# Metadata discovery does not load or execute the assemblies being inventoried.
function Get-CS2PSApiId($Symbol) {
    [Microsoft.CodeAnalysis.DocumentationCommentId]::CreateDeclarationId($Symbol.OriginalDefinition)
}

function Get-CS2PSApiAttributes($Symbol) {
    foreach ($attribute in $Symbol.GetAttributes()) {
        [ordered]@{
            Type = $attribute.AttributeClass.ToString()
            Arguments = @($attribute.ConstructorArguments | ForEach-Object { $_.ToString() })
            NamedArguments = @($attribute.NamedArguments | ForEach-Object { @{Name=$_.Key; Value=$_.Value.ToString()} })
        }
    }
}

function Get-CS2PSCallPolicy($Method) {
    # This describes the existing conservative emission rule, not a blanket binder proof.
    $reasons = [Collections.Generic.List[string]]::new()
    if ($Method.IsGenericMethod) { $reasons.Add('Generic method requires an admitted generic invocation rule.') }
    if ($Method.ReturnsByRef -or $Method.ReturnsByRefReadonly) { $reasons.Add('By-reference return requires an explicit representation.') }
    foreach ($parameter in $Method.Parameters) {
        if ($parameter.IsParams) { $reasons.Add('Params binding requires call-site expansion analysis.') }
        if ($parameter.RefKind.ToString() -ne 'None') { $reasons.Add('Ref/out/in binding requires explicit cell and mutation handling.') }
        if ($parameter.Type.IsRefLikeType -or $parameter.Type.TypeKind.ToString() -in 'Pointer','FunctionPointer') { $reasons.Add('Ref-like or pointer argument requires an admitted representation.') }
        if ($parameter.Type.SpecialType.ToString() -in 'System_Object','System_String') { $reasons.Add('Object/string argument requires null and runtime-type overload analysis.') }
    }
    [pscustomobject]@{ Candidate = $reasons.Count -eq 0; Reasons = @($reasons); Status = 'RequiresSiteAnalysis'; Rule='CS2PS conservative exact-typed-call policy'; Evidence='https://github.com/PowerShell/PowerShell/blob/149ab5cd6cad34869177f86ef9a3da8414f85dc6/src/System.Management.Automation/engine/CoreAdapter.cs' }
}

function New-CS2PSApiCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $OutputDirectory, [string[]] $ReferencePath = @($PSHOME))
    Initialize-Roslyn
    $null = [IO.Directory]::CreateDirectory($OutputDirectory)
    $manifestPath = Join-Path $OutputDirectory 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath) { throw 'Use a new catalog generation directory; existing inventories are retained.' }
    $files = [Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    $skipped = [Collections.Generic.List[object]]::new()
    foreach ($rootPath in $ReferencePath) {
        $item = Get-Item -LiteralPath $rootPath -ErrorAction Stop
        $candidates = if ($item.PSIsContainer) { Get-ChildItem -LiteralPath $item.FullName -Filter '*.dll' -File } else { @($item) }
        foreach ($file in $candidates) {
            try { $identity = [Reflection.AssemblyName]::GetAssemblyName($file.FullName) }
            catch [BadImageFormatException] { $skipped.Add(@{File=$file.Name; Reason='Native or non-assembly image'}); continue }
            if ($files.ContainsKey($identity.FullName)) {
                if ((Get-FileHash -LiteralPath $files[$identity.FullName].Path).Hash -cne (Get-FileHash -LiteralPath $file.FullName).Hash) { throw "Conflicting assembly images: $($identity.FullName)" }
                continue
            }
            $files.Add($identity.FullName, @{Path=$file.FullName; Name=$identity.Name; Identity=$identity.FullName; SHA256=(Get-FileHash -LiteralPath $file.FullName).Hash})
        }
    }
    $refs = [Collections.Generic.List[Microsoft.CodeAnalysis.MetadataReference]]::new()
    foreach ($file in $files.Values) { $refs.Add([Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile($file.Path)) }
    # Metadata-only semantic compilation. No Emit, source compilation, or inspected-code execution.
    $options = [Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
    $compilation = [Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('CS2PS.ApiInventory', [Microsoft.CodeAnalysis.SyntaxTree[]]@(), $refs, $options)
    $assemblies = [Collections.Generic.List[object]]::new()
    $memberCount = 0; $typeCount = 0; $methodCount = 0; $forwardCount = 0
    foreach ($reference in $refs) {
        $assembly = $compilation.GetAssemblyOrModuleSymbol($reference)
        if ($assembly -isnot [Microsoft.CodeAnalysis.IAssemblySymbol]) { throw "Not an assembly reference: $($reference.Display)" }
        $file = $files[$assembly.Identity.ToString()]
        if (-not $file) { throw "Assembly identity differs from image: $($reference.Display)" }
        $entries = [Collections.Generic.List[object]]::new()
        $queue = [Collections.Generic.Queue[object]]::new()
        $queue.Enqueue($assembly.GlobalNamespace)
        $localTypes = 0; $localMethods = 0
        while ($queue.Count) {
            $container = $queue.Dequeue()
            # Roslyn metadata symbols implement this interface explicitly.
            $getMembers = [Microsoft.CodeAnalysis.INamespaceOrTypeSymbol].GetMethod('GetMembers',[type[]]@())
            foreach ($symbol in $getMembers.Invoke($container,[object[]]@())) {
                if ($symbol -is [Microsoft.CodeAnalysis.INamespaceSymbol]) { $queue.Enqueue($symbol); continue }
                if ($symbol.DeclaredAccessibility.ToString() -notin 'Public','Protected','ProtectedOrInternal') { continue }
                $id = Get-CS2PSApiId $symbol
                if (-not $id) { continue }
                $record = [ordered]@{
                    Id=$id; Kind=$symbol.Kind.ToString(); Name=$symbol.Name
                    Signature=$symbol.ToString(); Accessibility=$symbol.DeclaredAccessibility.ToString()
                    Static=$symbol.IsStatic; Attributes=@(Get-CS2PSApiAttributes $symbol)
                    Semantics='Unreviewed'; Lowering='Unknown'
                }
                if ($symbol -is [Microsoft.CodeAnalysis.INamedTypeSymbol]) {
                    $queue.Enqueue($symbol); $localTypes++
                    $record.TypeKind = $symbol.TypeKind.ToString()
                    $record.BaseType = if ($symbol.BaseType) { $symbol.BaseType.ToString() } else { $null }
                    $record.Interfaces = @($symbol.Interfaces | ForEach-Object { $_.ToString() })
                    $record.RefLike = $symbol.IsRefLikeType
                } else { $record.DeclaringType = Get-CS2PSApiId $symbol.ContainingType }
                if ($symbol -is [Microsoft.CodeAnalysis.IMethodSymbol]) {
                    $localMethods++
                    $record.MethodKind=$symbol.MethodKind.ToString(); $record.Arity=$symbol.Arity
                    $record.ReturnType=$symbol.ReturnType.ToString(); $record.ReturnNullable=$symbol.ReturnNullableAnnotation.ToString()
                    $record.ReturnsByRef=$symbol.ReturnsByRef; $record.ReturnsByRefReadonly=$symbol.ReturnsByRefReadonly
                    $record.Virtual=$symbol.IsVirtual; $record.Abstract=$symbol.IsAbstract; $record.Override=$symbol.IsOverride
                    $record.Parameters = @($symbol.Parameters | ForEach-Object {
                        [ordered]@{Name=$_.Name; Type=$_.Type.ToString(); RefKind=$_.RefKind.ToString(); Nullable=$_.NullableAnnotation.ToString(); Params=$_.IsParams; Optional=$_.IsOptional; HasDefault=$_.HasExplicitDefaultValue; Default=if ($_.HasExplicitDefaultValue) { $_.ExplicitDefaultValue } else { $null }; Attributes=@(Get-CS2PSApiAttributes $_)}
                    })
                    $record.TypeParameters = @($symbol.TypeParameters | ForEach-Object {
                        @{Name=$_.Name; Constraints=@($_.ConstraintTypes | ForEach-Object { $_.ToString() }); ReferenceType=$_.HasReferenceTypeConstraint; ValueType=$_.HasValueTypeConstraint; Constructor=$_.HasConstructorConstraint; Unmanaged=$_.HasUnmanagedTypeConstraint; NotNull=$_.HasNotNullConstraint}
                    })
                    $record.CallPolicy = Get-CS2PSCallPolicy $symbol
                } elseif ($symbol -is [Microsoft.CodeAnalysis.IPropertySymbol]) {
                    $record.Type=$symbol.Type.ToString(); $record.Getter=if ($symbol.GetMethod) { Get-CS2PSApiId $symbol.GetMethod } else { $null }; $record.Setter=if ($symbol.SetMethod) { Get-CS2PSApiId $symbol.SetMethod } else { $null }
                } elseif ($symbol -is [Microsoft.CodeAnalysis.IFieldSymbol]) {
                    $record.Type=$symbol.Type.ToString(); $record.Const=$symbol.IsConst; $record.ReadOnly=$symbol.IsReadOnly
                    if ($symbol.HasConstantValue) { $record.Constant = $symbol.ConstantValue }
                } elseif ($symbol -is [Microsoft.CodeAnalysis.IEventSymbol]) { $record.Type=$symbol.Type.ToString() }
                $entries.Add($record)
            }
        }
        $dependencies = foreach ($module in $assembly.Modules) {
            foreach ($dependency in $module.ReferencedAssemblies) {
                $resolved = @($files.Values | Where-Object Name -CEQ $dependency.Name)
                @{Requested=$dependency.ToString(); Resolved=@($resolved.Identity); Status=if ($resolved.Count -eq 0) {'Missing'} elseif ($resolved.Identity -ccontains $dependency.ToString()) {'Exact'} else {'DifferentVersionOrIdentity'}}
            }
        }
        $forwards = @($assembly.GetForwardedTypes() | ForEach-Object { @{Type=(Get-CS2PSApiId $_); Assembly=$_.ContainingAssembly.Identity.ToString(); Unresolved=$_.TypeKind.ToString() -eq 'Error'} })
        $shardName = $file.SHA256 + '.json'
        $shardPath = Join-Path $OutputDirectory $shardName
        $payload = @{Identity=$file.Identity; Entries=@($entries); Dependencies=@($dependencies); ForwardedTypes=$forwards; Attributes=@(Get-CS2PSApiAttributes $assembly)}
        [IO.File]::WriteAllText($shardPath, ($payload | ConvertTo-Json -Depth 18 -Compress), [Text.UTF8Encoding]::new($false))
        $assemblies.Add(@{Name=$file.Name; Identity=$file.Identity; Path=$file.Path; SHA256=$file.SHA256; Shard=$shardName; ShardSHA256=(Get-FileHash -LiteralPath $shardPath).Hash; Types=$localTypes; Methods=$localMethods; Members=$entries.Count; Dependencies=@($dependencies); ForwardedTypes=$forwards.Count})
        $typeCount += $localTypes; $methodCount += $localMethods; $memberCount += $entries.Count; $forwardCount += $forwards.Count
        Write-Verbose "$($file.Name): $localTypes types; $($entries.Count) members"
    }
    $manifest = [ordered]@{
        Schema=1; PowerShell=$PSVersionTable.PSVersion.ToString(); Runtime=[Environment]::Version.ToString()
        SMA=[Management.Automation.PSObject].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute],$false)[0].InformationalVersion
        CoreLib=[object].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute],$false)[0].InformationalVersion
        Scope='Public/protected declared managed APIs in supplied assembly roots; recursive namespaces/types and assembly-reference graph. Not all NuGet packages or native runtime exports.'
        Assemblies=@($assemblies); Skipped=@($skipped); Types=$typeCount; Methods=$methodCount; Members=$memberCount; ForwardedTypes=$forwardCount
        DiscoverySources=@('https://github.com/dotnet/apisof.net','https://github.com/dotnet/dotnet-api-docs','https://github.com/dotnet/core/blob/main/release-notes/11.0/releases.json','https://www.newtonsoft.com/json/help/html/Introduction.htm')
    }
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ManifestPath=$manifestPath; Assemblies=$assemblies.Count; Types=$typeCount; Methods=$methodCount; Members=$memberCount; ForwardedTypes=$forwardCount; Skipped=$skipped.Count}
}

function Import-CS2PSApiCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $digest = (Get-FileHash -LiteralPath $resolved).Hash
    if ($script:ImportedApiCatalog -and $script:ImportedApiCatalog.Path -ceq $resolved -and $script:ImportedApiCatalog.Digest -ceq $digest) { return $script:ImportedApiCatalog.Catalog }
    $manifest = Get-Content -Raw -LiteralPath $resolved | ConvertFrom-Json
    if ($manifest.Schema -ne 1) { throw 'Unsupported API catalog schema.' }
    if ($manifest.Runtime -cne [Environment]::Version.ToString() -or $manifest.PowerShell -cne $PSVersionTable.PSVersion.ToString()) { throw 'API catalog toolchain differs from the executing toolchain.' }
    if ($manifest.SMA -cne [Management.Automation.PSObject].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute],$false)[0].InformationalVersion -or $manifest.CoreLib -cne [object].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute],$false)[0].InformationalVersion) { throw 'API catalog runtime source identity differs from the executing toolchain.' }
    $assemblies = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($assembly in $manifest.Assemblies) { $assemblies.Add($assembly.Identity,$assembly) }
    $catalog = [pscustomobject]@{Directory=[IO.Path]::GetDirectoryName($resolved); Manifest=$manifest; Assemblies=$assemblies; Loaded=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)}
    $script:ImportedApiCatalog = @{Path=$resolved; Digest=$digest; Catalog=$catalog}
    $catalog
}

function Find-CS2PSApi {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Catalog, [string] $AssemblyIdentity, [string] $Id, [string] $Pattern, [ValidateRange(1,1000)][int] $Limit=20)
    $matches = 0
    foreach ($identity in $Catalog.Assemblies.Keys | Sort-Object -CaseSensitive) {
        if ($AssemblyIdentity -and $identity -cne $AssemblyIdentity) { continue }
        $assembly = $Catalog.Assemblies[$identity]
        if (-not $Catalog.Loaded.ContainsKey($identity)) {
            $path = Join-Path $Catalog.Directory $assembly.Shard
            if ([IO.Path]::GetFileName($assembly.Shard) -cne $assembly.Shard -or (Get-FileHash -LiteralPath $path).Hash -cne $assembly.ShardSHA256) { throw "API shard integrity failure: $identity" }
            if ((Get-FileHash -LiteralPath $assembly.Path).Hash -cne $assembly.SHA256) { throw "API assembly changed: $identity" }
            $payload = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
            if ($payload.Identity -cne $identity) { throw 'API shard identity mismatch.' }
            $index = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
            foreach ($entry in $payload.Entries) {
                if (-not $index.ContainsKey($entry.Id)) { $index.Add($entry.Id,[Collections.Generic.List[object]]::new()) }
                # Metadata can contain declarations sharing an XML documentation ID.
                # Preserve every variant; exact translation lookup fails closed on ambiguity.
                $index[$entry.Id].Add($entry)
            }
            $Catalog.Loaded.Add($identity,$index)
        }
        $index = $Catalog.Loaded[$identity]
        $candidates = if ($Id) { if ($index.ContainsKey($Id)) { $index[$Id].ToArray() } else { @() } } else { foreach ($variants in $index.Values) { $variants.ToArray() } }
        foreach ($entry in $candidates) {
            if ($Pattern -and $entry.Id -notlike $Pattern) { continue }
            [pscustomobject]@{Assembly=$identity; Api=$entry}
            $matches++
            if ($matches -ge $Limit) { return }
        }
    }
}

function Get-CS2PSApiDependencyClosure {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Catalog, [Parameter(Mandatory)][string] $AssemblyIdentity, [switch] $ExactOnly)
    if (-not $Catalog.Assemblies.ContainsKey($AssemblyIdentity)) { throw 'Dependency root is not in this catalog.' }
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $queue = [Collections.Generic.Queue[string]]::new()
    $edges = [Collections.Generic.List[object]]::new()
    $queue.Enqueue($AssemblyIdentity)
    while ($queue.Count) {
        $current = $queue.Dequeue()
        if (-not $visited.Add($current)) { continue }
        foreach ($dependency in $Catalog.Assemblies[$current].Dependencies) {
            $edges.Add(@{From=$current; Requested=$dependency.Requested; Resolved=$dependency.Resolved; Status=$dependency.Status})
            # Follow a unique installed candidate for discovery, retaining identity differences.
            # This graph does not assert that the runtime can bind every edge.
            if ($dependency.Status -ceq 'Exact' -and $Catalog.Assemblies.ContainsKey($dependency.Requested)) { $queue.Enqueue($dependency.Requested) }
            elseif (-not $ExactOnly -and @($dependency.Resolved).Count -eq 1 -and $Catalog.Assemblies.ContainsKey($dependency.Resolved[0])) { $queue.Enqueue($dependency.Resolved[0]) }
        }
    }
    [pscustomobject]@{Assemblies=@($visited | Sort-Object -CaseSensitive); Edges=@($edges); Missing=@($edges | Where-Object Status -CEQ 'Missing'); IdentityMismatches=@($edges | Where-Object Status -CEQ 'DifferentVersionOrIdentity'); ExactOnly=[bool]$ExactOnly; Scope='Assembly-reference discovery graph; not execution or per-method dependency closure'}
}
