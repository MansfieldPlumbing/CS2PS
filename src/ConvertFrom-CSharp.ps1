#requires -Version 7.4
<#
.SYNOPSIS
    Translates C# static methods into typed, idiomatic PowerShell functions.
.DESCRIPTION
    Parses C# with Roslyn from the running PowerShell's own $PSHOME and uses its
    semantic model so C#'s meaning is carried across explicitly: integer
    division truncates, string equality is case-sensitive, string
    concatenation stays concatenation, narrowing casts truncate. Static methods
    become advanced functions with typed parameters and [OutputType]; method
    names map to approved verbs. Constructs outside the supported subset are
    reported as diagnostics and marked in the output, never guessed.

    The fixture-backed subset includes array/List loops, switches, simple
    classes and structs, ref/out parameters, formatting, fixed-width integer
    arithmetic, bit operations, UTF-16 arithmetic, exceptions and nullable
    primitive values. Unsupported input is marked and fails closed.
.OUTPUTS
    An object with the generated PowerShell text and its diagnostics.
#>
. (Join-Path $PSScriptRoot 'DotNetApiCatalog.ps1')

function ConvertFrom-CSharp {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')] [string] $Path,
        [Parameter(Mandatory, ParameterSetName = 'Source')] [string] $Source,
        [string] $ApiCatalogPath,
        [string[]] $ReferencePath = @()
    )
    Initialize-Roslyn
    $script:ApiCatalog = if ($ApiCatalogPath) { Import-CS2PSApiCatalog -Path $ApiCatalogPath } else { $null }
    $script:ApiCalls = [Collections.Generic.List[object]]::new()
    if ($Path) { $Source = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path) }

    $tree = [Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($Source)
    $refs = [System.Collections.Generic.List[Microsoft.CodeAnalysis.MetadataReference]]::new()
    $runtimeDir = [IO.Path]::GetDirectoryName([object].Assembly.Location)
    foreach ($n in 'System.Private.CoreLib.dll', 'System.Runtime.dll', 'System.Collections.dll', 'System.Console.dll') {
        $refs.Add([Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile([IO.Path]::Combine($runtimeDir, $n)))
    }
    foreach ($reference in $ReferencePath) { $refs.Add([Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile((Resolve-Path -LiteralPath $reference).Path)) }
    $options = [Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
    $compilation = [Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('CS2PS', [Microsoft.CodeAnalysis.SyntaxTree[]]@($tree), $refs, $options)
    $script:Model = $compilation.GetSemanticModel($tree)
    $script:Diagnostics = [System.Collections.Generic.List[object]]::new()
    $script:Methods = [System.Collections.Generic.List[object]]::new()
    $script:SourceTypes = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $script:MethodNames = @{}
    $script:ClassMethods = @{}
    $script:ClassContext = $false
    $script:Names = @{}
    $script:NameScopes = @{}
    $script:Renames = [Collections.Generic.List[object]]::new()
    $script:GeneratedNames = @{}
    $script:GeneratedScopes = @{}
    $script:StructTypes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $script:UnitId = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Source))).Substring(0,12)

    $errors = @($compilation.GetDiagnostics() | Where-Object { $_.Severity -eq [Microsoft.CodeAnalysis.DiagnosticSeverity]::Error })
    if ($errors.Count) {
        foreach ($error in $errors) { Add-Diagnostic $error "C# compiler diagnostic $($error.Id)" }
        $marked = ($script:Diagnostics | ForEach-Object { "# CS2PS: unsupported at line $($_.Line): $($_.Message)" }) -join "`n"
        return [pscustomobject]@{ PowerShell = $marked + "`nthrow [NotSupportedException]::new('C# input has compiler diagnostics.')`n"; Diagnostics = $script:Diagnostics.ToArray(); Methods = @() }
    }
    foreach ($node in $tree.GetRoot().DescendantNodes() | Where-Object { $_.GetType().Name -in 'AttributeListSyntax','EnumDeclarationSyntax','DelegateDeclarationSyntax','GlobalStatementSyntax' }) { Add-Diagnostic $node "declaration $($node.GetType().Name)" }

    $out = [System.Text.StringBuilder]::new()
    $helpers = @'
# C# element access throws rather than accepting PowerShell negative indices.
function Get-CS2PSElement($collection, [int] $index) {
    if ($null -eq $collection) { throw [NullReferenceException]::new() }
    $count = if ($collection -is [array] -or $collection -is [string]) { $collection.Length } else { $collection.Count }
    if ($index -lt 0 -or $index -ge $count) {
        if ($collection -is [array] -or $collection -is [string]) { throw [IndexOutOfRangeException]::new() }
        throw [ArgumentOutOfRangeException]::new('index')
    }
    return ,$collection[$index]
}
function Set-CS2PSElement($collection, [int] $index, $value) {
    $null = Get-CS2PSElement $collection $index
    $collection[$index] = $value
    return ,$value
}
function Get-CS2PSReceiver($value) {
    if ($null -eq $value) { throw [NullReferenceException]::new() }
    return ,$value
}
function Test-CS2PSConstant($left, $right) {
    if ($null -eq $left -or $null -eq $right) { return $null -eq $left -and $null -eq $right }
    if ($left -is [string] -or $right -is [string]) { return [string]::Equals($left, $right, [StringComparison]::Ordinal) }
    if ($left -is [char] -or $right -is [char]) { return Compare-CS2PSInteger $left $right '==' }
    return $left -ceq $right
}
function Get-CS2PSException($exception) {
    while ($exception -is [System.Management.Automation.RuntimeException] -and $exception.InnerException) { $exception = $exception.InnerException }
    return ,$exception
}
function Get-CS2PSThrowException($value) {
    if ($null -eq $value) { return [NullReferenceException]::new() }
    return ,$value
}
function Invoke-CS2PSRuntime([type] $type, $receiver, [string] $name, [type[]] $parameterTypes, [object[]] $arguments, [bool] $static) {
    if (-not $static -and $null -eq $receiver) { throw [NullReferenceException]::new() }
    $flags = if ($static) { [Reflection.BindingFlags]'Public,Static' } else { [Reflection.BindingFlags]'Public,Instance' }
    $method = $type.GetMethod($name, $flags, $null, $parameterTypes, $null)
    if (-not $method) { throw [MissingMethodException]::new($type.FullName, $name) }
    $cells = @{}
    for ($i = 0; $i -lt $arguments.Length; $i++) {
        if ($parameterTypes[$i].IsByRef) { $cells[$i] = $arguments[$i]; $arguments[$i] = $arguments[$i].Value }
    }
    try { return ,$method.Invoke($receiver, $arguments) }
    catch [Reflection.TargetInvocationException] { throw $_.Exception.InnerException }
    finally { foreach ($i in $cells.Keys) { $cells[$i].Value = $arguments[$i] } }
}
function Convert-CS2PSInteger($value, [string] $type, [bool] $checked) {
    if ($value -is [char]) { $value = [int]$value }
    $wide = [Numerics.BigInteger]$value
    $target = if ($type -eq 'char') { [ushort] } else { [type]$type }
    $result = if ($checked) { $target::CreateChecked[Numerics.BigInteger]($wide) } else { $target::CreateTruncating[Numerics.BigInteger]($wide) }
    if ($type -eq 'char') { return [char]$result }
    return $result
}
function Invoke-CS2PSInteger($left, $right, [string] $operator, [string] $type, [bool] $checked) {
    if ($left -is [char]) { $left = [int]$left }; if ($right -is [char]) { $right = [int]$right }
    $l = [Numerics.BigInteger]$left; $r = [Numerics.BigInteger]$right
    $value = switch ($operator) {
        '+' { $l + $r } '-' { $l - $r } '*' { $l * $r }
        '/' {
            if ($r.IsZero) { throw [DivideByZeroException]::new() }
            # Signed minimum / -1 throws even in an unchecked C# context.
            if ((($type -eq 'int' -and $l -eq [int]::MinValue) -or ($type -eq 'long' -and $l -eq [long]::MinValue)) -and $r -eq -1) { throw [OverflowException]::new() }
            [Numerics.BigInteger]::Divide($l, $r)
        }
        '%' {
            if ($r.IsZero) { throw [DivideByZeroException]::new() }
            if ((($type -eq 'int' -and $l -eq [int]::MinValue) -or ($type -eq 'long' -and $l -eq [long]::MinValue)) -and $r -eq -1) { throw [OverflowException]::new() }
            [Numerics.BigInteger]::Remainder($l, $r)
        }
        '&' { [Numerics.BigInteger]::op_BitwiseAnd($l, $r) }
        '|' { [Numerics.BigInteger]::op_BitwiseOr($l, $r) }
        '^' { [Numerics.BigInteger]::op_ExclusiveOr($l, $r) }
        '~' { [Numerics.BigInteger]::op_OnesComplement($l) }
        '<<' {
            $mask = if ($type -in 'long','ulong') { 63 } else { 31 }
            [Numerics.BigInteger]::op_LeftShift($l, ([int]$right -band $mask))
        }
        '>>' {
            $mask = if ($type -in 'long','ulong') { 63 } else { 31 }
            [Numerics.BigInteger]::op_RightShift($l, ([int]$right -band $mask))
        }
        '>>>' {
            $bits = if ($type -in 'long','ulong') { 64 } else { 32 }
            if ($l.Sign -lt 0) { $l += [Numerics.BigInteger]::Pow(2, $bits) }
            [Numerics.BigInteger]::op_RightShift($l, ([int]$right -band ($bits - 1)))
        }
        default { throw [NotSupportedException]::new('Integer operator') }
    }
    Convert-CS2PSInteger $value $type $checked
}
function Invoke-CS2PSBoolean([bool] $left, [bool] $right, [string] $operator) {
    switch ($operator) { '&' { return $left -and $right } '|' { return $left -or $right } '^' { return $left -ne $right } }
}
function Compare-CS2PSInteger($left, $right, [string] $operator) {
    if ($left -is [char]) { $left = [int]$left }; if ($right -is [char]) { $right = [int]$right }
    $comparison = [Numerics.BigInteger]::Compare([Numerics.BigInteger]$left, [Numerics.BigInteger]$right)
    switch ($operator) {
        '==' { return $comparison -eq 0 } '!=' { return $comparison -ne 0 }
        '<' { return $comparison -lt 0 } '>' { return $comparison -gt 0 }
        '<=' { return $comparison -le 0 } '>=' { return $comparison -ge 0 }
    }
}
function Convert-CS2PSFloatingInteger($value, [string] $type, [bool] $checked) {
    if ($value -is [decimal]) { return Convert-CS2PSInteger ([Numerics.BigInteger]$value) $type $true }
    if ($checked) {
        if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { throw [OverflowException]::new() }
        return Convert-CS2PSInteger ([Numerics.BigInteger]::new([double]$value)) $type $true
    }
    # .NET 9+ specifies saturating float/double conversions.
    $result = switch ($type) {
        'int' { [int]::CreateSaturating[double]($value) }
        'uint' { [uint]::CreateSaturating[double]($value) }
        'long' { [long]::CreateSaturating[double]($value) }
        'ulong' { [ulong]::CreateSaturating[double]($value) }
        'byte' { [byte]::CreateSaturating[double]($value) }
        'sbyte' { [sbyte]::CreateSaturating[double]($value) }
        'short' { [short]::CreateSaturating[double]($value) }
        'ushort' { [ushort]::CreateSaturating[double]($value) }
        'char' { [ushort]::CreateSaturating[double]($value) }
        default { throw [NotSupportedException]::new('Floating conversion target') }
    }
    Convert-CS2PSInteger $result $type $false
}
function Get-CS2PSNullableValue($value) {
    if ($null -eq $value) { throw [InvalidOperationException]::new('Nullable object must have a value.') }
    return ,$value
}
function Get-CS2PSNullableDefault($value, $default) {
    if ($null -eq $value) { return ,$default }
    return ,$value
}
function Convert-CS2PSNullable($value, [string] $type, [bool] $checked) {
    if ($null -eq $value) { return $null }
    if ($type -in 'sbyte','byte','short','ushort','char','int','uint','long','ulong') {
        if ($value -is [double] -or $value -is [float] -or $value -is [decimal]) { return Convert-CS2PSFloatingInteger $value $type $checked }
        return Convert-CS2PSInteger $value $type $checked
    }
    return [System.Management.Automation.LanguagePrimitives]::ConvertTo($value, [type]$type)
}
function Invoke-CS2PSNumber($left, $right, [string] $operator, [string] $type, [bool] $checked) {
    if ($type -in 'sbyte','byte','short','ushort','char','int','uint','long','ulong') {
        if ($operator -in '==','!=','<','>','<=','>=') { return Compare-CS2PSInteger $left $right $operator }
        return Invoke-CS2PSInteger $left $right $operator $type $checked
    }
    if ($type -eq 'bool') {
        if ($operator -eq '==') { return $left -eq $right }
        if ($operator -eq '!=') { return $left -ne $right }
        return Invoke-CS2PSBoolean $left $right $operator
    }
    $l = [System.Management.Automation.LanguagePrimitives]::ConvertTo($left, [type]$type)
    $r = [System.Management.Automation.LanguagePrimitives]::ConvertTo($right, [type]$type)
    if ($type -ne 'decimal' -and ([double]::IsNaN($l) -or [double]::IsNaN($r))) {
        if ($operator -in '==','!=','<','>','<=','>=') { return $operator -eq '!=' }
    }
    $value = switch ($operator) {
        '+' { $l + $r } '-' { $l - $r } '*' { $l * $r }
        '/' {
            if ($r -eq 0) {
                if ($type -eq 'decimal') { throw [DivideByZeroException]::new() }
                if ($l -eq 0 -or [double]::IsNaN($l)) { [double]::NaN }
                else {
                    $negative = ([BitConverter]::DoubleToInt64Bits([double]$l) -lt 0) -xor ([BitConverter]::DoubleToInt64Bits([double]$r) -lt 0)
                    if ($negative) { [double]::NegativeInfinity } else { [double]::PositiveInfinity }
                }
            } else { $l / $r }
        }
        '%' { if ($r -eq 0 -and $type -ne 'decimal') { [double]::NaN } elseif ($r -eq 0) { throw [DivideByZeroException]::new() } else { $l % $r } }
        '==' { return $l -eq $r } '!=' { return $l -ne $r }
        '<' { return $l -lt $r } '>' { return $l -gt $r }
        '<=' { return $l -le $r } '>=' { return $l -ge $r }
    }
    [System.Management.Automation.LanguagePrimitives]::ConvertTo($value, [type]$type)
}
function Invoke-CS2PSNullableBinary($left, $right, [string] $operator, [string] $type, [bool] $checked) {
    if ($operator -in '==','!=') {
        $equal = if ($null -eq $left -or $null -eq $right) { $null -eq $left -and $null -eq $right } else { Invoke-CS2PSNumber $left $right '==' $type $checked }
        if ($operator -eq '==') { return $equal }; return -not $equal
    }
    if ($type -eq 'bool' -and $operator -eq '&' -and (($null -ne $left -and -not $left) -or ($null -ne $right -and -not $right))) { return $false }
    if ($type -eq 'bool' -and $operator -eq '|' -and (($null -ne $left -and $left) -or ($null -ne $right -and $right))) { return $true }
    if ($null -eq $left -or $null -eq $right) {
        if ($operator -in '<','>','<=','>=') { return $false }
        return $null
    }
    Invoke-CS2PSNumber $left $right $operator $type $checked
}
function Invoke-CS2PSNullableUnary($value, [string] $operator, [string] $type, [bool] $checked) {
    if ($null -eq $value) { return $null }
    if ($operator -eq '!') { return -not $value }
    if ($operator -eq '+') { return ,$value }
    if ($operator -eq '-') { return Invoke-CS2PSNumber 0 $value '-' $type $checked }
    Invoke-CS2PSInteger $value 0 $operator $type $false
}
'@
    $types = @($tree.GetRoot().DescendantNodes() | Where-Object { $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.TypeDeclarationSyntax] })
    $usedNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($type in $types) {
        $symbol = $script:Model.GetDeclaredSymbol($type)
        $script:SourceTypes[$symbol.ToString()] = Get-ReadableName $symbol 'types' $symbol.Name
        if ($symbol.TypeKind.ToString() -eq 'Struct') { [void]$script:StructTypes.Add($symbol.ToString()) }
        foreach ($m in $type.Members | Where-Object { $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax] }) {
            $method = $script:Model.GetDeclaredSymbol($m)
            $name = Get-FunctionName $symbol.Name $method.Name ($method.ReturnType.SpecialType.ToString() -ne 'System_Void')
            $original = $name; $suffix = 2
            while (-not $usedNames.Add($name)) { $name = $original + '_' + $suffix; $suffix++ }
            $script:MethodNames[$m.Span.Start] = $name
            $refCalls = @($m.DescendantNodes() | Where-Object { $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.ArgumentSyntax] -and $_.RefKindKeyword.Text })
            if ($symbol.TypeKind.ToString() -eq 'Class' -and -not $refCalls.Count -and -not @($method.Parameters | Where-Object { $_.RefKind.ToString() -ne 'None' -or ($_.Type.TypeKind.ToString() -eq 'Struct' -and $_.Type.SpecialType.ToString() -eq 'None') }).Count) {
                $script:ClassMethods[$m.Span.Start] = Get-ReadableName $method ('methods:' + $symbol.ToString()) $method.Name
            }
        }
    }
    foreach ($type in $types) { [void]$out.AppendLine((Convert-TypeDeclaration $type)) }
    foreach ($type in $types) {
        foreach ($m in $type.Members | Where-Object { $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax] }) {
            [void]$out.AppendLine((Convert-Method $type $m)).AppendLine()
        }
    }
    # Retain only calls reachable from this unit, including helper dependencies.
    $body = $out.ToString()
    $helperAst = [Management.Automation.Language.Parser]::ParseInput($helpers, [ref]$null, [ref]$null)
    $definitions = @{}
    foreach ($function in $helperAst.FindAll({ param($ast) $ast -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { $definitions[$function.Name] = $function }
    $required = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pending = [Collections.Generic.Queue[string]]::new()
    $bodyAst = [Management.Automation.Language.Parser]::ParseInput($body, [ref]$null, [ref]$null)
    foreach ($command in $bodyAst.FindAll({ param($ast) $ast -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $command.GetCommandName()
        if ($name -and $definitions.ContainsKey($name) -and $required.Add($name)) { $pending.Enqueue($name) }
    }
    while ($pending.Count) {
        foreach ($command in $definitions[$pending.Dequeue()].FindAll({ param($ast) $ast -is [Management.Automation.Language.CommandAst] }, $true)) {
            $name = $command.GetCommandName()
            if ($name -and $definitions.ContainsKey($name) -and $required.Add($name)) { $pending.Enqueue($name) }
        }
    }
    if ($required.Count) {
        [void]$out.AppendLine('# Semantic support used by this file.')
        foreach ($function in $helperAst.EndBlock.Statements) { if ($required.Contains($function.Name)) { [void]$out.AppendLine($function.Extent.Text) } }
    }
    # Fail closed: a diagnostic never leaves a partially translated program executable.
    if (@($script:Diagnostics | Where-Object Severity -NE 'Information').Count) {
        $out.Clear() | Out-Null
        foreach ($d in $script:Diagnostics) { [void]$out.AppendLine("# CS2PS: unsupported at line $($d.Line): $($d.Message)") }
        [void]$out.AppendLine("throw [NotSupportedException]::new('CS2PS translation has diagnostics.')")
    }
    $typeMappings = foreach ($type in $types) {
        $symbol = $script:Model.GetDeclaredSymbol($type)
        $default = @($symbol.InstanceConstructors | Where-Object { $_.Parameters.Length -eq 0 })
        [pscustomobject]@{ Type = $symbol.ToString(); PowerShellType = Get-PsTypeName $symbol; HasDefaultConstructor = $default.Count -gt 0 }
    }
    [pscustomobject]@{ PowerShell = $out.ToString().Replace("`r`n","`n").TrimEnd() + "`n"; Diagnostics = $script:Diagnostics.ToArray(); Methods = $script:Methods.ToArray(); Types = @($typeMappings); Renames = $script:Renames.ToArray(); ApiCalls = $script:ApiCalls.ToArray() }
}

function Initialize-Roslyn {
    if ('Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree' -as [type]) { return }
    foreach ($n in 'Microsoft.CodeAnalysis.dll', 'Microsoft.CodeAnalysis.CSharp.dll') {
        [void][Reflection.Assembly]::LoadFrom([IO.Path]::Combine($PSHOME, $n))
    }
}

function Add-Diagnostic($node, [string] $message, [string] $severity = 'Error') {
    $location = if ($node -is [Microsoft.CodeAnalysis.Diagnostic]) { $node.Location } else { $node.GetLocation() }
    $line = $location.GetLineSpan().StartLinePosition.Line + 1
    $script:Diagnostics.Add([pscustomobject]@{ Line = $line; Message = $message; Severity = $severity })
}
function Test-SupportedValueType($type) {
    if (Test-Nullable $type) {
        $element = Get-UnderlyingType $type
        return (Test-Integral $element) -or (Test-Floating $element) -or $element.SpecialType.ToString() -eq 'System_Boolean'
    }
    if ($type -is [Microsoft.CodeAnalysis.IArrayTypeSymbol]) { return $type.Rank -eq 1 -and -not (Test-SourceStruct $type.ElementType) -and (Test-SupportedValueType $type.ElementType) }
    if (Test-SourceType $type) { return $true }
    if ($type.SpecialType.ToString() -in 'System_Object','System_Void','System_String','System_Boolean') { return $true }
    if ((Test-Integral $type) -or (Test-Floating $type)) { return $true }
    if ($type -is [Microsoft.CodeAnalysis.INamedTypeSymbol] -and $type.OriginalDefinition.ToString() -ceq 'System.Collections.Generic.List<T>') { return Test-SupportedValueType $type.TypeArguments[0] }
    $base = $type
    while ($base) { if ($base.ToString() -ceq 'System.Exception') { return $true }; $base = $base.BaseType }
    return $false
}

function Get-PsTypeName($typeSymbol) {
    if ($script:SourceTypes -and $script:SourceTypes.ContainsKey($typeSymbol.ToString())) { return $script:SourceTypes[$typeSymbol.ToString()] }
    if ($typeSymbol -is [Microsoft.CodeAnalysis.IArrayTypeSymbol]) { return (Get-PsTypeName $typeSymbol.ElementType) + '[]' }
    if ($typeSymbol -is [Microsoft.CodeAnalysis.INamedTypeSymbol] -and $typeSymbol.IsGenericType) {
        return $typeSymbol.ContainingNamespace.ToString() + '.' + $typeSymbol.Name + '[' + (($typeSymbol.TypeArguments | ForEach-Object { Get-PsTypeName $_ }) -join ',') + ']'
    }
    switch ($typeSymbol.SpecialType.ToString()) {
        'System_Int32' { return 'int' } 'System_Int64' { return 'long' } 'System_Double' { return 'double' }
        'System_Single' { return 'float' } 'System_Boolean' { return 'bool' } 'System_String' { return 'string' }
        'System_Char' { return 'char' } 'System_Byte' { return 'byte' } 'System_Int16' { return 'short' }
        'System_Object' { return 'object' }
        'System_SByte' { return 'sbyte' } 'System_UInt16' { return 'ushort' }
        'System_UInt32' { return 'uint' } 'System_UInt64' { return 'ulong' } 'System_Decimal' { return 'decimal' }
        'System_Void' { return $null }
    }
    $typeSymbol.ToString().TrimEnd('?')
}

function Get-ReadableName($symbol, [string] $scope, [string] $name, [switch] $Variable) {
    $key = $symbol.Kind.ToString() + ':' + $symbol.DeclaringSyntaxReferences[0].Span.Start + ':' + $scope
    if ($script:Names.ContainsKey($key)) { return $script:Names[$key] }
    if (-not $script:NameScopes.ContainsKey($scope)) {
        $script:NameScopes[$scope] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        if ($Variable) {
            foreach ($reserved in 'input','args','this','_','PSItem','true','false','null','error','host','PSHOME','HOME','PID','PWD','PSVersionTable','PSBoundParameters','PSCmdlet','MyInvocation','ExecutionContext','Matches','foreach','switch','self') {
                [void]$script:NameScopes[$scope].Add($reserved)
            }
        }
    }
    $candidate = $name; $suffix = 2
    while (-not $script:NameScopes[$scope].Add($candidate)) { $candidate = $name + '_' + $suffix; $suffix++ }
    $script:Names[$key] = $candidate
    if ($candidate -cne $name) {
        $script:Renames.Add([pscustomobject]@{ Source = $name; Output = $candidate; Scope = $scope; Reason = 'PowerShell case-insensitive name or reserved variable collision' })
    }
    return $candidate
}
function Get-VariableName($symbol) {
    Get-ReadableName $symbol ('variables:' + $symbol.ContainingSymbol.ToString()) $symbol.Name -Variable
}
function Get-GeneratedName($node, [string] $purpose) {
    $key = $purpose + ':' + $node.Span.Start
    if ($script:GeneratedNames.ContainsKey($key)) { return $script:GeneratedNames[$key] }
    $method = $node
    while ($method.Parent -and $method -isnot [Microsoft.CodeAnalysis.CSharp.Syntax.BaseMethodDeclarationSyntax]) { $method = $method.Parent }
    $scope = $method.Span.Start.ToString()
    if (-not $script:GeneratedScopes.ContainsKey($scope)) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($syntax in $method.DescendantNodes()) { if ($syntax.PSObject.Properties['Identifier']) { [void]$names.Add($syntax.Identifier.ValueText) } }
        $script:GeneratedScopes[$scope] = $names
    }
    $name = $purpose; $suffix = 2
    while (-not $script:GeneratedScopes[$scope].Add($name)) { $name = $purpose + '_' + $suffix; $suffix++ }
    $script:GeneratedNames[$key] = $name
    return $name
}
function Test-NonNullStringExpression($expression) {
    if (-not $expression) { return $false }
    if ($expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.LiteralExpressionSyntax]) { return $null -ne $expression.Token.Value }
    if ($expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.InterpolatedStringExpressionSyntax]) { return $true }
    if ($expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.BinaryExpressionSyntax] -and $expression.OperatorToken.Text -eq '+' -and (Test-String (Get-ExprType $expression))) { return $true }
    return $false
}
function Test-NullObservable($symbol) {
    if (-not $symbol -or $symbol.Kind.ToString() -eq 'Field') { return $true }
    if ($symbol.NullableAnnotation.ToString() -eq 'Annotated') { return $true }
    $declaration = $symbol.DeclaringSyntaxReferences[0].GetSyntax([Threading.CancellationToken]::None)
    $scope = $declaration
    while ($scope.Parent -and $scope -isnot [Microsoft.CodeAnalysis.CSharp.Syntax.BaseMethodDeclarationSyntax]) { $scope = $scope.Parent }
    $references = @($scope.DescendantNodes() | Where-Object { $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.IdentifierNameSyntax] -and $_.Identifier.ValueText -ceq $symbol.Name } | Where-Object {
        $target = $script:Model.GetSymbolInfo($_).Symbol
        $target -and $target.DeclaringSyntaxReferences.Length -and $target.DeclaringSyntaxReferences[0].Span.Start -eq $symbol.DeclaringSyntaxReferences[0].Span.Start
    })
    if ($symbol.Kind.ToString() -eq 'Local' -and $declaration.Initializer -and (Test-NonNullStringExpression $declaration.Initializer.Value)) {
        if (@($references | Where-Object { $_.Parent -is [Microsoft.CodeAnalysis.CSharp.Syntax.ArgumentSyntax] -and $_.Parent.RefKindKeyword.Text }).Count) { return $true }
        $writes = @($references | Where-Object { $_.Parent -is [Microsoft.CodeAnalysis.CSharp.Syntax.AssignmentExpressionSyntax] -and $_.Parent.Left -eq $_ })
        if (-not @($writes | Where-Object { -not (Test-NonNullStringExpression $_.Parent.Right) }).Count) { return $false }
    }
    foreach ($reference in $references) {
        $parent = $reference.Parent
        if ($parent -is [Microsoft.CodeAnalysis.CSharp.Syntax.BinaryExpressionSyntax] -and $parent.OperatorToken.Text -eq '+' -and (Test-String (Get-ExprType $parent))) { continue }
        # Other uses may expose null identity, a null return or a null dereference.
        return $true
    }
    return $false
}
function Get-StorageType($type, $owner = $null) {
    if ((Test-Nullable $type) -or ((Test-String $type) -and (Test-NullObservable $owner))) { return 'object' }
    Get-PsTypeName $type
}
function Test-ProvenNonNull($expression) {
    if ($expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.ThisExpressionSyntax] -or $expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.ObjectCreationExpressionSyntax]) { return $true }
    if ((Test-String (Get-ExprType $expression)) -and (Test-NonNullStringExpression $expression)) { return $true }
    if ($expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.IdentifierNameSyntax]) {
        $symbol = $script:Model.GetSymbolInfo($expression).Symbol
        return (Test-String $symbol.Type) -and -not (Test-NullObservable $symbol)
    }
    return $false
}
function Convert-Receiver($expression) {
    $text = Convert-Expression $expression
    if (Test-ProvenNonNull $expression) { return $text }
    return "(Get-CS2PSReceiver ($text) <# C# null dereferences throw NullReferenceException. #>)"
}
function Get-DefaultValue($type) {
    if (Test-SourceStruct $type) { return "[$(Get-PsTypeName $type)]::new()" }
    if ($type.IsReferenceType -or ($type -is [Microsoft.CodeAnalysis.INamedTypeSymbol] -and $type.OriginalDefinition.SpecialType.ToString() -eq 'System_Nullable_T')) { return '$null' }
    return "[$(Get-PsTypeName $type)]0"
}
function Test-Nullable($type) { $type -is [Microsoft.CodeAnalysis.INamedTypeSymbol] -and $type.OriginalDefinition.SpecialType.ToString() -eq 'System_Nullable_T' }
function Get-UnderlyingType($type) { if (Test-Nullable $type) { return $type.TypeArguments[0] }; return $type }

function Test-SourceType($symbol) { $symbol -and $script:SourceTypes.ContainsKey($symbol.ToString()) }
function Test-SourceStruct($symbol) { $symbol -and $script:StructTypes.Contains($symbol.ToString()) }
function Convert-Value($expr) {
    $text = Convert-Expression $expr
    if (Test-SourceStruct (Get-ExprType $expr)) { return "(Copy-$(Get-PsTypeName (Get-ExprType $expr)) ($text))" }
    $source = Get-ExprType $expr
    $target = $script:Model.GetTypeInfo($expr).ConvertedType
    if (Test-Nullable $target) {
        $underlying = Get-UnderlyingType $target
        if (Test-SourceStruct $underlying) { return $text }
        return "(Convert-CS2PSNullable ($text) '$(Get-PsTypeName $underlying)' $(Get-CheckedFlag $expr))"
    }
    if ($source -and $target -and $source.SpecialType -ne $target.SpecialType -and ((Test-Integral $target) -or (Test-Floating $target))) {
        if ($source.SpecialType.ToString() -eq 'System_Char') { $text = "[int]($text)" }
        return "[$(Get-PsTypeName $target)]($text)"
    }
    return $text
}
function Get-FieldName($symbol) { Get-ReadableName $symbol ('fields:' + $symbol.ContainingType.ToString()) $symbol.Name }
function Get-MethodFunction($symbol) { $script:MethodNames[$symbol.DeclaringSyntaxReferences[0].Span.Start] }
function Get-ConstructorFunction($symbol) {
    $overloads = @($symbol.ContainingType.InstanceConstructors)
    $suffix = if ($overloads.Count -gt 1) { '_' + (1 + [Array]::IndexOf($overloads, $symbol)) } else { '' }
    'New-' + (Get-PsTypeName $symbol.ContainingType) + $suffix
}

function Convert-TypeDeclaration($node) {
    if ($node.GetType().Name -notin 'ClassDeclarationSyntax','StructDeclarationSyntax' -or $node.BaseList -or $node.TypeParameterList -or $node.ParameterList -or @($node.Modifiers | Where-Object { $_.Text -in 'partial','abstract','unsafe','ref','readonly' }).Count) {
        Add-Diagnostic $node 'only simple non-generic classes and structs are supported'; return ''
    }
    $symbol = $script:Model.GetDeclaredSymbol($node)
    $typeName = Get-PsTypeName $symbol
    $text = "class $typeName {`n"
    $fields = @($node.Members | Where-Object { $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.FieldDeclarationSyntax] })
    foreach ($field in $fields) {
        if (@($field.Modifiers | Where-Object { $_.Text -in 'readonly','volatile','const' }).Count) { Add-Diagnostic $field 'readonly, volatile and const fields'; continue }
        foreach ($v in $field.Declaration.Variables) {
            $f = $script:Model.GetDeclaredSymbol($v)
            if (-not (Test-SupportedValueType $f.Type)) { Add-Diagnostic $v 'unsupported field type' }
            $static = if ($f.IsStatic) { 'static ' } else { '' }
            $default = if (Test-SourceStruct $f.Type) { " = [$(Get-PsTypeName $f.Type)]::new()" } else { '' }
            $text += "    $static[$(Get-StorageType $f.Type $f)] `$$(Get-FieldName $f)$default`n"
            if ($f.IsStatic -and $v.Initializer) { Add-Diagnostic $v 'static field initializer' }
        }
    }
    foreach ($method in $node.Members | Where-Object { $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax] -and $script:ClassMethods.ContainsKey($_.Span.Start) }) {
        $declared = $script:Model.GetDeclaredSymbol($method)
        $returnType = if ((Test-String $declared.ReturnType) -or (Test-Nullable $declared.ReturnType)) { 'object' } else { Get-PsTypeName $declared.ReturnType }
        if (-not $returnType) { $returnType = 'void' }
        $parameters = @($declared.Parameters | ForEach-Object { "[$(Get-StorageType $_.Type $_)] `$$(Get-VariableName $_)" })
        $static = if ($declared.IsStatic) { 'static ' } else { '' }
        $text += "    $static[$returnType] $($script:ClassMethods[$method.Span.Start])($($parameters -join ', ')) {`n"
        $script:ClassContext = $true
        try {
            if ($method.Body) { foreach ($statement in $method.Body.Statements) { $text += Convert-Statement $statement 2 } }
            elseif ($method.ExpressionBody) { $text += "        return $(Convert-Value $method.ExpressionBody.Expression)`n" }
        } finally { $script:ClassContext = $false }
        $text += "    }`n"
    }
    # Constructors execute on the actual PowerShell instance, preserving identity.
    foreach ($ctor in $symbol.InstanceConstructors) {
        foreach ($parameter in $ctor.Parameters) { if ($parameter.RefKind.ToString() -ne 'None' -or $parameter.IsParams -or $parameter.HasExplicitDefaultValue -or -not (Test-SupportedValueType $parameter.Type)) { Add-Diagnostic $node 'unsupported constructor parameter' } }
        $parameters = @($ctor.Parameters | ForEach-Object { "[$(Get-StorageType $_.Type $_)] `$$(Get-VariableName $_)" })
        $text += "    $typeName($($parameters -join ', ')) {`n"
        $script:ClassContext = $true
        try {
            foreach ($field in $fields) {
                foreach ($variable in $field.Declaration.Variables) {
                    $declared = $script:Model.GetDeclaredSymbol($variable)
                    if (-not $declared.IsStatic -and $variable.Initializer) { $text += "        `$this.$(Get-FieldName $declared) = $(Convert-Value $variable.Initializer.Value)`n" }
                }
            }
            if ($ctor.DeclaringSyntaxReferences.Length) {
                $syntax = $ctor.DeclaringSyntaxReferences[0].GetSyntax([Threading.CancellationToken]::None)
                if ($syntax.Initializer) { Add-Diagnostic $syntax 'constructor chaining requires explicit base/this constructor selection' }
                if ($syntax.Body) { foreach ($statement in $syntax.Body.Statements) { $text += Convert-Statement $statement 2 } }
                elseif ($syntax.ExpressionBody) { $text += "        [void]($(Convert-Expression $syntax.ExpressionBody.Expression))`n" }
            }
        } finally { $script:ClassContext = $false }
        $text += "    }`n"
    }
    $text += "}`n"
    if (Test-SourceStruct $symbol) {
        $text += "function Copy-$typeName(`$value) {`n    `$copy = [$typeName]::new()`n"
        foreach ($field in $fields) {
            foreach ($v in $field.Declaration.Variables) {
                $f = $script:Model.GetDeclaredSymbol($v)
                if ($f.IsStatic) { continue }
                $name = Get-FieldName $f
                $value = if (Test-SourceStruct $f.Type) { "(Copy-$(Get-PsTypeName $f.Type) (`$value.$name))" } else { "`$value.$name" }
                $text += "    `$copy.$name = $value`n"
            }
        }
        $text += "    return ,`$copy`n}`n"
    }
    foreach ($member in $node.Members) {
        if ($member.GetType().Name -notin 'MethodDeclarationSyntax','FieldDeclarationSyntax','ConstructorDeclarationSyntax','ClassDeclarationSyntax','StructDeclarationSyntax') { Add-Diagnostic $member "type member $($member.GetType().Name)" }
        if ($member -is [Microsoft.CodeAnalysis.CSharp.Syntax.ConstructorDeclarationSyntax] -and @($member.Modifiers | Where-Object { $_.Text -eq 'static' }).Count) { Add-Diagnostic $member 'static constructor' }
    }
    return $text
}

function Test-Integral($typeSymbol) { $typeSymbol -and $typeSymbol.SpecialType.ToString() -in 'System_Int32', 'System_Int64', 'System_Int16', 'System_Byte', 'System_UInt32', 'System_UInt64', 'System_SByte', 'System_UInt16', 'System_Char' }
function Test-Floating($typeSymbol) { $typeSymbol -and $typeSymbol.SpecialType.ToString() -in 'System_Double', 'System_Single', 'System_Decimal' }
function Test-String($typeSymbol) { $typeSymbol -and $typeSymbol.SpecialType.ToString() -eq 'System_String' }
function Get-ExprType($expr) { $script:Model.GetTypeInfo($expr).Type }
function Get-CheckedFlag($node) {
    while ($node) {
        if ($node.GetType().Name -in 'CheckedExpressionSyntax','CheckedStatementSyntax') { return $(if ($node.Keyword.Text -ceq 'checked') { '$true' } else { '$false' }) }
        $node = $node.Parent
    }
    '$false'
}

function Convert-IntegerOperation($node, [string] $left, [string] $right, [string] $operator, $type) {
    $name = Get-PsTypeName $type
    if ($operator -eq '/' -and $name -in 'int','long') {
        return "[Math]::DivRem([$name]($left), [$name]($right)).Item1 <# C# integer division truncates and preserves division exceptions. #>"
    }
    if ($operator -notin '+','-','*') {
        return "(Invoke-CS2PSInteger ($left) ($right) '$operator' '$name' $(Get-CheckedFlag $node)) <# C# width, shift masks and exceptional remainder are explicit. #>"
    }
    $constant = $script:Model.GetConstantValue($node)
    if ($constant.HasValue -and $node -is [Microsoft.CodeAnalysis.CSharp.Syntax.ExpressionSyntax]) {
        return Convert-NumericLiteral $constant.Value $type
    }
    $operands = if ($node -is [Microsoft.CodeAnalysis.CSharp.Syntax.BinaryExpressionSyntax]) { @($node.Left,$node.Right) } elseif ($node -is [Microsoft.CodeAnalysis.CSharp.Syntax.PrefixUnaryExpressionSyntax] -or $node -is [Microsoft.CodeAnalysis.CSharp.Syntax.PostfixUnaryExpressionSyntax]) { @($node.Operand,$null) } else { @() }
    if ($operands.Count -eq 2 -and $name -in 'int','long') {
        $a = Get-IntegralRange $operands[0]
        $b = if ($operands[1]) { Get-IntegralRange $operands[1] } else { @(1L,1L) }
        if ($a -and $b) {
            $bounds = switch ($operator) {
                '+' { @(([Numerics.BigInteger]($a[0]) + [Numerics.BigInteger]($b[0])), ([Numerics.BigInteger]($a[1]) + [Numerics.BigInteger]($b[1]))) }
                '-' { @(([Numerics.BigInteger]($a[0]) - [Numerics.BigInteger]($b[1])), ([Numerics.BigInteger]($a[1]) - [Numerics.BigInteger]($b[0]))) }
                '*' { @(([Numerics.BigInteger]($a[0]) * [Numerics.BigInteger]($b[0])), ([Numerics.BigInteger]($a[0]) * [Numerics.BigInteger]($b[1])), ([Numerics.BigInteger]($a[1]) * [Numerics.BigInteger]($b[0])), ([Numerics.BigInteger]($a[1]) * [Numerics.BigInteger]($b[1]))) }
            }
            $minimum = if ($name -eq 'int') { [int]::MinValue } else { [long]::MinValue }
            $maximum = if ($name -eq 'int') { [int]::MaxValue } else { [long]::MaxValue }
            if (-not @($bounds | Where-Object { $_ -lt $minimum -or $_ -gt $maximum }).Count) { return "($left $operator $right)" }
        }
    }
    $wide = if ($name -in 'int','short','byte','sbyte','ushort','char') { 'long' } else { 'Numerics.BigInteger' }
    $method = if ((Get-CheckedFlag $node) -eq '$true') { 'CreateChecked' } else { 'CreateTruncating' }
    $reason = if ($method -eq 'CreateChecked') { 'C# checked overflow must throw.' } else { "C# unchecked $name overflow must wrap; operands are not proven bounded." }
    if ($method -eq 'CreateTruncating') { Add-Diagnostic $node $reason 'Information' }
    if ($name -eq 'char') { return "[char][ushort]::$method[$wide](([$wide]($left) $operator [$wide]($right))) <# $reason #>" }
    return "[$name]::$method[$wide](([$wide]($left) $operator [$wide]($right))) <# $reason #>"
}
function Get-IntegralRange($expression) {
    if (-not $expression) { return $null }
    $constant = $script:Model.GetConstantValue($expression)
    if ($constant.HasValue -and (Test-Integral (Get-ExprType $expression))) { return @($constant.Value,$constant.Value) }
    if ($expression -isnot [Microsoft.CodeAnalysis.CSharp.Syntax.IdentifierNameSyntax]) { return $null }
    $symbol = $script:Model.GetSymbolInfo($expression).Symbol
    if ($symbol.Kind.ToString() -ne 'Local') { return $null }
    $declaration = $symbol.DeclaringSyntaxReferences[0].GetSyntax([Threading.CancellationToken]::None)
    $loop = $declaration.Parent.Parent
    if ($loop -isnot [Microsoft.CodeAnalysis.CSharp.Syntax.ForStatementSyntax] -or $loop.Incrementors.Count -ne 1) { return $null }
    $condition = $loop.Condition
    if ($condition -isnot [Microsoft.CodeAnalysis.CSharp.Syntax.BinaryExpressionSyntax] -or $condition.Left.ToString() -cne $symbol.Name -or $condition.OperatorToken.Text -notin '<','<=') { return $null }
    $start = $script:Model.GetConstantValue($declaration.Initializer.Value)
    $end = $script:Model.GetConstantValue($condition.Right)
    if (-not $start.HasValue -or -not $end.HasValue) { return $null }
    $increment = $loop.Incrementors[0]
    $unit = $increment -is [Microsoft.CodeAnalysis.CSharp.Syntax.PostfixUnaryExpressionSyntax] -and $increment.OperatorToken.Text -eq '++' -and $increment.Operand.ToString() -ceq $symbol.Name
    if (-not $unit -and $increment -is [Microsoft.CodeAnalysis.CSharp.Syntax.AssignmentExpressionSyntax]) {
        $rhs = $increment.Right
        $unit = $increment.OperatorToken.Text -eq '=' -and $increment.Left.ToString() -ceq $symbol.Name -and $rhs -is [Microsoft.CodeAnalysis.CSharp.Syntax.BinaryExpressionSyntax] -and $rhs.OperatorToken.Text -eq '+' -and $rhs.Left.ToString() -ceq $symbol.Name -and $script:Model.GetConstantValue($rhs.Right).HasValue -and $script:Model.GetConstantValue($rhs.Right).Value -eq 1
    }
    if (-not $unit) { return $null }
    $writes = @($loop.Statement.DescendantNodes() | Where-Object { $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.IdentifierNameSyntax] -and $_.Identifier.ValueText -ceq $symbol.Name -and ($_.Parent -is [Microsoft.CodeAnalysis.CSharp.Syntax.AssignmentExpressionSyntax] -or $_.Parent -is [Microsoft.CodeAnalysis.CSharp.Syntax.PrefixUnaryExpressionSyntax] -or $_.Parent -is [Microsoft.CodeAnalysis.CSharp.Syntax.PostfixUnaryExpressionSyntax] -or ($_.Parent -is [Microsoft.CodeAnalysis.CSharp.Syntax.ArgumentSyntax] -and $_.Parent.RefKindKeyword.Text)) })
    if ($writes.Count) { return $null }
    $upper = [Numerics.BigInteger]$end.Value
    if ($condition.OperatorToken.Text -eq '<') { $upper = $upper - 1 }
    # Include the final increment in the proof; a <= MaxValue loop can wrap.
    $maximum = if ((Get-PsTypeName $symbol.Type) -eq 'int') { [int]::MaxValue } else { [long]::MaxValue }
    if ($start.Value -gt $upper -or $upper -ge $maximum) { return $null }
    return @($start.Value,$upper)
}
function Convert-NumericLiteral($value, $type) {
    $literal = $value.ToString([Globalization.CultureInfo]::InvariantCulture)
    $name = Get-PsTypeName $type
    if ($name -eq 'int') { return $literal }
    if ($name -eq 'double') {
        if ($literal -notmatch '[.Ee]') { $literal += '.0' }
        return $literal
    }
    if ($name -eq 'long') { return $literal + 'L' }
    if ($name -eq 'decimal') { return $literal + 'D' }
    return "[$name]($literal)"
}

# Method names map to approved verbs; the rest become Get- (value) or Invoke- (void).
function Get-FunctionName([string] $class, [string] $method, [bool] $returnsValue) {
    $map = [ordered]@{ Get = 'Get'; Set = 'Set'; Is = 'Test'; Has = 'Test'; Can = 'Test'; Compute = 'Measure'; Calculate = 'Measure'
        Format = 'Format'; Parse = 'ConvertFrom'; Convert = 'Convert'; Clear = 'Clear'; Add = 'Add'; Remove = 'Remove'; Find = 'Find'; Reset = 'Reset'; New = 'New'; Create = 'New' }
    foreach ($k in $map.Keys) {
        if ($method -cmatch "^$k(?=[A-Z])") { return '{0}-{1}{2}' -f $map[$k], $class, $method }
    }
    '{0}-{1}{2}' -f ($(if ($returnsValue) { 'Get' } else { 'Invoke' })), $class, $method
}

function Convert-Method($type, $m) {
    $symbol = $script:Model.GetDeclaredSymbol($m)
    $returnType = Get-PsTypeName $symbol.ReturnType
    if (-not (Test-SupportedValueType $symbol.ReturnType)) { Add-Diagnostic $m 'unsupported return type' }
    $name = Get-MethodFunction $symbol
    if ($symbol.IsGenericMethod -or $symbol.IsExtensionMethod -or $symbol.IsVirtual -or $symbol.IsOverride -or $symbol.IsAbstract -or $symbol.ReturnsByRef -or $symbol.ReturnsByRefReadonly -or @($m.Modifiers | Where-Object { $_.Text -in 'async','extern' }).Count) { Add-Diagnostic $m 'generic, extension, virtual, ref-return, async or extern method' }
    $before = $script:Diagnostics.Count
    foreach ($parameter in $symbol.Parameters) { if (-not (Test-SupportedValueType $parameter.Type) -or $parameter.IsParams -or $parameter.HasExplicitDefaultValue) { Add-Diagnostic $m 'unsupported parameter type, params or optional parameter' } }
    $classMethod = $script:ClassMethods[$m.Span.Start]
    $script:Methods.Add([pscustomobject]@{ Type = $symbol.ContainingType.ToString(); Method = $symbol.Name; Function = $(if ($classMethod -and -not $symbol.IsStatic) { $null } else { $name }); ClassMethod = $classMethod; IsStatic = $symbol.IsStatic; Parameters = @($symbol.Parameters | ForEach-Object { Get-VariableName $_ }) })
    if ($script:ClassMethods.ContainsKey($m.Span.Start)) {
        if ($symbol.IsStatic) {
            $parameters = @($symbol.Parameters | ForEach-Object { "[$(Get-StorageType $_.Type $_)] `$$(Get-VariableName $_)" })
            $arguments = @($symbol.Parameters | ForEach-Object { '$' + (Get-VariableName $_) })
            return "function $name { param($($parameters -join ', ')); return ,[$(Get-PsTypeName $symbol.ContainingType)]::$classMethod($($arguments -join ', ')) }"
        }
        return ''
    }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("function $name {")
    if (-not $symbol.IsStatic) { [void]$sb.AppendLine('    # C# value-copy or ref/out semantics require a function taking the instance.') }
    if ($returnType) { [void]$sb.AppendLine("    [OutputType([$returnType])]") }
    $params = foreach ($p in $symbol.Parameters) {
        if (-not (Test-SupportedValueType $p.Type) -or $p.IsParams -or $p.HasExplicitDefaultValue) { Add-Diagnostic $m 'unsupported parameter type, params or optional parameter' }
        $t = if ($p.RefKind.ToString() -in 'Ref','Out') { 'ref' } else { Get-StorageType $p.Type $p }
        if ($p.RefKind.ToString() -notin 'None','Ref','Out') { Add-Diagnostic $m 'in/ref-readonly parameters' }
        # Parameters are optional: the binder already admits null/empty values.
        $attributes = ''
        $note = if ((Test-String $p.Type) -and $t -eq 'object') { ' <# Null and empty are observably distinct for this parameter. #>' } else { '' }
        "$attributes[$t] `$$(Get-VariableName $p)$note"
    }
    if (-not $symbol.IsStatic) { $params = @('        [object] $self') + @($params) }
    [void]$sb.AppendLine("    param($($params -join ', '))")
    $line = $m.GetLocation().GetLineSpan().StartLinePosition.Line + 1
    [void]$sb.AppendLine("    # From C# $($type.Identifier.Text).$($m.Identifier.Text) (line $line).")
    if (-not $symbol.IsStatic) { [void]$sb.AppendLine('    if ($null -eq $self) { throw [NullReferenceException]::new() }') }
    foreach ($p in $symbol.Parameters) {
        if ($p.RefKind.ToString() -eq 'None' -and (Test-SourceStruct $p.Type)) { [void]$sb.AppendLine("    `$$(Get-VariableName $p) = Copy-$(Get-PsTypeName $p.Type) (`$$(Get-VariableName $p))") }
    }
    if ($m.Body) { foreach ($s in $m.Body.Statements) { [void]$sb.Append((Convert-Statement $s 1)) } }
    elseif ($m.ExpressionBody) { [void]$sb.AppendLine("    return ,($(Convert-Value $m.ExpressionBody.Expression))") }
    [void]$sb.Append('}')
    $sb.ToString()
}

function Convert-Statement($s, [int] $depth) {
    $pad = '    ' * $depth
    switch ($s.GetType().Name) {
        'LocalDeclarationStatementSyntax' {
            if ($s.UsingKeyword.Text -or $s.AwaitKeyword.Text) { Add-Diagnostic $s 'using/await-using declaration' }
            $lines = foreach ($v in $s.Declaration.Variables) {
                $owner = $script:Model.GetDeclaredSymbol($v)
                $t = Get-StorageType $owner.Type $owner
                if (-not (Test-SupportedValueType ($script:Model.GetDeclaredSymbol($v).Type))) { Add-Diagnostic $v 'unsupported local type' }
                $init = if ($v.Initializer) { ' = ' + (Convert-Value $v.Initializer.Value) } else { ' = ' + (Get-DefaultValue ($script:Model.GetDeclaredSymbol($v).Type)) }
                "$pad[$t] `$$(Get-VariableName ($script:Model.GetDeclaredSymbol($v)))$init`n"
            }
            return ($lines -join '')
        }
        'ExpressionStatementSyntax' {
            if ($s.Expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.AssignmentExpressionSyntax] -and $s.Expression.OperatorToken.Text -ne '??=' -and $s.Expression.Left -isnot [Microsoft.CodeAnalysis.CSharp.Syntax.ElementAccessExpressionSyntax]) { return "${pad}$(Convert-Expression $s.Expression)`n" }
            if (($s.Expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.PostfixUnaryExpressionSyntax] -or $s.Expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.PrefixUnaryExpressionSyntax]) -and $s.Expression.OperatorToken.Text -in '++','--' -and -not (Test-Nullable (Get-ExprType $s.Expression.Operand))) {
                $left = Convert-Expression $s.Expression.Operand
                $op = if ($s.Expression.OperatorToken.Text -eq '++') { '+' } else { '-' }
                return "${pad}$left = $(Convert-IntegerOperation $s.Expression $left '1' $op (Get-ExprType $s.Expression))`n"
            }
            return "${pad}[void]($(Convert-Expression $s.Expression))`n"
        }
        'ReturnStatementSyntax' { return $(if ($s.Expression) { if ($script:ClassContext) { "${pad}return $(Convert-Value $s.Expression)`n" } else { "${pad}return ,($(Convert-Value $s.Expression))`n" } } else { "${pad}return`n" }) }
        'EmptyStatementSyntax' { return '' }
        'CheckedStatementSyntax' { return Convert-Embedded $s.Block $depth }
        'ThrowStatementSyntax' {
            if ($s.Expression) { return "${pad}throw (Get-CS2PSThrowException ($(Convert-Value $s.Expression)))`n" }
            return "${pad}throw`n"
        }
        'TryStatementSyntax' {
            $text = "${pad}try {`n$(Convert-Embedded $s.Block ($depth + 1))${pad}}"
            if ($s.Catches.Count) {
                $exception = '$' + (Get-GeneratedName $s 'exception')
                $text += " catch {`n${pad}    $exception = Get-CS2PSException `$_.Exception`n"
                $first = $true
                foreach ($clause in $s.Catches) {
                    if ($clause.Filter) { Add-Diagnostic $clause.Filter 'exception filters require pre-unwind evaluation'; continue }
                    $typeName = if ($clause.Declaration) { Get-PsTypeName ($script:Model.GetTypeInfo($clause.Declaration.Type).Type) } else { 'Exception' }
                    $keyword = if ($first) { 'if' } else { 'elseif' }; $first = $false
                    $text += "${pad}    $keyword ($exception -is [$typeName]) {`n"
                    if ($clause.Declaration -and $clause.Declaration.Identifier.Text) {
                        $local = $script:Model.GetDeclaredSymbol($clause.Declaration)
                        $text += "${pad}        [$typeName] `$$(Get-VariableName $local) = $exception`n"
                    }
                    $text += Convert-Embedded $clause.Block ($depth + 2)
                    $text += "${pad}    }`n"
                }
                if (-not $first) { $text += "${pad}    else { throw }`n" }
                $text += "${pad}}"
            }
            if ($s.Finally) { $text += " finally {`n$(Convert-Embedded $s.Finally.Block ($depth + 1))${pad}}" }
            return "$text`n"
        }
        'BlockSyntax' { return (($s.Statements | ForEach-Object { Convert-Statement $_ $depth }) -join '') }
        'IfStatementSyntax' {
            $text = "${pad}if ($(Convert-Expression $s.Condition)) {`n$(Convert-Embedded $s.Statement ($depth + 1))$pad}"
            $else = $s.Else
            while ($else) {
                if ($else.Statement -is [Microsoft.CodeAnalysis.CSharp.Syntax.IfStatementSyntax]) {
                    $text += " elseif ($(Convert-Expression $else.Statement.Condition)) {`n$(Convert-Embedded $else.Statement.Statement ($depth + 1))$pad}"
                    $else = $else.Statement.Else
                } else { $text += " else {`n$(Convert-Embedded $else.Statement ($depth + 1))$pad}"; $else = $null }
            }
            return "$text`n"
        }
        'ForStatementSyntax' {
            $init = if ($s.Declaration) { ($s.Declaration.Variables | ForEach-Object { "[$(Get-PsTypeName ($script:Model.GetDeclaredSymbol($_).Type))] `$$(Get-VariableName ($script:Model.GetDeclaredSymbol($_))) = $(Convert-Expression $_.Initializer.Value)" }) -join '; ' } else { ($s.Initializers | ForEach-Object { '[void](' + (Convert-Expression $_) + ')' }) -join '; ' }
            $cond = if ($s.Condition) { Convert-Expression $s.Condition } else { '$true' }
            $inc = ($s.Incrementors | ForEach-Object {
                if (($_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.PostfixUnaryExpressionSyntax] -or $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.PrefixUnaryExpressionSyntax]) -and $_.OperatorToken.Text -in '++','--' -and -not (Test-Nullable (Get-ExprType $_.Operand))) {
                    $left = Convert-Expression $_.Operand
                    $op = if ($_.OperatorToken.Text -eq '++') { '+' } else { '-' }
                    "$left = $(Convert-IntegerOperation $_ $left '1' $op (Get-ExprType $_))"
                } else { '[void](' + (Convert-Expression $_) + ')' }
            }) -join '; '
            return "${pad}:$(Get-GeneratedName $s 'loop') for ($init; $cond; $inc) {`n$(Convert-Embedded $s.Statement ($depth + 1))$pad}`n"
        }
        'ForEachStatementSyntax' {
            $t = Get-ExprType $s.Expression
            if ($t -isnot [Microsoft.CodeAnalysis.IArrayTypeSymbol] -and $t.OriginalDefinition.ToString() -cne 'System.Collections.Generic.List<T>') {
                Add-Diagnostic $s 'foreach requires a single-dimensional array or List<T>'; return ''
            }
            if ($t -is [Microsoft.CodeAnalysis.IArrayTypeSymbol] -and $t.Rank -ne 1) { Add-Diagnostic $s 'multidimensional foreach'; return '' }
            $enumerator = '$' + (Get-GeneratedName $s 'enumerator')
            $loop = Get-GeneratedName $s 'loop'
            $v = Get-VariableName ($script:Model.GetDeclaredSymbol($s))
            # Use a real enumerator: List<T> must detect mutation; evaluate collection once.
            $valueType = $script:Model.GetDeclaredSymbol($s).Type
            $current = if (Test-SourceStruct $valueType) { "(Copy-$(Get-PsTypeName $valueType) ($enumerator.Current))" } else { "$enumerator.Current" }
            return "${pad}$enumerator = (Get-CS2PSReceiver ($(Convert-Expression $s.Expression))).GetEnumerator()`n${pad}try {`n${pad}    :$loop while ($enumerator.MoveNext()) {`n${pad}        [$(Get-StorageType $valueType)] `$$v = $current`n$(Convert-Embedded $s.Statement ($depth + 2))${pad}    }`n${pad}} finally {`n${pad}    if ($enumerator -is [IDisposable]) { $enumerator.Dispose() }`n${pad}}`n"
        }
        'WhileStatementSyntax' { return "${pad}:$(Get-GeneratedName $s 'loop') while ($(Convert-Expression $s.Condition)) {`n$(Convert-Embedded $s.Statement ($depth + 1))$pad}`n" }
        'BreakStatementSyntax' { return "${pad}break $(Get-JumpLabel $s $false)`n" }
        'ContinueStatementSyntax' { return "${pad}continue $(Get-JumpLabel $s $true)`n" }
        'SwitchStatementSyntax' {
            if ((Get-ExprType $s.Expression).SpecialType.ToString() -eq 'System_Object') { Add-Diagnostic $s 'object switch subject' }
            $subject = '$' + (Get-GeneratedName $s 'switchValue')
            $text = "${pad}$subject = $(Convert-Expression $s.Expression)`n${pad}:$(Get-GeneratedName $s 'switchBlock') do {`n"
            $sections = @($s.Sections | Where-Object { -not @($_.Labels | Where-Object { $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.DefaultSwitchLabelSyntax] }).Count })
            $defaults = @($s.Sections | Where-Object { @($_.Labels | Where-Object { $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.DefaultSwitchLabelSyntax] }).Count })
            $first = $true
            foreach ($section in $sections) {
                $tests = foreach ($label in $section.Labels) {
                    if ($label -is [Microsoft.CodeAnalysis.CSharp.Syntax.CaseSwitchLabelSyntax]) { "(Test-CS2PSConstant ($subject) ($(Convert-Expression $label.Value)))" }
                    else { Add-Diagnostic $label 'pattern switch label'; '$false' }
                }
                $keyword = if ($first) { 'if' } else { 'elseif' }; $first = $false
                $text += "${pad}    $keyword ($($tests -join ' -or ')) {`n"
                foreach ($statement in $section.Statements) { $text += Convert-Statement $statement ($depth + 2) }
                $text += "${pad}    }`n"
            }
            foreach ($section in $defaults) {
                if (-not $first) { $text += "${pad}    else {`n" }
                foreach ($statement in $section.Statements) { $text += Convert-Statement $statement ($depth + 2) }
                if (-not $first) { $text += "${pad}    }`n" }
            }
            return $text + "${pad}} while (`$false)`n"
        }
        default { Add-Diagnostic $s "statement $($s.GetType().Name) is not supported"; return '' }
    }
}

function Convert-Embedded($s, [int] $depth) {
    if ($s -is [Microsoft.CodeAnalysis.CSharp.Syntax.BlockSyntax]) { return (($s.Statements | ForEach-Object { Convert-Statement $_ $depth }) -join '') }
    Convert-Statement $s $depth
}

function Get-JumpLabel($s, [bool] $continue) {
    $parent = $s.Parent
    while ($parent) {
        if ($parent.GetType().Name -in 'ForStatementSyntax','ForEachStatementSyntax','WhileStatementSyntax') { return Get-GeneratedName $parent 'loop' }
        if (-not $continue -and $parent -is [Microsoft.CodeAnalysis.CSharp.Syntax.SwitchStatementSyntax]) { return Get-GeneratedName $parent 'switchBlock' }
        $parent = $parent.Parent
    }
    Add-Diagnostic $s 'jump target is outside the supported subset'
}

function Convert-Pattern($pattern, [string] $subject) {
    switch ($pattern.GetType().Name) {
        'ConstantPatternSyntax' { return "(Test-CS2PSConstant ($subject) ($(Convert-Expression $pattern.Expression)))" }
        'DiscardPatternSyntax' { return '$true' }
        default { Add-Diagnostic $pattern "pattern $($pattern.GetType().Name)"; return '$false' }
    }
}

function Convert-Argument($argument) {
    if (-not $argument.RefKindKeyword.Text) { return Convert-Value $argument.Expression }
    $expr = $argument.Expression
    if ($expr -is [Microsoft.CodeAnalysis.CSharp.Syntax.DeclarationExpressionSyntax]) {
        if ($expr.Designation -isnot [Microsoft.CodeAnalysis.CSharp.Syntax.SingleVariableDesignationSyntax]) { Add-Diagnostic $expr 'out discard/deconstruction'; return '$null' }
        $sym = $script:Model.GetDeclaredSymbol($expr.Designation)
        return "`$([$((Get-StorageType $sym.Type))] `$$(Get-VariableName $sym) = $(Get-DefaultValue $sym.Type); [ref]`$$(Get-VariableName $sym))"
    }
    if ($expr -isnot [Microsoft.CodeAnalysis.CSharp.Syntax.IdentifierNameSyntax]) { Add-Diagnostic $argument 'ref/out requires a local or parameter'; return '$null' }
    $sym = $script:Model.GetSymbolInfo($expr).Symbol
    if ($sym.Kind.ToString() -notin 'Local','Parameter') { Add-Diagnostic $argument 'ref/out field argument'; return '$null' }
    $name = '$' + (Get-VariableName $sym)
    if ($sym.Kind.ToString() -eq 'Parameter' -and $sym.RefKind.ToString() -in 'Ref','Out') { return $name }
    return "[ref]$name"
}
function Test-SimpleLValue($expression) {
    if ($expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.IdentifierNameSyntax]) { return $true }
    if ($expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.ThisExpressionSyntax]) { return $true }
    if ($expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax]) {
        $symbol = $script:Model.GetSymbolInfo($expression).Symbol
        if ($symbol.IsStatic) { return $true }
        return Test-SimpleLValue $expression.Expression
    }
    return $false
}
function New-ArgumentArray([string[]] $values) {
    if ($values.Count -eq 0) { return '[object[]]@()' }
    if ($values.Count -eq 1) { return '[object[]]@(,(' + $values[0] + '))' }
    return '[object[]]@(' + (($values | ForEach-Object { '(' + $_ + ')' }) -join ', ') + ')'
}

function Convert-Expression($e) {
    switch ($e.GetType().Name) {
        'LiteralExpressionSyntax' {
            $v = $e.Token.Value
            if ($v -is [string]) { return "'" + ($v -replace "'", "''") + "'" }
            if ($v -is [bool]) { return $(if ($v) { '$true' } else { '$false' }) }
            if ($null -eq $v) { return '$null' }
            if ($v -is [char]) { return "[char]$([int]$v)" }
            $t = Get-ExprType $e
            $literal = $v.ToString([Globalization.CultureInfo]::InvariantCulture)
            return Convert-NumericLiteral $v $t
        }
        'InterpolatedStringExpressionSyntax' {
            $format = [Text.StringBuilder]::new(); $values = [System.Collections.Generic.List[string]]::new()
            foreach ($part in $e.Contents) {
                if ($part -is [Microsoft.CodeAnalysis.CSharp.Syntax.InterpolatedStringTextSyntax]) { [void]$format.Append($part.TextToken.ValueText) }
                else {
                    $hole = '{' + $values.Count
                    if ($part.AlignmentClause) { $hole += ',' + $script:Model.GetConstantValue($part.AlignmentClause.Value).Value }
                    if ($part.FormatClause) { $hole += ':' + $part.FormatClause.FormatStringToken.ValueText }
                    [void]$format.Append($hole + '}')
                    $values.Add('(' + (Convert-Value $part.Expression) + ')')
                }
            }
            $literal = "'" + $format.ToString().Replace("'", "''") + "'"
            return "[string]::Format($literal, [object[]]@($($values -join ', ')))"
        }
        'IdentifierNameSyntax' {
            $sym = $script:Model.GetSymbolInfo($e).Symbol
            if ($sym -and $sym.Kind.ToString() -in 'Local', 'Parameter') {
                $name = '$' + (Get-VariableName $sym)
                if ($sym.Kind.ToString() -eq 'Parameter' -and $sym.RefKind.ToString() -in 'Ref','Out') { $name += '.Value' }
                return $name
            }
            if ($sym -and $sym.Kind.ToString() -eq 'Field' -and (Test-SourceType $sym.ContainingType)) {
                if ($sym.IsStatic) { return "[$(Get-PsTypeName $sym.ContainingType)]::$((Get-FieldName $sym))" }
                return "$(if ($script:ClassContext) { '$this' } else { '$self' }).$(Get-FieldName $sym)"
            }
            return "[$($sym.ToString())]"
        }
        'ParenthesizedExpressionSyntax' { return "($(Convert-Expression $e.Expression))" }
        'ThisExpressionSyntax' { return $(if ($script:ClassContext) { '$this' } else { '$self' }) }
        'PrefixUnaryExpressionSyntax' {
            $op = $e.OperatorToken.Text
            $x = Convert-Expression $e.Operand
            if ($op -in '++','--') { return Convert-Increment $e $false }
            if (Test-Nullable (Get-ExprType $e.Operand)) { return "(Invoke-CS2PSNullableUnary ($x) '$op' '$(Get-PsTypeName (Get-UnderlyingType (Get-ExprType $e)))' $(Get-CheckedFlag $e))" }
            if ($op -eq '~' -and (Test-Integral (Get-ExprType $e))) { return "(Invoke-CS2PSInteger ($x) 0 '~' '$(Get-PsTypeName (Get-ExprType $e))' `$false)" }
            if ($op -eq '-' -and (Test-Integral (Get-ExprType $e))) { return Convert-IntegerOperation $e '0' $x '-' (Get-ExprType $e) }
            switch ($op) { '!' { return "-not ($x)" } '-' { return "-($x)" } '+' { return "($x)" } default { Add-Diagnostic $e "prefix $op"; return '$null' } }
        }
        'PostfixUnaryExpressionSyntax' { if ($e.OperatorToken.Text -eq '!') { return Convert-Expression $e.Operand }; return Convert-Increment $e $true }
        'AssignmentExpressionSyntax' {
            if ($e.Left -is [Microsoft.CodeAnalysis.CSharp.Syntax.ThisExpressionSyntax]) { Add-Diagnostic $e 'assignment to this'; return '$null' }
            if ($e.Left -is [Microsoft.CodeAnalysis.CSharp.Syntax.ElementAccessExpressionSyntax]) {
                if ($e.OperatorToken.Text -ne '=') { Add-Diagnostic $e 'compound element assignment'; return '$null' }
                return "(Set-CS2PSElement ($(Convert-Expression $e.Left.Expression)) ($(Convert-Expression $e.Left.ArgumentList.Arguments[0].Expression)) ($(Convert-Value $e.Right)))"
            }
            $left = Convert-Expression $e.Left; $right = Convert-Value $e.Right
            $op = $e.OperatorToken.Text
            if ($op -eq '??=') {
                if ($e.Left -isnot [Microsoft.CodeAnalysis.CSharp.Syntax.IdentifierNameSyntax]) { Add-Diagnostic $e 'coalescing assignment requires a local or parameter'; return '$null' }
                return "`$(if (`$null -eq $left) { $left = $right }; ,$left)"
            }
            if ($op -ne '=' -and (Test-Nullable (Get-ExprType $e.Left))) {
                if ($e.Left -isnot [Microsoft.CodeAnalysis.CSharp.Syntax.IdentifierNameSyntax]) { Add-Diagnostic $e 'nullable compound assignment requires a local or parameter'; return '$null' }
                return "$left = (Invoke-CS2PSNullableBinary ($left) ($right) '$($op.TrimEnd('='))' '$(Get-PsTypeName (Get-UnderlyingType (Get-ExprType $e.Left)))' $(Get-CheckedFlag $e))"
            }
            if ($op -ne '=' -and (Test-Integral (Get-ExprType $e.Left))) {
                if (-not (Test-SimpleLValue $e.Left)) { Add-Diagnostic $e 'compound assignment with effectful receiver'; return '$null' }
                return "$left = $(Convert-IntegerOperation $e $left $right $op.TrimEnd('=') (Get-ExprType $e.Left))"
            }
            if ($op -eq '+=' -and (Test-String (Get-ExprType $e.Left))) { return "$left = [string]::Concat($left, $right)" }
            return "$left $op $right"
        }
        'ConditionalExpressionSyntax' { return "`$(if ($(Convert-Expression $e.Condition)) { $(Convert-Expression $e.WhenTrue) } else { $(Convert-Expression $e.WhenFalse) })" }
        'CastExpressionSyntax' {
            $target = $script:Model.GetTypeInfo($e.Type).Type
            $source = Get-ExprType $e.Expression
            $x = Convert-Expression $e.Expression
            if (Test-Nullable $target) {
                $underlying = Get-UnderlyingType $target
                if (Test-SourceStruct $underlying) { Add-Diagnostic $e 'casts to nullable source structs'; return '$null' }
                return "(Convert-CS2PSNullable ($x) '$(Get-PsTypeName $underlying)' $(Get-CheckedFlag $e))"
            }
            if (Test-Nullable $source) {
                if (-not $target.IsReferenceType) { $x = "(Get-CS2PSNullableValue ($x))" }
                $source = Get-UnderlyingType $source
            }
            if ($source.SpecialType.ToString() -eq 'System_Char' -and (Test-Floating $target)) { return "[$(Get-PsTypeName $target)][int]($x)" }
            if ((Test-Integral $target) -and (Test-Integral $source)) {
                $name = Get-PsTypeName $target
                $method = if ((Get-CheckedFlag $e) -eq '$true') { 'CreateChecked' } else { 'CreateTruncating' }
                $wide = if ((Get-PsTypeName $source) -eq 'char') { "[Numerics.BigInteger]([int]($x))" } else { "[Numerics.BigInteger]($x)" }
                if ($name -eq 'char') { return "[char][ushort]::$method[Numerics.BigInteger]($wide) <# C# narrowing preserves checked overflow or fixed-width wrapping. #>" }
                return "[$name]::$method[Numerics.BigInteger]($wide) <# C# narrowing preserves checked overflow or fixed-width wrapping. #>"
            }
            if ((Test-Integral $target) -and (Test-Floating $source)) {
                if ((Get-PsTypeName $target) -in 'int','uint','long','ulong' -and (Get-PsTypeName $source) -in 'double','float' -and (Get-CheckedFlag $e) -eq '$false') {
                    return "[$(Get-PsTypeName $target)]::CreateSaturating[$(Get-PsTypeName $source)]($x) <# C# floating conversion truncates and saturates on this runtime. #>"
                }
                return "(Convert-CS2PSFloatingInteger ($x) '$(Get-PsTypeName $target)' $(Get-CheckedFlag $e))"
            }
            return "[$(Get-PsTypeName $target)]$x"
        }
        'BinaryExpressionSyntax' { return (Convert-Binary $e) }
        'CheckedExpressionSyntax' { return Convert-Expression $e.Expression }
        'ThrowExpressionSyntax' { return "`$(throw (Get-CS2PSThrowException ($(Convert-Value $e.Expression))))" }
        'DefaultExpressionSyntax' {
            $t = Get-ExprType $e
            if (Test-SourceStruct $t) { return "[$(Get-PsTypeName $t)]::new()" }
            if ($t.IsReferenceType -or (Test-Nullable $t)) { return '$null' }
            return "[$(Get-PsTypeName $t)]0"
        }
        'SwitchExpressionSyntax' {
            if ((Get-ExprType $e.GoverningExpression).SpecialType.ToString() -eq 'System_Object') { Add-Diagnostic $e 'object switch subject' }
            $subject = '$' + (Get-GeneratedName $e 'switchValue')
            $text = "`$($subject = $(Convert-Expression $e.GoverningExpression); "
            $first = $true
            foreach ($arm in $e.Arms) {
                $test = Convert-Pattern $arm.Pattern $subject
                if ($arm.WhenClause) { $test = "($test) -and ($(Convert-Expression $arm.WhenClause.Condition))" }
                $keyword = if ($first) { 'if' } else { 'elseif' }; $first = $false
                $text += "$keyword ($test) { ,($(Convert-Expression $arm.Expression)) } "
            }
            return $text + "else { throw [System.Runtime.CompilerServices.SwitchExpressionException]::new($subject) })"
        }
        'ArrayCreationExpressionSyntax' {
            $t = Get-ExprType $e
            if ($t.Rank -ne 1) { Add-Diagnostic $e 'multidimensional array'; return '$null' }
            if (Test-SourceStruct $t.ElementType) { Add-Diagnostic $e 'arrays of source structs'; return '$null' }
            if ($e.Initializer) { return "[$(Get-PsTypeName $t)]@($(($e.Initializer.Expressions | ForEach-Object { Convert-Expression $_ }) -join ', '))" }
            return "[$(Get-PsTypeName $t)]::new($(Convert-Expression $e.Type.RankSpecifiers[0].Sizes[0]))"
        }
        'ImplicitArrayCreationExpressionSyntax' { return "[$(Get-PsTypeName (Get-ExprType $e))]@($(($e.Initializer.Expressions | ForEach-Object { Convert-Expression $_ }) -join ', '))" }
        'ElementAccessExpressionSyntax' {
            if ($e.ArgumentList.Arguments.Count -ne 1) { Add-Diagnostic $e 'multidimensional index'; return '$null' }
            $collectionType = Get-ExprType $e.Expression
            if ($collectionType -isnot [Microsoft.CodeAnalysis.IArrayTypeSymbol] -and -not (Test-String $collectionType) -and $collectionType.OriginalDefinition.ToString() -cne 'System.Collections.Generic.List<T>') { Add-Diagnostic $e 'index requires array, string or List<T>'; return '$null' }
            return "(Get-CS2PSElement ($(Convert-Expression $e.Expression)) ($(Convert-Expression $e.ArgumentList.Arguments[0].Expression)))"
        }
        'ObjectCreationExpressionSyntax' {
            if ($e.Initializer) { Add-Diagnostic $e 'object/collection initializer'; return '$null' }
            if (Test-Nullable (Get-ExprType $e)) {
                if ($e.ArgumentList.Arguments.Count -eq 0) { return '$null' }
                return Convert-Value $e.ArgumentList.Arguments[0].Expression
            }
            if (Test-SourceType (Get-ExprType $e)) {
                $sym = $script:Model.GetSymbolInfo($e).Symbol
                $args_ = @($e.ArgumentList.Arguments | ForEach-Object { Convert-Expression $_.Expression })
                return "[$(Get-PsTypeName $sym.ContainingType)]::new($($args_ -join ', '))"
            }
            return "[$(Get-PsTypeName (Get-ExprType $e))]::new($(($e.ArgumentList.Arguments | ForEach-Object { Convert-Expression $_.Expression }) -join ', '))"
        }
        'InvocationExpressionSyntax' {
            $args_ = ($e.ArgumentList.Arguments | ForEach-Object { Convert-Argument $_ }) -join ', '
            $sym = $script:Model.GetSymbolInfo($e).Symbol
            if ($sym.ReducedFrom) { Add-Diagnostic $e 'reduced extension method invocation'; return '$null' }
            if (Test-Nullable $sym.ContainingType) {
                $receiver = Convert-Expression $e.Expression.Expression
                if ($sym.Name -ceq 'GetValueOrDefault') {
                    $default = if ($e.ArgumentList.Arguments.Count) { Convert-Value $e.ArgumentList.Arguments[0].Expression } else { Get-DefaultValue (Get-UnderlyingType $sym.ContainingType) }
                    return "(Get-CS2PSNullableDefault ($receiver) ($default))"
                }
                if ($sym.Name -ceq 'ToString' -and -not $e.ArgumentList.Arguments.Count) { return "[string]::Concat([object]($receiver))" }
                Add-Diagnostic $e 'nullable method other than GetValueOrDefault/ToString'; return '$null'
            }
            if (-not (Test-SourceType $sym.ContainingType) -and $e.Expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax] -and (Test-SourceType (Get-ExprType $e.Expression.Expression))) {
                Add-Diagnostic $e 'inherited runtime methods on source classes/structs'; return '$null'
            }
            if (Test-SourceType $sym.ContainingType) {
                if (@($e.ArgumentList.Arguments | Where-Object { $_.NameColon }).Count -or $e.ArgumentList.Arguments.Count -ne $sym.Parameters.Length) { Add-Diagnostic $e 'named or optional arguments'; return '$null' }
                if ($script:ClassMethods.ContainsKey($sym.DeclaringSyntaxReferences[0].Span.Start)) {
                    if ($sym.IsStatic) {
                        $arguments = @($e.ArgumentList.Arguments | ForEach-Object { Convert-Argument $_ })
                        return "[$(Get-PsTypeName $sym.ContainingType)]::$($script:ClassMethods[$sym.DeclaringSyntaxReferences[0].Span.Start])($($arguments -join ', '))"
                    }
                    $receiver = if ($e.Expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax]) { Convert-Receiver $e.Expression.Expression } elseif ($script:ClassContext) { '$this' } else { '$self' }
                    $arguments = @($e.ArgumentList.Arguments | ForEach-Object { Convert-Argument $_ })
                    return "$receiver.$($script:ClassMethods[$sym.DeclaringSyntaxReferences[0].Span.Start])($($arguments -join ', '))"
                }
                $parts = @()
                if (-not $sym.IsStatic) {
                    $receiver = if ($e.Expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax]) { Convert-Expression $e.Expression.Expression } else { '$self' }
                    $parts += "-self ($receiver)"
                }
                for ($i = 0; $i -lt $sym.Parameters.Length; $i++) { $parts += '-'+(Get-VariableName $sym.Parameters[$i])+' ('+(Convert-Argument $e.ArgumentList.Arguments[$i])+')' }
                return "($(Get-MethodFunction $sym) $($parts -join ' '))"
            }
            if ($sym.IsGenericMethod -or @($e.ArgumentList.Arguments | Where-Object { $_.NameColon }).Count -or @($sym.Parameters | Where-Object { $_.RefKind.ToString() -notin 'None','Ref','Out' }).Count -or @($sym.Parameters | Where-Object { $_.RefKind.ToString() -in 'Ref','Out' }).Count -gt 1) { Add-Diagnostic $e 'generic/named/in runtime invocation or multiple runtime ref arguments'; return '$null' }
            if ($e.Expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax]) {
                $types = @($sym.Parameters | ForEach-Object {
                    $typeName = '[' + (Get-PsTypeName $_.Type) + ']'
                    if ($_.RefKind.ToString() -ne 'None') { '(' + $typeName + ').MakeByRefType()' } else { $typeName }
                })
                $values = @($e.ArgumentList.Arguments | ForEach-Object { Convert-Argument $_ })
                if ($sym.Parameters.Length -and $sym.Parameters[-1].IsParams) {
                    if ($sym.Parameters[-1].Type.IsRefLikeType) {
                        if ($sym.ContainingType.SpecialType.ToString() -eq 'System_String' -and $sym.Name -ceq 'Format' -and $sym.Parameters[-1].Type.TypeArguments[0].SpecialType.ToString() -eq 'System_Object') {
                            # Expanded .NET 11 params spans use the equivalent object[] formatting overload.
                            $types[-1] = '[object[]]'
                        } else { Add-Diagnostic $e 'runtime params span requires a supported lowering'; return '$null' }
                    }
                    $fixed = $sym.Parameters.Length - 1
                    $explicitArray = $values.Count -eq $sym.Parameters.Length -and (Get-ExprType $e.ArgumentList.Arguments[-1].Expression) -is [Microsoft.CodeAnalysis.IArrayTypeSymbol]
                    if (-not $explicitArray) {
                        $tail = @(); for ($i = $fixed; $i -lt $values.Count; $i++) { $tail += $values[$i] }
                        $head = @(); for ($i = 0; $i -lt $fixed; $i++) { $head += $values[$i] }
                        $values = $head + @((New-ArgumentArray $tail))
                    }
                }
                if ($values.Count -ne $sym.Parameters.Length) { Add-Diagnostic $e 'optional runtime arguments'; return '$null' }
                $receiver = if ($sym.IsStatic) { '$null' } else { Convert-Expression $e.Expression.Expression }
                $static = if ($sym.IsStatic) { '$true' } else { '$false' }
                # Exact typed arguments are the best match for a unique reflected signature.
                $policy = Get-CS2PSCallPolicy $sym
                $inventory = if ($script:ApiCatalog) { @(Find-CS2PSApi -Catalog $script:ApiCatalog -AssemblyIdentity $sym.ContainingAssembly.Identity.ToString() -Id (Get-CS2PSApiId $sym) -Limit 2) } else { @() }
                if ($script:ApiCatalog -and $inventory.Count -ne 1) { Add-Diagnostic $e 'selected API is absent or ambiguous in the exact toolchain catalog'; return '$null' }
                $direct = $policy.Candidate -and (-not $script:ApiCatalog -or $inventory[0].Api.CallPolicy.Candidate)
                $runtimeType = (Get-PsTypeName $sym.ContainingType) -as [type]
                if ($direct -and $runtimeType) {
                    $parameterTypes = [type[]]@($sym.Parameters | ForEach-Object { (Get-PsTypeName $_.Type) -as [type] })
                    $flags = if ($sym.IsStatic) { [Reflection.BindingFlags]'Public,Static' } else { [Reflection.BindingFlags]'Public,Instance' }
                    $selected = $runtimeType.GetMethod($sym.Name, $flags, $null, $parameterTypes, $null)
                    $direct = $null -ne $selected
                } else { $direct = $false }
                $script:ApiCalls.Add([pscustomobject]@{Id=(Get-CS2PSApiId $sym); Assembly=$sym.ContainingAssembly.Identity.ToString(); Line=$e.GetLocation().GetLineSpan().StartLinePosition.Line+1; CatalogMatched=$inventory.Count -eq 1; Form=if ($direct) {'Direct'} else {'Reflection'}; Reasons=@($policy.Reasons); Semantics=if ($inventory.Count) {$inventory[0].Api.Semantics} else {'Unreviewed'}; Lowering='Unknown'})
                if ($direct) {
                    $typedValues = for ($i = 0; $i -lt $values.Count; $i++) {
                        if ($e.ArgumentList.Arguments[$i].Expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.LiteralExpressionSyntax] -and (Get-ExprType $e.ArgumentList.Arguments[$i].Expression).SpecialType -eq $sym.Parameters[$i].Type.SpecialType) { $values[$i] }
                        else { "[$(Get-PsTypeName $sym.Parameters[$i].Type)]($($values[$i]))" }
                    }
                    $target = if ($sym.IsStatic) { "[$(Get-PsTypeName $sym.ContainingType)]::" } else { "$(Convert-Receiver $e.Expression.Expression)." }
                    return "$target$($sym.Name)($($typedValues -join ', '))"
                }
                return "(Invoke-CS2PSRuntime ([$(Get-PsTypeName $sym.ContainingType)]) ($receiver) '$($sym.Name)' ([type[]]@($($types -join ', '))) ($(New-ArgumentArray $values)) $static) <# Reflection preserves the selected object/null, ref or expanded params signature. #>"
            }
            Add-Diagnostic $e 'unsupported invocation form'; return '$null'
        }
        'MemberAccessExpressionSyntax' {
            $sym = $script:Model.GetSymbolInfo($e).Symbol
            if (Test-Nullable $sym.ContainingType) {
                $receiver = Convert-Expression $e.Expression
                if ($sym.Name -ceq 'HasValue') { return "(`$null -ne ($receiver))" }
                if ($sym.Name -ceq 'Value') { return "(Get-CS2PSNullableValue ($receiver))" }
                Add-Diagnostic $e 'unsupported nullable member'; return '$null'
            }
            if ($sym.Kind.ToString() -eq 'Field' -and (Test-SourceType $sym.ContainingType)) {
                if ($sym.IsStatic) { return "[$(Get-PsTypeName $sym.ContainingType)]::$((Get-FieldName $sym))" }
                return "$(Convert-Receiver $e.Expression).$(Get-FieldName $sym)"
            }
            if ($sym -and $sym.IsStatic) { return "[$(Get-PsTypeName $sym.ContainingType)]::$($sym.Name)" }
            return "$(Convert-Receiver $e.Expression).$($e.Name.Identifier.Text)"
        }
        default { Add-Diagnostic $e "expression $($e.GetType().Name) is not supported yet"; return "<# CS2PS: unsupported $($e.GetType().Name) #>" }
    }
}

function Convert-Binary($e) {
    $l = Convert-Expression $e.Left; $r = Convert-Expression $e.Right
    $lt = Get-ExprType $e.Left; $rt = Get-ExprType $e.Right
    $op = $e.OperatorToken.Text
    $strings = (Test-String $lt) -or (Test-String $rt)
    if ($op -in '==','!=' -and (($lt -and $lt.IsReferenceType) -or ($rt -and $rt.IsReferenceType))) {
        $operation = $script:Model.GetOperation($e, [Threading.CancellationToken]::None)
        if ($operation.LeftOperand.Type.SpecialType.ToString() -eq 'System_String') { $test = "[object]::Equals($l, $r) <# String.Equals is ordinal; object arguments preserve null versus empty. #>" }
        else { $test = "[object]::ReferenceEquals($l, $r)" }
        if ($op -eq '!=') { return "(-not ($test))" }; return "($test)"
    }
    if ($op -eq '??') {
        $value = '$' + (Get-GeneratedName $e 'coalescedValue')
        $resultType = Get-ExprType $e
        $nonNull = if ((Test-Integral $resultType) -or (Test-Floating $resultType)) { "[$(Get-PsTypeName $resultType)]$value" } else { $value }
        return "`$($value = $l; if (`$null -eq $value) { ,($r) } else { ,($nonNull) })"
    }
    if ((Test-Nullable $lt) -or (Test-Nullable $rt)) {
        $type = Get-UnderlyingType (Get-ExprType $e)
        if ($op -in '==','!=','<','>','<=','>=') {
            $operation = $script:Model.GetOperation($e, [Threading.CancellationToken]::None)
            $type = Get-UnderlyingType $operation.LeftOperand.Type
            if (-not $type) { $type = Get-UnderlyingType $operation.RightOperand.Type }
        }
        if ($op -notin '+','-','*','/','%','&','|','^','<<','>>','>>>','==','!=','<','>','<=','>=') { Add-Diagnostic $e 'unsupported lifted operator'; return '$null' }
        return "(Invoke-CS2PSNullableBinary ($l) ($r) '$op' '$(Get-PsTypeName $type)' $(Get-CheckedFlag $e))"
    }
    if (($op -in '+','-','*','/','%','==','!=','<','>','<=','>=') -and ((Test-Floating $lt) -or (Test-Floating $rt))) {
        $operation = $script:Model.GetOperation($e, [Threading.CancellationToken]::None)
        if ($operation.LeftOperand.Type.SpecialType.ToString() -eq 'System_Double') {
            $operators = @{ '+'='+'; '-'='-'; '*'='*'; '/'='/'; '%'='%'; '=='='-eq'; '!='='-ne'; '<'='-lt'; '>'='-gt'; '<='='-le'; '>='='-ge' }
            return "([double]($l) $($operators[$op]) [double]($r))"
        }
        return "(Invoke-CS2PSNumber ($l) ($r) '$op' '$(Get-PsTypeName $operation.LeftOperand.Type)' $(Get-CheckedFlag $e))"
    }
    if ($op -in '==','!=','<','>','<=','>=' -and (Test-Integral $lt) -and (Test-Integral $rt)) {
        $operation = $script:Model.GetOperation($e, [Threading.CancellationToken]::None)
        if ($operation.LeftOperand.Type.SpecialType -eq $operation.RightOperand.Type.SpecialType -and (Get-PsTypeName $operation.LeftOperand.Type) -in 'int','long','uint','ulong') {
            $operators = @{ '=='='-eq'; '!='='-ne'; '<'='-lt'; '>'='-gt'; '<='='-le'; '>='='-ge' }
            $promoted = Get-PsTypeName $operation.LeftOperand.Type
            if ($lt.SpecialType -ne $operation.LeftOperand.Type.SpecialType) { $l = "[$promoted]($l)" }
            if ($rt.SpecialType -ne $operation.RightOperand.Type.SpecialType) { $r = "[$promoted]($r)" }
            return "($l $($operators[$op]) $r)"
        }
        return "(Compare-CS2PSInteger ($l) ($r) '$op')"
    }
    if ($op -in '&','|','^' -and (Get-ExprType $e).SpecialType.ToString() -eq 'System_Boolean') { return "(Invoke-CS2PSBoolean ($l) ($r) '$op')" }
    if ($op -in '&','|','^','<<','>>','>>>' -and (Test-Integral (Get-ExprType $e))) { return "(Invoke-CS2PSInteger ($l) ($r) '$op' '$(Get-PsTypeName (Get-ExprType $e))' `$false)" }
    if ($op -in '+','-','*','/','%' -and (Test-Integral (Get-ExprType $e))) {
        return Convert-IntegerOperation $e $l $r $op (Get-ExprType $e)
    }
    switch ($op) {
        '+' { if ($strings) { return "[string]::Concat($l, $r)" }; return "$l + $r" }   # C# concatenation, never numeric addition
        '/' {
            if ((Test-Integral $lt) -and (Test-Integral $rt)) { return "[Math]::DivRem($l, $r).Item1" }   # C# truncates toward zero; PowerShell would return a double
            return "$l / $r"
        }
        '-' { return "$l - $r" } '*' { return "$l * $r" } '%' { return "$l % $r" }
        '==' { return $(if ($strings) { "$l -ceq $r" } else { "$l -eq $r" }) }
        '!=' { return $(if ($strings) { "$l -cne $r" } else { "$l -ne $r" }) }
        '<' { return $(if ($strings) { "$l -clt $r" } else { "$l -lt $r" }) }
        '>' { return $(if ($strings) { "$l -cgt $r" } else { "$l -gt $r" }) }
        '<=' { return $(if ($strings) { "$l -cle $r" } else { "$l -le $r" }) }
        '>=' { return $(if ($strings) { "$l -cge $r" } else { "$l -ge $r" }) }
        '&&' { return "$l -and $r" } '||' { return "$l -or $r" }
        '&' { return "$l -band $r" } '|' { return "$l -bor $r" } '^' { return "$l -bxor $r" }
        '<<' { return "$l -shl $r" } '>>' { return "$l -shr $r" }
        default { Add-Diagnostic $e "operator $op is not supported yet"; return "<# CS2PS: operator $op #>" }
    }
}

function Convert-Increment($e, [bool] $postfix) {
    $type = Get-ExprType $e.Operand
    $nullable = Test-Nullable $type
    $type = Get-UnderlyingType $type
    if (-not (Test-Integral $type)) { Add-Diagnostic $e 'increment requires an integral local, parameter or simple field'; return '$null' }
    if (-not (Test-SimpleLValue $e.Operand)) { Add-Diagnostic $e 'increment with effectful lvalue'; return '$null' }
    $left = Convert-Expression $e.Operand
    $old = '$' + (Get-GeneratedName $e 'previousValue')
    $op = if ($e.OperatorToken.Text -eq '++') { '+' } else { '-' }
    $value = if ($postfix) { $old } else { $left }
    $operation = if ($nullable) { "(Invoke-CS2PSNullableBinary ($old) 1 '$op' '$(Get-PsTypeName $type)' $(Get-CheckedFlag $e))" } else { Convert-IntegerOperation $e $old '1' $op $type }
    return "`$($old = $left; $left = $operation; $value)"
}
