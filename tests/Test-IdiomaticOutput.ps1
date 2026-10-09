#requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('CI','ILVerify','Verify','Measure','Golden','Baseline','Upstream','ApiCatalog','ApiQuery','CallMatrix','AndroidBindings','OutputContract','SourceClosure')] [string] $Mode = 'Verify',
    [switch] $CaptureCallBaseline,
    [string] $ApiCatalogPath,
    [string] $ApiPattern = 'M:System.String.Substring*',
    [string] $ApiAssembly,
    [string[]] $ReferencePath = @($PSHOME),
    [string] $AndroidSourceRoot = 'C:/Dev/.vendor/dotnet-android'
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
function Test-LoweredOutputContract([string] $SourcePath, [string] $ClassName, [string] $Fixture) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($SourcePath,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw "SMA validation failed: $SourcePath $($errors[0])" }
    $methods = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionMemberAst] -and -not $node.IsConstructor},$true))
    $admission = @(foreach ($method in $methods) {
        try { $null = ConvertTo-TypedExpression -MethodAst $method; $status='Admitted'; $reason='' }
        catch { $status='Rejected'; $reason=$_.Exception.Message }
        @{Method=$method.Name;Line=$method.Extent.StartLineNumber;Status=$status;Reason=$reason}
    })
    $names = @($admission | Where-Object Status -eq Admitted | ForEach-Object Method)
    $report = [ordered]@{Source=$SourcePath;SmaParsed=$true;Admission=$admission;IndependentIL=$null}
    if (-not $names.Count) { return $report }
    $directory = Join-Path $build "output-contract/$ClassName"
    $outputs = @(foreach ($part in 'first','second') {
        $path = Join-Path $directory "$part/$ClassName.dll"
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        $null = Export-LoweredAssembly -SourcePath $SourcePath -ClassName $ClassName -MethodNames $names -OutputPath $path -Deterministic
        $path
    })
    $hashes = @($outputs | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash })
    if ($hashes[0] -cne $hashes[1]) { throw "Nondeterministic lowered IL: $ClassName" }
    $context = [Runtime.Loader.AssemblyLoadContext]::new("CS2PS-$ClassName",$true)
    try {
        $assembly = $context.LoadFromAssemblyPath($outputs[0])
        $references = @($assembly.GetReferencedAssemblies().Name)
        if ($references.Count -ne 1 -or $references[0] -cne 'System.Private.CoreLib') { throw "Unexpected assembly dependencies: $ClassName $($references -join ', ')" }
        $oraclePath = (Get-ChildItem -LiteralPath $build -Filter "$ClassName.reference.*.dll" | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
        $oracle = $context.LoadFromAssemblyPath($oraclePath)
        $cases = @(Get-Content -Raw -LiteralPath ([IO.Path]::ChangeExtension($Fixture,'cases.json')) | ConvertFrom-Json | Where-Object Method -in $names)
        $originalCulture = [Globalization.CultureInfo]::CurrentCulture
        try {
            foreach ($culture in 'en-US','fr-FR') {
                [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
                foreach ($case in $cases) {
                    $flags = [Reflection.BindingFlags]'Public,NonPublic,Static'
                    $expectedMethod = $oracle.GetType($ClassName,$true).GetMethod($case.Method,$flags)
                    $actualMethod = $assembly.GetType($ClassName,$true).GetMethod($case.Method,$flags)
                    $parameters = $expectedMethod.GetParameters()
                    $arguments = [object[]]::new($parameters.Count)
                    for ($i=0; $i -lt $arguments.Count; $i++) {
                        $arguments[$i] = if ($null -eq $case.Arguments[$i]) { $null } else { [Management.Automation.LanguagePrimitives]::ConvertTo($case.Arguments[$i],$parameters[$i].ParameterType) }
                    }
                    $outcomes = @(foreach ($method in @($expectedMethod,$actualMethod)) {
                        try { $value=$method.Invoke($null,$arguments); @{Value=$value;Type=$(if ($null -ne $value) {$value.GetType().FullName});Exception=$null} }
                        catch { @{Value=$null;Type=$null;Exception=$_.Exception.GetBaseException().GetType().FullName} }
                    })
                    if ($outcomes[0].Exception -cne $outcomes[1].Exception -or $outcomes[0].Type -cne $outcomes[1].Type -or $outcomes[0].Value -cne $outcomes[1].Value) {
                        throw "Independent IL differs: $ClassName.$($case.Method) $culture; $($outcomes | ConvertTo-Json -Compress)"
                    }
                }
            }
        } finally { [Globalization.CultureInfo]::CurrentCulture = $originalCulture }
        $report.IndependentIL = @{Path=$outputs[0];Bytes=(Get-Item -LiteralPath $outputs[0]).Length;SHA256=$hashes[0];Deterministic=$true;References=$references;CasesPerCulture=$cases.Count;Differences=0}
    } finally { $context.Unload() }
    return $report
}
if ($Mode -eq 'CI') {
    & (Join-Path $PSScriptRoot 'Test-FixtureOrigins.ps1')
    foreach ($file in @(& git -C $root ls-files '*.ps1')) {
        $tokens=$null; $errors=$null
        $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file),[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw "Committed PowerShell parse failure: $file" }
    }
    $runtimeVersion = [object].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute],$false)[0].InformationalVersion.Split('+')[0]
    if ($PSVersionTable.PSVersion.ToString() -cne '7.7.0-preview.5' -or $runtimeVersion -cne '11.0.0-rc.1.26425.128') { throw 'CI requires the pinned PowerShell and runtime.' }
    $lowering = Join-Path $build 'cache/PSLowering'
    $pin = '1afabe056235a570da29e268824784557d4f6cdd'
    $actual = & git -C $lowering rev-parse HEAD
    if ($LASTEXITCODE -or $actual -cne $pin) { throw 'PSLowering checkout SHA mismatch.' }
    $archive = Join-Path $build 'cache/PSLowering.source.tar'
    & git -C $lowering archive --format=tar --output $archive $pin
    if ($LASTEXITCODE -or (Get-FileHash -LiteralPath $archive).Hash -cne '816E789E4326B6506644A87D1EDF5D75EA4ED29893BAC2422A964F0D0E418C97') { throw 'PSLowering source archive digest mismatch.' }
    & git -C $lowering diff --quiet HEAD --
    if ($LASTEXITCODE) { throw 'PSLowering tracked files are modified.' }
    $files = @(& git -C $lowering ls-files)
    if ($LASTEXITCODE -or -not $files.Count) { throw 'PSLowering checkout is empty.' }
    $integrity = @{Commit=$pin;Files=@($files | ForEach-Object { @{Path=$_;SHA256=(Get-FileHash -LiteralPath (Join-Path $lowering $_)).Hash} })}
    Save-Text (Join-Path $build 'cache/PSLowering.integrity.json') ($integrity | ConvertTo-Json -Depth 5)
    foreach ($stage in 'ApiCatalog','CallMatrix','AndroidBindings','OutputContract','SourceClosure','ILVerify') {
        & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $PSCommandPath -Mode $stage -AndroidSourceRoot $AndroidSourceRoot
        if ($LASTEXITCODE) { throw "CI stage failed: $stage" }
    }
    $records = @(foreach ($path in 'call-matrix/current.json','android-bindings/receipt.json','output-contract/receipt.json','source-closure/receipt.json','ilverify/receipt.json') {
        @{Path=$path;SHA256=(Get-FileHash -LiteralPath (Join-Path $build $path)).Hash;Result=(Get-Content -Raw -LiteralPath (Join-Path $build $path) | ConvertFrom-Json)}
    })
    Save-Text (Join-Path $build 'ci-receipt.json') (@{Commit=(& git -C $root rev-parse HEAD);PowerShell=$PSVersionTable.PSVersion.ToString();Runtime=$runtimeVersion;PSLowering=$pin;PSLoweringArchiveSHA256=(Get-FileHash -LiteralPath $archive).Hash;WorkflowRun=$env:GITHUB_RUN_ID;Records=$records;NotRun=@('Android emulator','Physical Snapdragon/Hexagon','Other consumer repository suites','Global size acceptance')} | ConvertTo-Json -Depth 30)
    'Conformance: 341 distinct source/SMA comparisons and 34 independent IL comparisons per culture; 0 differences.'
    'Size acceptance and universal lowering admission remain open; see README.md.'
    return
}
if ($Mode -eq 'ILVerify') {
    Import-PinnedLowering
    $directory = Join-Path $build 'ilverify'
    $null = [IO.Directory]::CreateDirectory($directory)
    $package = Join-Path $directory 'dotnet-ilverify.10.0.12.zip'
    if (-not (Test-Path -LiteralPath $package)) { Invoke-WebRequest 'https://api.nuget.org/v3-flatcontainer/dotnet-ilverify/10.0.12/dotnet-ilverify.10.0.12.nupkg' -OutFile $package }
    $digest = '7FA6EDC3210E8BD0B998234B51196E95C9ED6DB3B4EAC51BC5320CF1799C6C0D'
    if ((Get-FileHash -LiteralPath $package).Hash -cne $digest) { throw 'ILVerify package digest mismatch.' }
    Expand-Archive -LiteralPath $package -DestinationPath (Join-Path $directory 'tool') -Force
    $tool = Join-Path $directory 'tool/tools/net10.0/any/ILVerify.dll'
    $runtimeZip = Join-Path $directory 'dotnet-runtime.zip'
    if (-not (Test-Path -LiteralPath $runtimeZip)) { Invoke-WebRequest 'https://builds.dotnet.microsoft.com/dotnet/Runtime/11.0.0-rc.1.26425.128/dotnet-runtime-11.0.0-rc.1.26425.128-win-x64.zip' -OutFile $runtimeZip }
    $runtimeDigest = '0DE14CB96790C916B4EB86DE0B96A9F8BEFD1BC3687779B0B0813925D5A728CD34E0F91D80314E5B3D1B971CC67611170194DB4DE47012B506F5A183124361E8'
    if ((Get-FileHash -LiteralPath $runtimeZip -Algorithm SHA512).Hash -cne $runtimeDigest) { throw 'Independent dotnet runtime digest mismatch.' }
    Expand-Archive -LiteralPath $runtimeZip -DestinationPath (Join-Path $directory 'dotnet') -Force
    $dotnet = Join-Path $directory 'dotnet/dotnet.exe'
    $hostPath = Join-Path $directory 'ConsumerOracle.dll'
    $sourcePaths = @((Join-Path $PSScriptRoot 'reference/ConsumerOracle.cs'),(Join-Path $PSScriptRoot 'fixtures/ProgressLayout.cs'),(Join-Path $build 'android-bindings/JavaNativeTypeManager.cs'))
    $trees = [Microsoft.CodeAnalysis.SyntaxTree[]]@($sourcePaths | ForEach-Object { [Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText([IO.File]::ReadAllText($_)) })
    $refs = [Microsoft.CodeAnalysis.MetadataReference[]]@('System.Private.CoreLib.dll','System.Runtime.dll','System.Console.dll','System.Text.Json.dll','System.Memory.dll' | ForEach-Object { [Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile((Join-Path $PSHOME $_)) })
    $options = [Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::ConsoleApplication)
    $compilation = [Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('ConsumerOracle',$trees,$refs,$options)
    $stream = [IO.File]::Create($hostPath)
    try { $emitted = $compilation.Emit($stream) } finally { $stream.Dispose() }
    if (-not $emitted.Success) { throw "Comparison executable compile failed: $($emitted.Diagnostics -join '; ')" }
    Save-Text ([IO.Path]::ChangeExtension($hostPath,'runtimeconfig.json')) (@{runtimeOptions=@{tfm='net11.0';framework=@{name='Microsoft.NETCore.App';version='11.0.0-rc.1.26425.128'};rollForward='Disable'}} | ConvertTo-Json -Depth 5)
    $receipt = Get-Content -Raw -LiteralPath (Join-Path $build 'output-contract/receipt.json') | ConvertFrom-Json
    $hostChecks = [Collections.Generic.List[object]]::new()
    $checks = @(foreach ($output in $receipt.Outputs) {
        $assemblyPath = $output.IndependentIL.Path
        if (-not $assemblyPath) { throw 'No independently executed assembly available for ILVerify.' }
        $log = @(& $dotnet exec --runtimeconfig ([IO.Path]::ChangeExtension($hostPath,'runtimeconfig.json')) $tool $assemblyPath --system-module System.Private.CoreLib -r (Join-Path $PSHOME 'System.Private.CoreLib.dll') 2>&1)
        $code = $LASTEXITCODE
        Save-Text (Join-Path $directory ([IO.Path]::GetFileName($assemblyPath) + '.log')) ($log -join "`n")
        if ($code -ne 0 -or -not ($log -match 'All Classes and Methods.*Verified')) { throw "ILVerify failed: $assemblyPath" }
        $class = [IO.Path]::GetFileNameWithoutExtension($output.Source)
        $fixture = if ($class -ceq 'ProgressLayout') { Join-Path $PSScriptRoot 'fixtures/ProgressLayout.cs' } else { Join-Path $build 'android-bindings/JavaNativeTypeManager.cs' }
        $vectorsPath = [IO.Path]::ChangeExtension($fixture,'cases.json')
        $admitted = @($output.Admission | Where-Object Status -ceq Admitted | ForEach-Object Method) -join '|'
        foreach ($culture in 'en-US','fr-FR') {
            $log = @(& $dotnet exec $hostPath $assemblyPath $class $culture $vectorsPath $admitted 2>&1)
            if ($LASTEXITCODE -ne 0 -or "$($log[-1])" -cne "calls $($output.IndependentIL.CasesPerCulture), differences 0, SMA absent") { throw "Dotnet-only parity failed: $class $culture $($log -join '; ')" }
            $hostChecks.Add(@{Class=$class;Culture=$culture;Calls=$output.IndependentIL.CasesPerCulture;Differences=0;SmaLoaded=$false;SourceSHA256=(Get-FileHash -LiteralPath $fixture).Hash;VectorsSHA256=(Get-FileHash -LiteralPath $vectorsPath).Hash})
        }
        @{Assembly=$assemblyPath;SHA256=(Get-FileHash -LiteralPath $assemblyPath).Hash;Status='PASS'}
    })
    # Valid but behaviorally corrupted candidate; frozen C# and vectors remain untouched.
    $original = Join-Path $build 'output-contract/ProgressLayout.ps1'
    $tokens=$null; $errors=$null
    $ast = [Management.Automation.Language.Parser]::ParseFile($original,[ref]$tokens,[ref]$errors)
    $method = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionMemberAst] -and $node.Name -ceq 'Clamp'},$true))[0]
    if ($errors.Count -or -not $method) { throw 'Negative-control source not available.' }
    $text = [IO.File]::ReadAllText($original)
    $mutated = $text.Substring(0,$method.Body.Extent.StartOffset) + '{ return 0 }' + $text.Substring($method.Body.Extent.EndOffset)
    $source = Join-Path $directory 'corrupted.ps1'
    Save-Text $source $mutated
    $candidate = Join-Path $directory 'Corrupted.dll'
    $null = Export-LoweredAssembly -SourcePath $source -ClassName ProgressLayout -MethodNames Clamp -OutputPath $candidate -Deterministic
    $context = [Runtime.Loader.AssemblyLoadContext]::new('CS2PS-negative',$true)
    try {
        $actual = $context.LoadFromAssemblyPath($candidate).GetType('ProgressLayout').GetMethod('Clamp')
        $oraclePath = (Get-ChildItem -LiteralPath $build -Filter 'ProgressLayout.reference.*.dll' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
        $expected = $context.LoadFromAssemblyPath($oraclePath).GetType('ProgressLayout').GetMethod('Clamp')
        $vectors = @(Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures/ProgressLayout.cases.json') | ConvertFrom-Json | Where-Object Method -ceq Clamp)
        $differences = 0
        foreach ($culture in 'en-US','fr-FR') {
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
            foreach ($vector in $vectors) {
                $arguments = [object[]]@($vector.Arguments | ForEach-Object { [int]$_ })
                if ($expected.Invoke($null,$arguments) -cne $actual.Invoke($null,$arguments)) { $differences++ }
            }
        }
        if (-not $differences) { throw 'Behavioral validator failed to detect corrupted generated output.' }
    } finally { $context.Unload() }
    $negative = @(& $dotnet exec $hostPath $candidate ProgressLayout en-US (Join-Path $PSScriptRoot 'fixtures/ProgressLayout.cases.json') Clamp 2>&1)
    if ($LASTEXITCODE -ne 1 -or "$($negative[-1])" -cne 'calls 3, differences 2, SMA absent') { throw 'Dotnet-only negative control did not detect exactly the expected corruption.' }
    $damaged = Join-Path $directory 'damaged.dll'
    [IO.File]::WriteAllBytes($damaged,[byte[]]@(0,0,0,0))
    $log = @(& $dotnet exec --runtimeconfig ([IO.Path]::ChangeExtension($hostPath,'runtimeconfig.json')) $tool $damaged --system-module System.Private.CoreLib -r (Join-Path $PSHOME 'System.Private.CoreLib.dll') 2>&1)
    if ($LASTEXITCODE -eq 0) { throw 'ILVerify accepted a damaged assembly.' }
    Save-Text (Join-Path $directory 'negative-structure.log') ($log -join "`n")
    $report = @{Tool='dotnet-ilverify';Version='10.0.12';PackageSHA256=$digest;FrameworkReference=(Join-Path $PSHOME 'System.Private.CoreLib.dll');FrameworkSHA256=(Get-FileHash -LiteralPath (Join-Path $PSHOME 'System.Private.CoreLib.dll')).Hash;Checks=$checks;BehavioralNegative=@{Status='PASS';DetectedDifferences=$differences;CasesPerCulture=$vectors.Count;Cultures=@('en-US','fr-FR');OracleSHA256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'fixtures/ProgressLayout.cs')).Hash};StructuralNegative='PASS'}
    $report.DotnetOnly = @($hostChecks)
    $report.DotnetOnlyNegative = @{Status='PASS';Culture='en-US';Cases=3;DetectedDifferences=2}
    $report.RuntimeSHA512 = $runtimeDigest
    $report.Runtime = '11.0.0-rc.1.26425.128'
    $report.ComparisonSources = @($sourcePaths | ForEach-Object { @{Path=$_;SHA256=(Get-FileHash -LiteralPath $_).Hash} })
    Save-Text (Join-Path $directory 'receipt.json') ($report | ConvertTo-Json -Depth 8)
    "ILVerify: $($checks.Count) assemblies verified; behavioral corruption detected ($differences differences); damaged assembly rejected."
    return
}
if ($Mode -eq 'SourceClosure') {
    $upstream = Join-Path $build 'cache/android-bindings/37f8b4a65cf7eb1fca9808ea7b724e5db1e7dba5/external/Java.Interop/src/Java.Interop.Tools.TypeNameMappings/Java.Interop.Tools.TypeNameMappings/JavaNativeTypeManager.cs'
    # Validate the existing acquisition rather than reading an external checkout.
    $cache = Join-Path $build 'cache/android-bindings/37f8b4a65cf7eb1fca9808ea7b724e5db1e7dba5'
    $integrity = Get-Content -Raw -LiteralPath (Join-Path $cache 'integrity.json') | ConvertFrom-Json
    $sourceRecord = @($integrity.Files | Where-Object Path -like '*/JavaNativeTypeManager.cs')[0]
    if ((Get-FileHash -LiteralPath $upstream).Hash -cne $sourceRecord.SHA256) { throw 'Pinned Android source integrity failed.' }
    $closure = Get-CS2PSSourceMemberClosure -Path $upstream -Member 'JavaNativeTypeManager.ToCliType(string)'
    $directory = Join-Path $build 'source-closure'
    Save-Text (Join-Path $directory 'closure.json') ($closure | ConvertTo-Json -Depth 12)
    if ($closure.Members.Count -ne 3 -or @($closure.Members | Where-Object Kind -ne Method).Count) { throw 'JNI CLI-name dependency closure changed.' }
    # This is the same explicitly scoped method-body comparison host used by
    # AndroidBindings, not a claim to reproduce upstream type initialization.
    $fixture = Join-Path $directory 'JavaNativeTypeManager.cs'
    Save-Text $fixture ("// Method-body closure from dotnet/android $($integrity.Commit).`nusing System;`npublic static class JavaNativeTypeManager {`n" + (($closure.Members.Source) -join "`n") + "`n}`n")
    $cases = @(foreach ($value in @($null,'','java/lang/String','java/util/Map$Entry','I','a/b/c','a//b','foo$bar$baz','éclair/value','[I','/','$')) {
        @{Type='JavaNativeTypeManager';Method='ToCliType';Arguments=@($value)}
    })
    Save-Text ([IO.Path]::ChangeExtension($fixture,'cases.json')) ($cases | ConvertTo-Json -Depth 5)
    $translation = ConvertFrom-CSharp -Path $fixture
    Save-Text (Join-Path $directory 'JavaNativeTypeManager.ps1') $translation.PowerShell
    if (@($translation.Diagnostics | Where-Object Severity -ne Information).Count) {
        Save-Text (Join-Path $directory 'translation-gaps.json') ($translation.Diagnostics | ConvertTo-Json -Depth 5)
        throw "Extracted source has explicit translation gaps: $($translation.Diagnostics | ConvertTo-Json -Compress)"
    }
    foreach ($culture in 'en-US','fr-FR') {
        $log = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $PSScriptRoot 'Test-Parity.ps1') -Fixture $fixture -Culture $culture -TraceBinding)
        if ($LASTEXITCODE -or $log[-1] -cne "calls $($cases.Count), differences 0") { throw "Extracted source parity failed: $culture $($log -join '; ')" }
    }
    $peer = Join-Path $directory 'Peer.cs'; $caller = Join-Path $directory 'Caller.cs'
    Save-Text $caller 'public static class Caller { public static int Run(int value) => Peer.Once(value); public static int Unused() => 0; }'
    Save-Text $peer 'public static class Peer { public static int Once(int value) => value > 0 ? Caller.Run(value - 1) : 0; }'
    $cycle = Get-CS2PSSourceMemberClosure -Path $caller,$peer -Member 'Caller.Run(int)'
    if (-not $cycle.Closed -or $cycle.Members.Count -ne 2 -or @($cycle.Members | Where-Object Identity -match Unused).Count) { throw 'Cross-file recursive closure failed.' }
    Import-PinnedLowering
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $directory 'JavaNativeTypeManager.ps1'),[ref]$tokens,[ref]$errors)
    $admission = @(foreach ($method in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionMemberAst]},$true)) {
        try { $null=ConvertTo-TypedExpression -MethodAst $method; @{Method=$method.Name;Status='Admitted'} }
        catch { @{Method=$method.Name;Status='Rejected';Reason=$_.Exception.Message} }
    })
    $receipt = @{Commit=$integrity.Commit;Root=$closure.Root;SourceMembers=$closure.Members.Count;SourceEdges=@($closure.Edges | Where-Object Kind -eq SourceMember).Count;ExternalEdges=@($closure.Edges | Where-Object Kind -eq ExternalCLR).Count;Boundaries=$closure.Boundaries;WholeTypeClosed=$closure.Closed;Scope='Extracted original method bodies, not original upstream class initialization';CasesPerCulture=$cases.Count;Differences=0;Admission=$admission;CrossFileCyclePassed=$true}
    Save-Text (Join-Path $directory 'receipt.json') ($receipt | ConvertTo-Json -Depth 12)
    "Source closure: $($closure.Members.Count) methods; $($cases.Count) calls/culture; 0 differences; type boundaries $($closure.Boundaries.Count)"
    $admission | ForEach-Object { "$($_.Method): $($_.Status) $($_.Reason)" }
    return
}
if ($Mode -eq 'OutputContract') {
    Import-PinnedLowering
    $reports = @(foreach ($fixture in @((Join-Path $PSScriptRoot 'fixtures/ProgressLayout.cs'),(Join-Path $build 'android-bindings/JavaNativeTypeManager.cs'))) {
        $name = [IO.Path]::GetFileNameWithoutExtension($fixture)
        $translation = ConvertFrom-CSharp -Path $fixture -ClassOnly
        if (@($translation.Diagnostics | Where-Object Severity -ne Information).Count) { throw "Translation failed: $name" }
        $output = Join-Path $build "output-contract/$name.ps1"
        Save-Text $output $translation.PowerShell
        $sourceCases = @(Get-Content -Raw -LiteralPath ([IO.Path]::ChangeExtension($fixture,'cases.json')) | ConvertFrom-Json).Count
        foreach ($culture in 'en-US','fr-FR') {
            $log = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $PSScriptRoot 'Test-Parity.ps1') -Fixture $fixture -Culture $culture -ClassOnly)
            if ($LASTEXITCODE) { throw "Source parity failed: $name $culture" }
            if ($log[-1] -cne "calls $sourceCases, differences 0") { throw "Unexpected class-only parity count: $name $culture" }
        }
        $report = Test-LoweredOutputContract $output $name $fixture
        $ast = [Management.Automation.Language.Parser]::ParseFile($output,[ref]$null,[ref]$null)
        if (@($ast.EndBlock.Statements | Where-Object { $_ -isnot [Management.Automation.Language.TypeDefinitionAst] }).Count) { throw "Class-only source contains top-level runtime logic: $name" }
        $report.SmaParity = @{CasesPerCulture=$sourceCases;Differences=0;Cultures=@('en-US','fr-FR')}
        $report.Helpers = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -match 'CS2PS'},$true)).Count
        if ($report.Helpers) { throw "Targeted output still requires semantic helper calls: $name" }
        $report
    })
    Save-Text (Join-Path $build 'output-contract/receipt.json') (@{PSLowering='1afabe056235a570da29e268824784557d4f6cdd';QuickPSReference='f1b1c9083d448c3ee893f878122de758849d4022';Outputs=$reports} | ConvertTo-Json -Depth 12)
    foreach ($report in $reports) {
        "$([IO.Path]::GetFileName($report.Source)): helpers $($report.Helpers); $(@($report.Admission | Where-Object Status -eq Admitted).Count) admitted; $(@($report.Admission | Where-Object Status -eq Rejected).Count) compiler gaps"
        $report.Admission | Where-Object Status -eq Rejected | ForEach-Object { "$($_.Method): $($_.Reason)" }
        if ($report.IndependentIL) { "Independent IL: $($report.IndependentIL.CasesPerCulture) calls/culture; 0 differences; deterministic; references $($report.IndependentIL.References -join ', ')" }
    }
    return
}
if ($Mode -eq 'AndroidBindings') {
    $pin = '37f8b4a65cf7eb1fca9808ea7b724e5db1e7dba5'
    $vendor = $AndroidSourceRoot
    $directory = Join-Path $build 'android-bindings'
    $cache = Join-Path $build "cache/android-bindings/$pin"
    $null = [IO.Directory]::CreateDirectory($cache)
    $integrityPath = Join-Path $cache 'integrity.json'
    if (-not (Test-Path -LiteralPath $integrityPath)) {
        & git -C $vendor cat-file -e "${pin}^{commit}"
        if ($LASTEXITCODE) { throw 'Pinned Android source commit is unavailable.' }
        $available = @(& git -C $vendor ls-tree -r --name-only $pin src/Mono.Android external/Java.Interop/src/Java.Interop external/Java.Interop/src/Java.Interop.Tools.TypeNameMappings)
        if ($LASTEXITCODE) { throw 'Pinned Android binding source is unavailable.' }
        $paths = @('LICENSE.TXT','external/Java.Interop/LICENSE','external/Java.Interop/ThirdPartyNotices.txt','src/Mono.Android/Profiles/api-36.xml','src/Mono.Android/Mono.Android.csproj') + @($available | Where-Object {
            $_ -match '^src/Mono.Android/Android.Media/(Audio.*|MediaPlayer|ToneGenerator)\.cs$' -or
            $_ -match '^src/Mono.Android/Android.App/(Activity|ActivityTracker|Application|IntentService|SyncContext)\.cs$' -or
            $_ -match '^src/Mono.Android/Android.OS/(Handler|Message)\.cs$' -or
            $_ -match '^src/Mono.Android/Android.Runtime/(JNIEnv|JNIEnvInit|JNINativeWrapper|JValue|JniHandleOwnership|RuntimeNativeMethods|DynamicMethodNameCounter)\.cs$' -or
            $_ -match '^external/Java.Interop/src/Java.Interop/Java.Interop/(JniEnvironment(\.(Strings|References|Types|Object|Errors|Monitors|Members.Utf8))?|JniTypeSignature|JniArgumentValue|JniObjectReference|JniMethodInfo|JniNativeMethodRegistration)\.cs$' -or
            $_ -match '/Java.Interop.Tools.TypeNameMappings/JavaNativeTypeManager\.cs$'
        })
        $archive = Join-Path $cache 'source.tar'
        & git -C $vendor archive --format=tar --output $archive $pin -- @paths
        if ($LASTEXITCODE) { throw 'Pinned source acquisition failed.' }
        & tar.exe -xf $archive -C $cache
        if ($LASTEXITCODE) { throw 'Pinned source extraction failed.' }
        $integrity = @{Repository='https://github.com/dotnet/android';Commit=$pin;ArchiveSHA256=(Get-FileHash -LiteralPath $archive).Hash;Files=@($paths | ForEach-Object { @{Path=$_;SHA256=(Get-FileHash -LiteralPath (Join-Path $cache $_)).Hash} })}
        Save-Text $integrityPath ($integrity | ConvertTo-Json -Depth 6)
    }
    $integrity = Get-Content -Raw -LiteralPath $integrityPath | ConvertFrom-Json
    $licensePaths = @('external/Java.Interop/LICENSE','external/Java.Interop/ThirdPartyNotices.txt')
    if (@($licensePaths | Where-Object {$_ -notin $integrity.Files.Path}).Count) {
        $licenseArchive = Join-Path $cache 'licenses.tar'
        & git -C $vendor archive --format=tar --output $licenseArchive $pin -- @licensePaths
        if ($LASTEXITCODE) { throw 'Pinned Java.Interop license acquisition failed.' }
        & tar.exe -xf $licenseArchive -C $cache
        if ($LASTEXITCODE) { throw 'Pinned Java.Interop license extraction failed.' }
        $integrity.Files = @($integrity.Files) + @($licensePaths | Where-Object {$_ -notin $integrity.Files.Path} | ForEach-Object { @{Path=$_;SHA256=(Get-FileHash -LiteralPath (Join-Path $cache $_)).Hash} })
        Save-Text $integrityPath ($integrity | ConvertTo-Json -Depth 6)
    }
    if ($integrity.Commit -cne $pin -or (Get-FileHash -LiteralPath (Join-Path $cache 'source.tar')).Hash -cne $integrity.ArchiveSHA256) { throw 'Android source archive identity mismatch.' }
    foreach ($record in $integrity.Files) { if ((Get-FileHash -LiteralPath (Join-Path $cache $record.Path)).Hash -cne $record.SHA256) { throw "Android source digest mismatch: $($record.Path)" } }
    foreach ($license in @{ 'LICENSE.TXT'='LICENSE.dotnet-android.txt'; 'external/Java.Interop/LICENSE'='LICENSE.Java.Interop.txt'; 'external/Java.Interop/ThirdPartyNotices.txt'='ThirdPartyNotices.Java.Interop.txt' }.GetEnumerator()) {
        Save-Text (Join-Path $directory $license.Value) ([IO.File]::ReadAllText((Join-Path $cache $license.Key)))
    }
    # The API XML is the generator's declaration input, including TTS. It is
    # not executable C# and does not establish reference ownership or behavior.
    $apiPath = Join-Path $cache 'src/Mono.Android/Profiles/api-36.xml'
    $settings = [Xml.XmlReaderSettings]::new(); $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit; $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($apiPath,$settings)
    $api = [Xml.XmlDocument]::new(); $api.XmlResolver = $null
    try { $api.Load($reader) } finally { $reader.Dispose() }
    $targets = [ordered]@{
        Audio=@('android.media.AudioTrack','android.media.AudioRecord','android.media.AudioManager','android.media.AudioAttributes','android.media.AudioFormat','android.media.MediaPlayer','android.media.SoundPool')
        Lifecycle=@('android.app.Activity','android.app.Application','android.app.Service','android.app.NativeActivity','android.os.Handler','android.os.Looper','android.app.Application.ActivityLifecycleCallbacks')
        TTS=@('android.speech.tts.TextToSpeech','android.speech.tts.TextToSpeech.OnInitListener','android.speech.tts.UtteranceProgressListener','android.speech.tts.TextToSpeechService','android.speech.tts.SynthesisRequest','android.speech.tts.SynthesisCallback','android.speech.tts.Voice')
    }
    $bindings = [Collections.Generic.List[object]]::new()
    $classes = [Collections.Generic.List[object]]::new()
    foreach ($family in $targets.Keys) {
        foreach ($name in $targets[$family]) {
            $type = @($api.SelectNodes('/api/package/class | /api/package/interface') | Where-Object { ($_.ParentNode.GetAttribute('name') + '.' + $_.GetAttribute('name')) -ceq $name })
            if ($type.Count -ne 1) { throw "Android API target is absent or ambiguous: $name" }
            $classes.Add(@{Family=$family;Type=$name;JniType=$type[0].GetAttribute('jni-signature');BaseType=$type[0].GetAttribute('extends');Interfaces=$type[0].GetAttribute('implements');Members=$type[0].SelectNodes('method | constructor | field').Count})
            foreach ($member in $type[0].SelectNodes('method | constructor | field')) {
                $bindings.Add(@{Family=$family;Type=$name;Kind=$member.LocalName;Name=$member.GetAttribute('name');JniSignature=$member.GetAttribute('jni-signature');Static=$member.GetAttribute('static');Visibility=$member.GetAttribute('visibility');ReturnType=$member.GetAttribute('return');Value=$member.GetAttribute('value');Parameters=@($member.SelectNodes('parameter') | ForEach-Object { @{Name=$_.GetAttribute('name');Type=$_.GetAttribute('type')} });Status='DeclarationOnly';Source='src/Mono.Android/Profiles/api-36.xml'})
            }
        }
    }
    Save-Text (Join-Path $directory 'api-36-bindings.json') (@{Commit=$pin;Platform=$api.DocumentElement.GetAttribute('platform');SourceSHA256=(Get-FileHash -LiteralPath $apiPath).Hash;Classes=@($classes);Members=@($bindings)} | ConvertTo-Json -Depth 10)
    [string[]] $defines = @('NET','JAVA_INTEROP','ENABLE_MARSHAL_METHODS') + @(1..36 | ForEach-Object {"ANDROID_$_"})
    $parseOptions = [Microsoft.CodeAnalysis.CSharp.CSharpParseOptions]::Default.WithPreprocessorSymbols($defines)
    $references = @('System.Threading.dll','System.Threading.Thread.dll','System.Linq.dll','System.Memory.dll','System.Reflection.Emit.dll','System.Reflection.Emit.ILGeneration.dll','System.Collections.Concurrent.dll','System.Runtime.InteropServices.dll','System.ObjectModel.dll','System.Diagnostics.Debug.dll' | ForEach-Object { Join-Path $PSHOME $_ } | Where-Object {Test-Path -LiteralPath $_})
    foreach ($referenceRoot in $ReferencePath) {
        $resolved = (Resolve-Path -LiteralPath $referenceRoot).Path
        if ($resolved.TrimEnd('\','/') -ieq $PSHOME.TrimEnd('\','/')) { continue }
        if (Test-Path -LiteralPath $resolved -PathType Container) { $references += @(Get-ChildItem -LiteralPath $resolved -Filter '*.dll' -File | ForEach-Object FullName) }
        else { $references += $resolved }
    }
    $attempts = [Collections.Generic.List[object]]::new()
    $sourceMethods = [Collections.Generic.List[object]]::new()
    foreach ($record in $integrity.Files | Where-Object Path -Like '*.cs') {
        $path = Join-Path $cache $record.Path
        $tree = [Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText([IO.File]::ReadAllText($path),$parseOptions)
        foreach ($node in $tree.GetRoot().DescendantNodes() | Where-Object {$_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.BaseMethodDeclarationSyntax]}) {
            $name = if ($node -is [Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax]) {$node.Identifier.ValueText} else {$node.GetType().Name}
            $sourceMethods.Add(@{Source=$record.Path;Line=$node.GetLocation().GetLineSpan().StartLinePosition.Line+1;Name=$name;Parameters=$node.ParameterList.ToString();Unsafe='unsafe' -in @($node.Modifiers | ForEach-Object Text);Generic=$node -is [Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax] -and $null -ne $node.TypeParameterList;Extern='extern' -in @($node.Modifiers | ForEach-Object Text);HasBody=$null -ne $node.Body -or $null -ne $node.ExpressionBody})
        }
        $translationException = $null
        try { $result = ConvertFrom-CSharp -Path $path -Define $defines -ReferencePath $references }
        catch { $translationException = $_.Exception.Message; $result = [pscustomobject]@{PowerShell="throw [NotSupportedException]::new('CS2PS translation failed; see source-inventory.json.')`n";Diagnostics=@()} }
        $compilerErrors = @($script:Model.Compilation.GetDiagnostics() | Where-Object Severity -eq Error | ForEach-Object { @{Id=$_.Id;Line=$_.Location.GetLineSpan().StartLinePosition.Line+1;Message=$_.GetMessage()} })
        $errors = @($result.Diagnostics | Where-Object Severity -ne Information)
        $status = if ($translationException) {'TranslatorFailure'} elseif ($compilerErrors.Count) {'CSharpBindingBlocked'} elseif ($errors.Count) {'TranslationBlocked'} elseif (-not $result.Methods.Count) {'NoExecutableMethods'} else {'TranslatedUnverified'}
        $output = Join-Path $directory ('attempts/' + $record.Path + '.ps1')
        Save-Text $output $result.PowerShell
        $attempts.Add(@{Source=$record.Path;SHA256=$record.SHA256;Status=$status;CompilerErrors=$compilerErrors;Diagnostics=@($result.Diagnostics);TranslatorFailure=$translationException;Output=$output;Parity='NotRun';Lowering='NotRun'})
    }
    Save-Text (Join-Path $directory 'source-inventory.json') (@{Commit=$pin;Defines=$defines;References=@($references | ForEach-Object {@{Path=$_;SHA256=(Get-FileHash -LiteralPath $_).Hash}});Scope='Selected source files, each translated independently; not an SDK dependency closure';Methods=@($sourceMethods);Attempts=@($attempts)} | ConvertTo-Json -Depth 10)
    # First independently executable upstream logic. Original method declarations
    # and bodies are preserved in a minimal comparison host; no Android stubs.
    $typeNamePath = @($integrity.Files | Where-Object Path -Like '*/JavaNativeTypeManager.cs')[0].Path
    $typeNameTree = [Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText([IO.File]::ReadAllText((Join-Path $cache $typeNamePath)),$parseOptions)
    $selection = @($typeNameTree.GetRoot().DescendantNodes() | Where-Object {
        $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax] -and
        ($_.Identifier.ValueText -in 'ToPascalCase','IsPackageNamePreservedForAssembly' -or
        ($_.Identifier.ValueText -ceq 'ToJniName' -and $_.ParameterList.Parameters.Count -eq 2 -and $_.ParameterList.Parameters[0].Type.ToString() -ceq 'string'))
    })
    if ($selection.Count -ne 3) { throw 'Upstream JNI naming selection changed.' }
    $slicePath = Join-Path $directory 'JavaNativeTypeManager.cs'
    Save-Text $slicePath ("// Original method bodies: dotnet/android $pin $typeNamePath`nusing System;`npublic static class JavaNativeTypeManager {`n" + (($selection | ForEach-Object ToString) -join "`n") + "`n}`n")
    $cases = [Collections.Generic.List[object]]::new()
    foreach ($pair in @(@($null,0),@($null,1),@('',0),@('',1),@('I',0),@('I',1),@('I',2),@('java/lang/String',1),@('[I',1),@('Ljava/lang/String;',2),@('I',-1))) { $cases.Add(@{Type='JavaNativeTypeManager';Method='ToJniName';Arguments=$pair}) }
    foreach ($pair in @(@($null,2),@('',2),@('a',2),@('ab',2),@('aBC',2),@('i',1),@('éclair',2),@('x',0),@('value',-1))) { $cases.Add(@{Type='JavaNativeTypeManager';Method='ToPascalCase';Arguments=$pair}) }
    foreach ($value in @($null,'','Mono.Android','mono.android','System.Private.CoreLib')) { $cases.Add(@{Type='JavaNativeTypeManager';Method='IsPackageNamePreservedForAssembly';Arguments=@($value)}) }
    Save-Text (Join-Path $directory 'JavaNativeTypeManager.cases.json') ($cases | ConvertTo-Json -Depth 5)
    $slice = ConvertFrom-CSharp -Path $slicePath
    if (@($slice.Diagnostics | Where-Object Severity -ne Information).Count) { throw "Upstream JNI helper translation failed: $($slice.Diagnostics | ConvertTo-Json -Compress)" }
    $psPath = Join-Path $directory 'JavaNativeTypeManager.ps1'
    Save-Text $psPath $slice.PowerShell
    Import-PinnedLowering
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($psPath,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Upstream JNI helper SMA parse failed.' }
    $admission = @(foreach ($method in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionMemberAst] -and -not $node.IsConstructor},$true)) {
        try { $null = ConvertTo-TypedExpression -MethodAst $method; @{Method=$method.Name;Status='Admitted';Reason=''} } catch { @{Method=$method.Name;Status='Rejected';Reason=$_.Exception.Message} }
    })
    foreach ($culture in 'en-US','fr-FR') {
        & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $PSScriptRoot 'Test-Parity.ps1') -Fixture $slicePath -Culture $culture
        if ($LASTEXITCODE) { throw "JNI naming parity failed: $culture" }
        & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $PSScriptRoot 'Test-Parity.ps1') -Fixture (Join-Path $PSScriptRoot 'android/ConditionalBinding.cs') -Culture $culture -Define ANDROID_36
        if ($LASTEXITCODE) { throw "Android define parity failed: $culture" }
    }
    $admittedNames = @($admission | Where-Object {$_.Status -eq 'Admitted'} | ForEach-Object {$_.Method})
    $loweredReceipt = $null
    if ($admittedNames.Count) {
        $contract = Test-LoweredOutputContract $psPath JavaNativeTypeManager $slicePath
        $loweredReceipt = $contract.IndependentIL
        $loweredReceipt.Methods = $admittedNames
    }
    $receipt = @{Commit=$pin;Platform=36;Classes=$classes.Count;ApiMembers=$bindings.Count;SourceFiles=$attempts.Count;SourceMethods=$sourceMethods.Count;Attempts=@($attempts | ForEach-Object {@{Source=$_.Source;Status=$_.Status;CompilerErrors=$_.CompilerErrors.Count;Diagnostics=$_.Diagnostics.Count}});HelperMethods=3;HelperCasesPerCulture=$cases.Count;ConditionalCasesPerCulture=2;Cultures=@('en-US','fr-FR');Differences=0;HelperAdmission=$admission;DeviceExecution='NotRun';Scope='Declaration inventory and independent managed naming logic; not executable audio/lifecycle/TTS bindings';PowerShell=$PSVersionTable.PSVersion.ToString();Runtime=[Environment]::Version.ToString()}
    $receipt.Lowered = $loweredReceipt
    Save-Text (Join-Path $directory 'receipt.json') ($receipt | ConvertTo-Json -Depth 10)
    foreach ($family in $targets.Keys) { "$family`: $(@($classes | Where-Object Family -eq $family).Count) classes, $(@($bindings | Where-Object Family -eq $family).Count) declarations" }
    "$($attempts.Count) C# files, $($sourceMethods.Count) methods/constructors inventoried"
    $attempts | Group-Object Status | Select-Object Name,Count
    "JNI helpers: 3 methods, $($cases.Count) parity calls per culture, 0 differences"
    $admission | ForEach-Object { "$($_.Method): $($_.Status) $($_.Reason)" }
    "Receipt: $(Join-Path $directory 'receipt.json')"
    if (@($attempts | Where-Object Status -eq 'TranslatorFailure').Count) { throw 'Batch exposed translator failures; see source-inventory.json.' }
    return
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
            @{Name='Call mappings';Arguments=@('-Fixture',(Join-Path $PSScriptRoot 'call-matrix/Calls.cs'));Expected=33}
        )) {
            $arguments = $suite.Arguments
            $log = @(& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $PSScriptRoot 'Test-Parity.ps1') -Culture $culture -ApiCatalogPath $ApiCatalogPath -TraceBinding @arguments)
            if ($LASTEXITCODE) { throw "Call-matrix parity failed: $culture $($suite.Name); $($log -join '; ')" }
            $summary = @($log | Where-Object { $_ -match '^calls ([0-9]+), differences ([0-9]+)$' })[-1]
            if ($summary -notmatch '^calls ([0-9]+), differences 0$' -or [int]$Matches[1] -ne $suite.Expected) { throw "Unexpected parity count: $summary" }
            $total += $suite.Expected
            $parity.Add(@{Culture=$culture;Suite=$suite.Name;Calls=$suite.Expected;Differences=0})
        }
        "$culture`: $total calls, 0 differences (269 existing + 33 binding/string regressions)"
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
                if ([IO.File]::ReadAllText($golden) -cne $result.PowerShell) {
                    $backup = Join-Path $build ('golden-backup/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '/' + [IO.Path]::GetFileName($golden))
                    Save-Text $backup ([IO.File]::ReadAllText($golden))
                    Save-Text $golden $result.PowerShell
                }
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
