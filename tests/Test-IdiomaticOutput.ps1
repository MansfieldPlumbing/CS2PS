#requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Verify','Measure','Golden','Baseline','Upstream','ApiCatalog','ApiQuery','CallMatrix')] [string] $Mode = 'Verify',
    [switch] $CaptureCallBaseline,
    [string] $ApiCatalogPath,
    [string] $ApiPattern = 'M:System.String.Substring*',
    [string] $ApiAssembly,
    [string[]] $ReferencePath = @($PSHOME)
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$build = Join-Path $root 'build'
$null = [IO.Directory]::CreateDirectory($build)
. (Join-Path $root 'src/ConvertFrom-CSharp.ps1')
Initialize-Roslyn
if ($Mode -eq 'ApiQuery') {
    if (-not $ApiCatalogPath) { $ApiCatalogPath = (Get-Content -Raw -LiteralPath (Join-Path $build 'api-catalog/current.json') | ConvertFrom-Json).ManifestPath }
    $catalog = Import-CS2PSApiCatalog -Path $ApiCatalogPath
    [string[]] $identity = if ($ApiAssembly) { @($catalog.Manifest.Assemblies | Where-Object Name -CEQ $ApiAssembly | ForEach-Object Identity) } else { @() }
    if ($ApiAssembly -and $identity.Count -ne 1) { throw 'Supply an assembly name identifying exactly one catalog image.' }
    Find-CS2PSApi -Catalog $catalog -AssemblyIdentity $(if ($identity.Count) {$identity[0]} else {$null}) -Pattern $ApiPattern -Limit 20
    return
}
if ($Mode -eq 'ApiCatalog') {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    if ($ApiCatalogPath) {
        $existing = Import-CS2PSApiCatalog -Path $ApiCatalogPath
        $summary = [pscustomobject]@{ManifestPath=(Resolve-Path -LiteralPath $ApiCatalogPath).Path; Assemblies=$existing.Manifest.Assemblies.Count; Types=$existing.Manifest.Types; Methods=$existing.Manifest.Methods; Members=$existing.Manifest.Members; ForwardedTypes=$existing.Manifest.ForwardedTypes}
    } else {
        $generation = Join-Path $build ('api-catalog/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
        $summary = New-CS2PSApiCatalog -OutputDirectory $generation -ReferencePath $ReferencePath
    }
    $watch.Stop()
    $inventoryMilliseconds = if ($ApiCatalogPath) { $null } else { $watch.Elapsed.TotalMilliseconds }
    $watch.Restart()
    $catalog = Import-CS2PSApiCatalog -Path $summary.ManifestPath
    $discoveryCases = @(
        @('System.Private.CoreLib','M:System.String.Substring(System.Int32,System.Int32)~System.String'),
        @('System.Private.CoreLib','M:System.Threading.Tasks.Task.Delay(System.Int32)~System.Threading.Tasks.Task'),
        @('System.Private.CoreLib','M:System.Runtime.InteropServices.NativeLibrary.Load(System.String)~System.IntPtr'),
        @('Newtonsoft.Json','M:Newtonsoft.Json.JsonConvert.SerializeObject(System.Object)~System.String'),
        @('System.Management.Automation','T:System.Management.Automation.PowerShell'),
        @('System.Text.Json','T:System.Text.Json.JsonSerializer')
    )
    foreach ($case in $discoveryCases) {
        $identity = @($catalog.Manifest.Assemblies | Where-Object Name -CEQ $case[0] | ForEach-Object Identity)
        if ($identity.Count -ne 1 -or @(Find-CS2PSApi -Catalog $catalog -AssemblyIdentity $identity[0] -Id $case[1] -Limit 2).Count -ne 1) { throw "API discovery failed: $($case[1])" }
    }
    $coreIdentity = @($catalog.Manifest.Assemblies | Where-Object Name -CEQ 'System.Private.CoreLib' | ForEach-Object Identity)[0]
    $stringMembers = @(Find-CS2PSApi -Catalog $catalog -AssemblyIdentity $coreIdentity -Pattern 'M:System.String.*' -Limit 1000 | Where-Object { $_.Api.DeclaringType -ceq 'T:System.String' -and $_.Api.Accessibility -ceq 'Public' -and $_.Api.MethodKind -notin 'Constructor','StaticConstructor' })
    $reflectionMethods = [string].GetMethods([Reflection.BindingFlags]'Public,Static,Instance,DeclaredOnly')
    if ($stringMembers.Count -ne $reflectionMethods.Count) { throw 'String declaration inventory does not match reflected public method count.' }
    $newtonsoftIdentity = @($catalog.Manifest.Assemblies | Where-Object Name -CEQ 'Newtonsoft.Json' | ForEach-Object Identity)[0]
    $dependencies = Get-CS2PSApiDependencyClosure -Catalog $catalog -AssemblyIdentity $newtonsoftIdentity
    if ($dependencies.Edges.Count -eq 0) { throw 'Newtonsoft assembly dependency graph is empty.' }
    # Catalog-assisted conversion must preserve the existing emission decisions exactly.
    $sites = 0
    $apiFixtures = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'fixtures') -Filter '*.cs' | Sort-Object Name)
    foreach ($fixture in $apiFixtures) {
        $before = ConvertFrom-CSharp -Path $fixture.FullName
        $after = ConvertFrom-CSharp -Path $fixture.FullName -ApiCatalogPath $summary.ManifestPath
        if ($before.PowerShell -cne $after.PowerShell -or ($before.Diagnostics | ConvertTo-Json -Depth 5 -Compress) -cne ($after.Diagnostics | ConvertTo-Json -Depth 5 -Compress)) { throw "Catalog changed translation semantics: $($fixture.Name)" }
        if ($fixture.BaseName -in 'ProgressLayout','ClassBoundaries','FormatBoundaries','Checked') {
            $golden = Join-Path $PSScriptRoot ('golden/' + $fixture.BaseName + '.ps1')
            if (-not (Test-Path -LiteralPath $golden) -or [IO.File]::ReadAllText($golden) -cne $after.PowerShell) { throw "Catalog golden comparison failed: $($fixture.Name)" }
        }
        $sites += @($after.ApiCalls | Where-Object CatalogMatched).Count
    }
    # Exercise a discovered shipped library through the existing comparison harness.
    $consumerDirectory = Join-Path $build 'api-catalog/consumer'
    $null = [IO.Directory]::CreateDirectory($consumerDirectory)
    $consumerPath = Join-Path $consumerDirectory 'JsonApi.cs'
    [IO.File]::WriteAllText($consumerPath, 'public static class JsonApi { public static string Serialize(int value) => Newtonsoft.Json.JsonConvert.SerializeObject(value); }', [Text.UTF8Encoding]::new($false))
    $consumerCases = @(0,-1,42,[int]::MinValue,[int]::MaxValue | ForEach-Object { @{Type='JsonApi';Method='Serialize';Arguments=@($_)} })
    [IO.File]::WriteAllText((Join-Path $consumerDirectory 'JsonApi.cases.json'), ($consumerCases | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    $newtonsoftPath = $catalog.Assemblies[$newtonsoftIdentity].Path
    foreach ($culture in 'en-US','fr-FR') {
        & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $PSScriptRoot 'Test-Parity.ps1') -Fixture $consumerPath -Culture $culture -ReferencePath $newtonsoftPath -ApiCatalogPath $summary.ManifestPath
        if ($LASTEXITCODE) { throw "Discovered Json.NET call parity failed: $culture" }
    }
    $watch.Stop()
    $receipt = @{ManifestPath=$summary.ManifestPath; Assemblies=$summary.Assemblies; Types=$summary.Types; Methods=$summary.Methods; Members=$summary.Members; ForwardedTypes=$summary.ForwardedTypes; CatalogMatchedCallSites=$sites; Fixtures=$apiFixtures.Count; StringPublicMethods=$stringMembers.Count; NewtonsoftDependencyAssemblies=$dependencies.Assemblies.Count; NewtonsoftDependencyEdges=$dependencies.Edges.Count; NewtonsoftMissingDependencies=$dependencies.Missing.Count; NewtonsoftIdentityMismatches=$dependencies.IdentityMismatches.Count; JsonNetParityCasesPerCulture=$consumerCases.Count; Cultures=@('en-US','fr-FR'); InventoryMilliseconds=$inventoryMilliseconds; ValidationMilliseconds=$watch.Elapsed.TotalMilliseconds; ReusedInventory=[bool]$ApiCatalogPath; Scope=$catalog.Manifest.Scope}
    $receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $build 'api-catalog/current.json')
    $receipt
    return
}
function Save-Text([string] $Path, [string] $Text) {
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function Import-PinnedLowering {
    $pin = '1afabe056235a570da29e268824784557d4f6cdd'
    $cache = Join-Path $build 'cache/PSLowering'
    $actual = & git -C $cache rev-parse HEAD
    if ($LASTEXITCODE -or $actual -cne $pin) { throw 'PSLowering SHA mismatch.' }
    $integrity = Get-Content -Raw -LiteralPath (Join-Path $build 'cache/PSLowering.integrity.json') | ConvertFrom-Json
    if ($integrity.Commit -cne $pin) { throw 'PSLowering integrity revision mismatch.' }
    foreach ($record in $integrity.Files) { if ((Get-FileHash -LiteralPath (Join-Path $cache $record.Path)).Hash -cne $record.SHA256) { throw "PSLowering digest mismatch: $($record.Path)" } }
    Import-Module (Join-Path $cache 'src/Dev.MansfieldPlumbing.PowerShell.Lowering.psd1') -Force -Global
}
if ($Mode -eq 'CallMatrix') {
    if (-not $ApiCatalogPath) { $ApiCatalogPath = (Get-Content -Raw -LiteralPath (Join-Path $build 'api-catalog/current.json') | ConvertFrom-Json).ManifestPath }
    $directory = Join-Path $build 'call-matrix'
    $null = [IO.Directory]::CreateDirectory($directory)
    $path = Join-Path $directory $(if ($CaptureCallBaseline) {'baseline.json'} else {'current.json'})
    if ($CaptureCallBaseline -and (Test-Path -LiteralPath $path)) { throw 'Call baseline already exists.' }
    if (-not $CaptureCallBaseline -and -not (Test-Path -LiteralPath (Join-Path $directory 'baseline.json'))) {
        & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $PSCommandPath -Mode CallMatrix -CaptureCallBaseline -ApiCatalogPath $ApiCatalogPath
        if ($LASTEXITCODE) { throw 'Unable to reconstruct the pinned call baseline.' }
    }
    if ($CaptureCallBaseline) {
        $baselineCommit = '4d8433c6725b1499ff5a2d604eee9fc4fc31a96d'
        $baselineDirectory = Join-Path $directory 'baseline-source'
        foreach ($name in 'ConvertFrom-CSharp.ps1','DotNetApiCatalog.ps1') {
            $text = @(& git -C $root show "${baselineCommit}:src/$name")
            if ($LASTEXITCODE) { throw "Baseline source unavailable: $baselineCommit $name" }
            Save-Text (Join-Path $baselineDirectory $name) (($text -join "`n") + "`n")
        }
        . (Join-Path $baselineDirectory 'ConvertFrom-CSharp.ps1')
    }
    $records = [Collections.Generic.List[object]]::new()
    $sourceInvocationCount = 0
    $admission = [Collections.Generic.List[object]]::new()
    if (-not $CaptureCallBaseline) { Import-PinnedLowering }
    foreach ($fixture in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'fixtures') -Filter '*.cs' | Sort-Object Name) {
        $result = ConvertFrom-CSharp -Path $fixture.FullName -ApiCatalogPath $ApiCatalogPath
        $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($call in $result.ApiCalls) { [void]$ids.Add($call.Id) }
        $expectedSpans = @(
            foreach ($node in $script:Model.SyntaxTree.GetRoot().DescendantNodes()) {
                if ($node -isnot [Microsoft.CodeAnalysis.CSharp.Syntax.InvocationExpressionSyntax]) { continue }
                $symbol = $script:Model.GetSymbolInfo($node).Symbol
                if ($symbol -and $ids.Contains((Get-CS2PSApiId $symbol))) { "$($node.Span.Start):$($node.Span.Length)" }
            }
        )
        $sourceInvocationCount += $expectedSpans.Count
        if (-not $CaptureCallBaseline) {
            $emittedSpans = @($result.ApiCalls | ForEach-Object { "$($_.SourceStart):$($_.SourceLength)" })
            if ($expectedSpans.Count -ne $emittedSpans.Count -or ($expectedSpans.Count -and (Compare-Object $expectedSpans $emittedSpans))) { throw "Invocation span coverage mismatch: $($fixture.Name)" }
        }
        foreach ($call in $result.ApiCalls) { $records.Add(@{Fixture=$fixture.Name;Call=$call}) }
        if ($CaptureCallBaseline) { Save-Text (Join-Path $directory ($fixture.BaseName + '.before.ps1')) $result.PowerShell }
        else {
            $output = Join-Path $directory ($fixture.BaseName + '.ps1')
            Save-Text $output $result.PowerShell
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($output,[ref]$tokens,[ref]$errors)
            if ($errors.Count) { throw "Generated call-matrix parse failed: $($fixture.Name): $($errors[0])" }
            if ($fixture.BaseName -in 'ProgressLayout','ClassBoundaries','FormatBoundaries','Checked') {
                $golden = Join-Path $PSScriptRoot ('golden/' + $fixture.BaseName + '.ps1')
                if ([IO.File]::ReadAllText($golden) -cne $result.PowerShell) { throw "Call-matrix golden mismatch: $($fixture.Name)" }
            }
            foreach ($method in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionMemberAst] -and -not $node.IsConstructor},$true)) {
                try { $null = ConvertTo-TypedExpression -MethodAst $method; $status='Admitted'; $reason='' } catch { $status='Rejected'; $reason=$_.Exception.Message }
                $admission.Add(@{Fixture=$fixture.Name;Method=$method.Name;Line=$method.Extent.StartLineNumber;Status=$status;Reason=$reason})
            }
            foreach ($method in $result.Methods | Where-Object { -not $_.ClassMethod }) {
                $admission.Add(@{Fixture=$fixture.Name;Method=$method.Function;Line=0;Status='Rejected';Reason='Pinned admission accepts FunctionMemberAst; this entrypoint requires function semantics.'})
            }
        }
    }
    if ($CaptureCallBaseline) {
        Save-Text $path (@{Commit=$baselineCommit;SourceInvocations=$sourceInvocationCount;Sites=@($records);Count=$records.Count} | ConvertTo-Json -Depth 10)
        return
    }
    $baseline = Get-Content -Raw -LiteralPath (Join-Path $directory 'baseline.json') | ConvertFrom-Json
    $oldKeys = @($baseline.Sites | ForEach-Object { "$($_.Fixture):$($_.Call.Line):$($_.Call.Id)" } | Sort-Object -Unique)
    $newKeys = @($records | ForEach-Object { "$($_.Fixture):$($_.Call.Line):$($_.Call.Id)" } | Sort-Object -Unique)
    if ($baseline.Count -ne 78 -or $records.Count -ne 75 -or $sourceInvocationCount -ne 75 -or (Compare-Object $oldKeys $newKeys)) { throw 'The original invocation corpus changed.' }
    $sourceKeys = @($records | ForEach-Object { "$($_.Fixture):$($_.Call.SourceStart):$($_.Call.SourceLength)" } | Sort-Object -Unique)
    if ($sourceKeys.Count -ne $records.Count) { throw 'Duplicate source invocation records.' }
    $parity = [Collections.Generic.List[object]]::new()
    $jsonFixture = Join-Path $directory 'JsonApi.cs'
    Save-Text $jsonFixture 'public static class JsonApi { public static string Serialize(int value) => Newtonsoft.Json.JsonConvert.SerializeObject(value); }'
    Save-Text (Join-Path $directory 'JsonApi.cases.json') (@(0,-1,42,[int]::MinValue,[int]::MaxValue | ForEach-Object { @{Type='JsonApi';Method='Serialize';Arguments=@($_)} }) | ConvertTo-Json -Depth 5)
    $jsonReference = Join-Path $PSHOME 'Newtonsoft.Json.dll'
    $jsonTranslation = ConvertFrom-CSharp -Path $jsonFixture -ReferencePath $jsonReference -ApiCatalogPath $ApiCatalogPath
    Save-Text (Join-Path $directory 'JsonApi.ps1') $jsonTranslation.PowerShell
    if ($jsonTranslation.ApiCalls.Count -ne 1 -or $jsonTranslation.ApiCalls[0].Outcome -ne 'Direct' -or $jsonTranslation.PowerShell -match 'Invoke-CS2PSRuntime|SerializeObject\(\[object\]') { throw 'Discovered Json.NET call did not use the unambiguous direct-call rule.' }
    foreach ($culture in 'en-US','fr-FR') {
        $total = 0
        foreach ($suite in @(
            @{Name='Fixtures';Arguments=@();Expected=264},
            @{Name='Json.NET';Arguments=@('-Fixture',$jsonFixture,'-ReferencePath',$jsonReference);Expected=5},
            @{Name='Call mappings';Arguments=@('-Fixture',(Join-Path $PSScriptRoot 'call-matrix/Calls.cs'));Expected=16}
        )) {
            $arguments = $suite.Arguments
            $log = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $PSScriptRoot 'Test-Parity.ps1') -Culture $culture -ApiCatalogPath $ApiCatalogPath @arguments)
            if ($LASTEXITCODE) { throw "Call-matrix parity failed: $culture $($suite.Name); $($log -join '; ')" }
            $summary = @($log | Where-Object { $_ -match '^calls ([0-9]+), differences ([0-9]+)$' })[-1]
            if ($summary -notmatch '^calls ([0-9]+), differences 0$' -or [int]$Matches[1] -ne $suite.Expected) { throw "Unexpected parity count: $summary" }
            $total += $suite.Expected
            $parity.Add(@{Culture=$culture;Suite=$suite.Name;Calls=$suite.Expected;Differences=0})
        }
        "$culture`: $total calls, 0 differences (269 existing + 16 binding regressions)"
    }
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $PSScriptRoot 'Test-Diagnostics.ps1')
    if ($LASTEXITCODE) { throw 'Diagnostic suite failed.' }
    $counts = [ordered]@{}
    foreach ($outcome in 'Direct','Adapted','Exact fallback','Unsupported') { $counts[$outcome] = @($records | Where-Object {$_.Call.Outcome -eq $outcome}).Count }
    $receipt = @{Sites=@($records);Count=$records.Count;Outcomes=$counts;BaselineDirect=@($baseline.Sites | Where-Object {$_.Call.Form -eq 'Direct'}).Count;BaselineReflection=@($baseline.Sites | Where-Object {$_.Call.Form -eq 'Reflection'}).Count;Parity=@($parity);Admission=@($admission);AdditionalJsonCall=@($jsonTranslation.ApiCalls);PowerShell=$PSVersionTable.PSVersion.ToString();SMA=[Management.Automation.PSObject].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute],$false)[0].InformationalVersion;CoreLib=[object].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute],$false)[0].InformationalVersion;PSLowering='1afabe056235a570da29e268824784557d4f6cdd';GoldenFiles=4;ParsedFixtures=30}
    $receipt.SourceInvocations = $sourceInvocationCount
    $receipt.BaselineCommit = '4d8433c6725b1499ff5a2d604eee9fc4fc31a96d'
    $beforeBySource = @(foreach ($record in $records) {
        @($baseline.Sites | Where-Object {$_.Fixture -ceq $record.Fixture -and $_.Call.Line -eq $record.Call.Line -and $_.Call.Id -ceq $record.Call.Id})[0].Call.Form
    })
    $receipt.BaselineSourceDirect = @($beforeBySource | Where-Object {$_ -eq 'Direct'}).Count
    $receipt.BaselineSourceReflection = @($beforeBySource | Where-Object {$_ -eq 'Reflection'}).Count
    Save-Text $path ($receipt | ConvertTo-Json -Depth 12)
    "Historical records before: $($receipt.BaselineDirect) direct, $($receipt.BaselineReflection) reflection"
    "Source sites before: $($receipt.BaselineSourceDirect) direct, $($receipt.BaselineSourceReflection) reflection"
    "Source invocations: $($records.Count); historical baseline included 3 duplicate visits"
    foreach ($outcome in $counts.Keys) { "$outcome`: $($counts[$outcome])" }
    "Lowering: $(@($admission | Where-Object Status -eq 'Admitted').Count) admitted, $(@($admission | Where-Object Status -eq 'Rejected').Count) rejected; reasons in $path"
    foreach ($record in $records | Where-Object {$_.Call.Outcome -eq 'Exact fallback'}) { "$($record.Fixture):$($record.Call.Line): $($record.Call.Reasons -join ' ')" }
    return
}
if ($Mode -eq 'Baseline') {
    $source = & git -C $root show '8c78f1b:src/ConvertFrom-CSharp.ps1'
    if ($LASTEXITCODE) { throw 'Baseline commit unavailable.' }
    $path = Join-Path $build 'baseline-emitter.ps1'
    Save-Text $path ($source -join "`n")
    . $path
    $result = ConvertFrom-CSharp -Path (Join-Path $PSScriptRoot 'fixtures/ProgressLayout.cs')
    $path = Join-Path $build 'baseline-progress.ps1'
    Save-Text $path $result.PowerShell
    . $path
    for ($i=0; $i -lt 1000; $i++) { $null = Get-ProgressLayoutBarWidth -v291 57 -v304 80 }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    for ($i=0; $i -lt 100000; $i++) { $null = Get-ProgressLayoutBarWidth -v291 57 -v304 80 }
    $watch.Stop()
    $receipt = @{Commit='8c78f1b';Calls=100000;Milliseconds=$watch.Elapsed.TotalMilliseconds;PowerShell=$PSVersionTable.PSVersion.ToString();Runtime=[Environment]::Version.ToString()}
    $receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $build 'baseline-speed.json')
    $receipt; return
}
if ($Mode -eq 'Upstream') {
    $pin = '37f8b4a65cf7eb1fca9808ea7b724e5db1e7dba5'
    $relative = 'src/Xamarin.Android.Build.Tasks/Utilities/PathUtil.cs'
    $source = @(& git -C 'C:/Dev/.vendor/dotnet-android' show "${pin}:$relative")
    if ($LASTEXITCODE) { throw 'Pinned Android source unavailable.' }
    $sourceText = ($source -join "`n") + "`n"
    $original = Join-Path $build 'cache/android/PathUtil.cs'
    Save-Text $original $sourceText
    if ((Get-FileHash -LiteralPath $original).Hash -cne '6303AFCBE3E7335892A26C9E49589E90340C441F073E97B0CC687A2AF23B3500') { throw 'Pinned Android source digest mismatch.' }
    $tree = [Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($sourceText)
    $method = @($tree.GetRoot().DescendantNodes() | Where-Object { $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax] -and $_.Identifier.ValueText -ceq 'IsValidDriveChar' })
    if ($method.Count -ne 1) { throw 'Pinned member selection is ambiguous.' }
    $slice = "// Consumer slice: dotnet/android $pin $relative; method body unchanged.`npublic static class PathUtil {`n$($method[0].ToFullString())}`n"
    $slicePath = Join-Path $build 'android/PathUtilDriveChar.cs'
    Save-Text $slicePath $slice
    $result = ConvertFrom-CSharp -Path $slicePath
    if (@($result.Diagnostics | Where-Object Severity -NE 'Information').Count) { throw 'Android member is outside the supported subset.' }
    Save-Text (Join-Path $build 'android/PathUtilDriveChar.ps1') $result.PowerShell
    # A real consumer slice is compared against compiled original C# by the existing harness.
    $cases = @('A','Z','a','z','0',':','[','`','é',[string][char]0) | ForEach-Object { @{Type='PathUtil';Method='IsValidDriveChar';Arguments=@($_)} }
    Save-Text (Join-Path $build 'android/PathUtilDriveChar.cases.json') ($cases | ConvertTo-Json -Depth 5)
    foreach ($culture in 'en-US','fr-FR') {
        & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $PSScriptRoot 'Test-Parity.ps1') -Fixture $slicePath -Culture $culture
        if ($LASTEXITCODE) { throw "Android parity failed: $culture" }
    }
    Import-PinnedLowering
    $assemblyPath = Join-Path $build 'android/PathUtilDriveChar.dll'
    $lowered = Export-LoweredAssembly -SourcePath (Join-Path $build 'android/PathUtilDriveChar.ps1') -ClassName PathUtil -MethodNames IsValidDriveChar -OutputPath $assemblyPath
    $assembly = [Reflection.Assembly]::LoadFrom($assemblyPath)
    $compiled = $assembly.GetType('PathUtil',$true).GetMethod('IsValidDriveChar')
    $oracleFile = Get-ChildItem -LiteralPath $build -Filter 'PathUtilDriveChar.reference.*.dll' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $oracle = [Reflection.Assembly]::LoadFrom($oracleFile.FullName).GetType('PathUtil',$true).GetMethod('IsValidDriveChar',[Reflection.BindingFlags]'Static,NonPublic')
    foreach ($case in $cases) {
        $arguments = [object[]]@([char]$case.Arguments[0])
        if ($compiled.Invoke($null,$arguments) -cne $oracle.Invoke($null,$arguments)) { throw 'Lowered Android method differs from original C#.' }
    }
    $receipt = @{Repository='https://github.com/dotnet/android';Commit=$pin;Source=$relative;SourceSHA256=(Get-FileHash -LiteralPath $original).Hash;Member='IsValidDriveChar';Line=$method[0].GetLocation().GetLineSpan().StartLinePosition.Line+1;SliceSHA256=(Get-FileHash -LiteralPath $slicePath).Hash;Cases=10;Scope='Method body only; not complete Android binding or device integration'}
    $receipt.LoweredSHA256 = (Get-FileHash -LiteralPath $assemblyPath).Hash
    $receipt.LoweredCases = $cases.Count
    $receipt.Dependencies = @($assembly.GetReferencedAssemblies().Name)
    if (@($receipt.Dependencies | Where-Object { $_ -ne 'System.Private.CoreLib' }).Count) { throw 'Unexpected lowered Android dependency.' }
    $receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $build 'android/receipt.json')
    $receipt; return
}
$pin = '1afabe056235a570da29e268824784557d4f6cdd'
Import-PinnedLowering
$goldenNames = 'ProgressLayout','ClassBoundaries','FormatBoundaries','Checked'
$measurements = [Collections.Generic.List[object]]::new()
$admission = [Collections.Generic.List[object]]::new()
$nameFailures = [Collections.Generic.List[object]]::new()
$sites = [Collections.Generic.List[object]]::new()
foreach ($fixture in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'fixtures') -Filter '*.cs' | Sort-Object Name) {
    $result = ConvertFrom-CSharp -Path $fixture.FullName
    $sourceLines = @([IO.File]::ReadAllLines($fixture.FullName) | Where-Object { $_.Trim() }).Count
    $output = Join-Path $build ($fixture.BaseName + '.idiomatic.ps1')
    Save-Text $output $result.PowerShell
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($output,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw "Generated parse failure: $($fixture.Name): $($errors[0])" }
    # Token extents exclude both standalone and inline comments from line counts.
    $codeLines = [Collections.Generic.HashSet[int]]::new()
    foreach ($token in $tokens | Where-Object { $_.Kind.ToString() -notin 'Comment','NewLine','EndOfInput' }) {
        for ($line=$token.Extent.StartLineNumber; $line -le $token.Extent.EndLineNumber; $line++) { [void]$codeLines.Add($line) }
    }
    $helpers = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -match 'CS2PS'},$true))
    $declarations = @($script:Model.SyntaxTree.GetRoot().DescendantNodes() | Where-Object { $_.GetType().Name -in 'ClassDeclarationSyntax','StructDeclarationSyntax','MethodDeclarationSyntax','ParameterSyntax','VariableDeclaratorSyntax' })
    $identifiers = 0
    $emittedNames = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.VariableExpressionAst] -or $node -is [Management.Automation.Language.PropertyMemberAst] -or $node -is [Management.Automation.Language.FunctionMemberAst] -or $node -is [Management.Automation.Language.FunctionDefinitionAst] -or $node -is [Management.Automation.Language.TypeDefinitionAst]},$true) | ForEach-Object { if ($_ -is [Management.Automation.Language.VariableExpressionAst]) { $_.VariablePath.UserPath } else { $_.Name } })
    foreach ($declaration in $declarations) {
        $symbol = $script:Model.GetDeclaredSymbol($declaration)
        if (-not $symbol) { continue }
        $identifiers++
        $original = $symbol.Name
        $renamed = @($result.Renames | Where-Object Source -CEQ $original)
        $unchanged = @($emittedNames | Where-Object { $_ -ceq $original -or ($symbol.Kind.ToString() -eq 'Method' -and $_.EndsWith($original,[StringComparison]::Ordinal)) }).Count
        if (-not $unchanged -and -not $renamed.Count) { $nameFailures.Add(@{Fixture=$fixture.Name;Name=$original;Line=$declaration.GetLocation().GetLineSpan().StartLinePosition.Line+1;Reason='Identifier absent from executable AST without collision record'}) }
        foreach ($rename in $renamed) { if (-not $rename.Reason -or $rename.Output -notmatch ('^' + [regex]::Escape($rename.Source) + '_[2-9][0-9]*$')) { $nameFailures.Add(@{Fixture=$fixture.Name;Name=$original;Reason='Invalid collision record'}) } }
    }
    foreach ($diagnostic in $result.Diagnostics) { $sites.Add(@{Fixture=$fixture.Name;Line=$diagnostic.Line;Severity=$diagnostic.Severity;Reason=$diagnostic.Message}) }
    foreach ($method in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionMemberAst] -and -not $node.IsConstructor},$true)) {
        try { $null = ConvertTo-TypedExpression -MethodAst $method; $status='Admitted'; $reason='' } catch { $status='Rejected'; $reason=$_.Exception.Message }
        $admission.Add(@{Fixture=$fixture.Name;Method=$method.Name;Line=$method.Extent.StartLineNumber;Status=$status;Reason=$reason})
    }
    foreach ($method in $result.Methods | Where-Object { -not $_.ClassMethod }) { $admission.Add(@{Fixture=$fixture.Name;Method=$method.Function;Line=0;Status='Rejected';Reason='Pinned admission accepts FunctionMemberAst; this generated entrypoint requires function semantics.'}) }
    $golden = Join-Path $PSScriptRoot ('golden/' + $fixture.BaseName + '.ps1')
    if ($fixture.BaseName -in $goldenNames) {
        if ($Mode -eq 'Golden') {
            if ([IO.File]::Exists($golden)) {
                if ([IO.File]::ReadAllText($golden) -cne $result.PowerShell) { throw "Golden already exists; review before replacement: $golden" }
            } else { Save-Text $golden $result.PowerShell }
        } elseif (-not [IO.File]::Exists($golden) -or [IO.File]::ReadAllText($golden) -cne $result.PowerShell) { throw "Golden mismatch: $($fixture.Name)" }
    }
    $ratio = $codeLines.Count / $sourceLines
    $measurements.Add(@{Fixture=$fixture.Name;SourceLines=$sourceLines;GeneratedLines=$codeLines.Count;Ratio=$ratio;Helpers=$helpers.Count;Identifiers=$identifiers;Renames=@($result.Renames);SizePassed=$ratio -le 1.5})
    '{0}: {1}/{2} = {3:N2}x; helpers {4}; identifiers {5}; renames {6}' -f $fixture.Name,$codeLines.Count,$sourceLines,$ratio,$helpers.Count,$identifiers,$result.Renames.Count
}
if ($Mode -eq 'Golden') { 'Four golden files written; review before committing.'; return }
$before = Get-Content -Raw -LiteralPath (Join-Path $build 'baseline-speed.json') | ConvertFrom-Json
. (Join-Path $build 'ProgressLayout.idiomatic.ps1')
for ($i=0; $i -lt 1000; $i++) { $null = Get-ProgressLayoutBarWidth -percent 57 -columns 80 }
$watch = [Diagnostics.Stopwatch]::StartNew()
for ($i=0; $i -lt 100000; $i++) { $null = Get-ProgressLayoutBarWidth -percent 57 -columns 80 }
$watch.Stop()
$cultures = [Collections.Generic.List[object]]::new()
if ($Mode -eq 'Verify') {
    foreach ($culture in 'en-US','fr-FR') {
        $log = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $PSScriptRoot 'Test-Parity.ps1') -Culture $culture)
        if ($LASTEXITCODE) { throw "Parity failure: $culture; $($log -join '; ')" }
        $summary = @($log | Where-Object { $_ -match '^calls ([0-9]+), differences ([0-9]+)$' })[-1]
        if ($summary -notmatch '^calls ([0-9]+), differences 0$') { throw 'Parity summary missing or nonzero.' }
        $cultures.Add(@{Culture=$culture;Calls=[int]$Matches[1];Differences=0}); "$culture`: $summary"
    }
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $PSScriptRoot 'Test-Diagnostics.ps1')
    if ($LASTEXITCODE) { throw 'Diagnostic suite failed.' }
}
$receipt = @{PowerShell=$PSVersionTable.PSVersion.ToString();Runtime=[Environment]::Version.ToString();PSLowering=$pin;Fixtures=@($measurements);NameFailures=@($nameFailures);Admission=@($admission);SemanticSites=@($sites);Parity=@($cultures);Speed=@{Calls=100000;BeforeMilliseconds=$before.Milliseconds;AfterMilliseconds=$watch.Elapsed.TotalMilliseconds}}
$receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $build 'idiomatic-acceptance.json')
$admitted = @($admission | Where-Object Status -EQ 'Admitted').Count
$rejected = @($admission | Where-Object Status -EQ 'Rejected').Count
$sizeFailures = @($measurements | Where-Object SizePassed -EQ $false).Count
"Names: $($nameFailures.Count) failures; size: $sizeFailures failures; lowering: $admitted admitted, $rejected rejected"
"Speed: 100000 calls, before $($before.Milliseconds) ms, after $($watch.Elapsed.TotalMilliseconds) ms"
if ($nameFailures.Count -or $sizeFailures -or @($measurements | Where-Object { $_.Fixture -eq 'ProgressLayout.cs' -and $_.Helpers -ne 0 }).Count) { throw 'Measured acceptance has failures; see build/idiomatic-acceptance.json.' }
