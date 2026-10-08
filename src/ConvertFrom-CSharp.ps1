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

    Supported in this first slice: static methods; parameters and locals of
    simple types; if/else, for, foreach, while, return, blocks; assignment and
    compound assignment; ++/--; arithmetic, comparison, logical and
    conditional expressions; casts; calls to static .NET members and to
    instance members of values.
.OUTPUTS
    An object with the generated PowerShell text and its diagnostics.
#>
function ConvertFrom-CSharp {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')] [string] $Path,
        [Parameter(Mandatory, ParameterSetName = 'Source')] [string] $Source
    )
    Initialize-Roslyn
    if ($Path) { $Source = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path) }

    $tree = [Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($Source)
    $refs = [System.Collections.Generic.List[Microsoft.CodeAnalysis.MetadataReference]]::new()
    $runtimeDir = [IO.Path]::GetDirectoryName([object].Assembly.Location)
    foreach ($n in 'System.Private.CoreLib.dll', 'System.Runtime.dll', 'System.Collections.dll', 'System.Console.dll') {
        $refs.Add([Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile([IO.Path]::Combine($runtimeDir, $n)))
    }
    $options = [Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
    $compilation = [Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('CS2PS', [Microsoft.CodeAnalysis.SyntaxTree[]]@($tree), $refs, $options)
    $script:Model = $compilation.GetSemanticModel($tree)
    $script:Diagnostics = [System.Collections.Generic.List[object]]::new()
    $script:Methods = [System.Collections.Generic.List[object]]::new()
    $script:SourceTypes = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $script:MethodNames = @{}
    $script:UnitId = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Source))).Substring(0,12)

    $errors = @($compilation.GetDiagnostics() | Where-Object { $_.Severity -eq [Microsoft.CodeAnalysis.DiagnosticSeverity]::Error })
    if ($errors.Count) { throw "C# source does not compile: $($errors[0])" }

    $out = [System.Text.StringBuilder]::new()
    [void]$out.AppendLine(@'
# C# element access throws rather than accepting PowerShell negative indices.
function Get-CS2PSElement($collection, [int] $index) {
    if ($null -eq $collection) { throw [NullReferenceException]::new() }
    $count = if ($collection -is [array]) { $collection.Length } else { $collection.Count }
    if ($index -lt 0 -or $index -ge $count) {
        if ($collection -is [array]) { throw [IndexOutOfRangeException]::new() }
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
'@)
    $types = @($tree.GetRoot().DescendantNodes() | Where-Object { $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.TypeDeclarationSyntax] })
    $usedNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($type in $types) {
        $symbol = $script:Model.GetDeclaredSymbol($type)
        $script:SourceTypes[$symbol.ToString()] = "CS2PS_$($script:UnitId)_t$($type.Span.Start)"
        foreach ($m in $type.Members | Where-Object { $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax] }) {
            $method = $script:Model.GetDeclaredSymbol($m)
            $name = Get-FunctionName $type.Identifier.Text $m.Identifier.Text ($method.ReturnType.SpecialType.ToString() -ne 'System_Void')
            if (-not $usedNames.Add($name)) { $name += '_m' + $m.Span.Start; [void]$usedNames.Add($name) }
            $script:MethodNames[$m.Span.Start] = $name
        }
    }
    foreach ($type in $types) { [void]$out.AppendLine((Convert-TypeDeclaration $type)) }
    foreach ($type in $types) {
        foreach ($m in $type.Members | Where-Object { $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.MethodDeclarationSyntax] }) {
            [void]$out.AppendLine((Convert-Method $type $m)).AppendLine()
        }
    }
    # Fail closed: a diagnostic never leaves a partially translated program executable.
    if ($script:Diagnostics.Count) {
        $out.Clear() | Out-Null
        foreach ($d in $script:Diagnostics) { [void]$out.AppendLine("# CS2PS: unsupported at line $($d.Line): $($d.Message)") }
        [void]$out.AppendLine("throw [NotSupportedException]::new('CS2PS translation has diagnostics.')")
    }
    [pscustomobject]@{ PowerShell = $out.ToString().TrimEnd() + "`n"; Diagnostics = $script:Diagnostics.ToArray(); Methods = $script:Methods.ToArray() }
}

function Initialize-Roslyn {
    if ('Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree' -as [type]) { return }
    foreach ($n in 'Microsoft.CodeAnalysis.dll', 'Microsoft.CodeAnalysis.CSharp.dll') {
        [void][Reflection.Assembly]::LoadFrom([IO.Path]::Combine($PSHOME, $n))
    }
}

function Add-Diagnostic($node, [string] $message) {
    $line = $node.GetLocation().GetLineSpan().StartLinePosition.Line + 1
    $script:Diagnostics.Add([pscustomobject]@{ Line = $line; Message = $message })
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
        'System_UInt32' { return 'uint' } 'System_UInt64' { return 'ulong' } 'System_Decimal' { return 'decimal' }
        'System_Void' { return $null }
    }
    $typeSymbol.ToString()
}

# Syntax positions identify declared symbols, including shadowed and case-only names.
function Get-VariableName($symbol) { 'v' + $symbol.DeclaringSyntaxReferences[0].Span.Start }
function Get-StorageType($symbol) {
    if (Test-String $symbol) { return 'object' } # [string] silently converts null to empty.
    Get-PsTypeName $symbol
}

function Test-SourceType($symbol) { $symbol -and $script:SourceTypes.ContainsKey($symbol.ToString()) }
function Get-FieldName($symbol) { 'f' + $symbol.DeclaringSyntaxReferences[0].Span.Start }
function Get-MethodFunction($symbol) { $script:MethodNames[$symbol.DeclaringSyntaxReferences[0].Span.Start] }
function Get-ConstructorFunction($symbol) {
    $suffix = if ($symbol.DeclaringSyntaxReferences.Length) { $symbol.DeclaringSyntaxReferences[0].Span.Start } else { 'default' }
    'New-' + (Get-PsTypeName $symbol.ContainingType) + '_' + $suffix
}

function Convert-TypeDeclaration($node) {
    if ($node -isnot [Microsoft.CodeAnalysis.CSharp.Syntax.ClassDeclarationSyntax] -or $node.BaseList -or $node.TypeParameterList -or $node.ParameterList -or @($node.Modifiers | Where-Object { $_.Text -in 'partial','abstract','unsafe' }).Count) {
        Add-Diagnostic $node 'only simple non-generic classes are supported'; return ''
    }
    $symbol = $script:Model.GetDeclaredSymbol($node)
    $typeName = Get-PsTypeName $symbol
    $text = "class $typeName {`n"
    $fields = @($node.Members | Where-Object { $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.FieldDeclarationSyntax] })
    foreach ($field in $fields) {
        if (@($field.Modifiers | Where-Object { $_.Text -in 'readonly','volatile','const' }).Count) { Add-Diagnostic $field 'readonly, volatile and const fields'; continue }
        foreach ($v in $field.Declaration.Variables) {
            $f = $script:Model.GetDeclaredSymbol($v)
            $static = if ($f.IsStatic) { 'static ' } else { '' }
            $text += "    $static[$(Get-StorageType $f.Type)] `$$(Get-FieldName $f)`n"
            if ($f.IsStatic -and $v.Initializer) { Add-Diagnostic $v 'static field initializer' }
        }
    }
    $text += "}`n"
    foreach ($member in $node.Members) {
        if ($member.GetType().Name -notin 'MethodDeclarationSyntax','FieldDeclarationSyntax','ConstructorDeclarationSyntax','ClassDeclarationSyntax') { Add-Diagnostic $member "type member $($member.GetType().Name)" }
    }
    foreach ($ctor in $symbol.InstanceConstructors) {
        $name = Get-ConstructorFunction $ctor
        $parameters = @($ctor.Parameters | ForEach-Object { "[$(Get-StorageType $_.Type)] `$$(Get-VariableName $_)" })
        $text += "function $name {`n    param($($parameters -join ', '))`n    `$self = [$typeName]::new()`n"
        foreach ($field in $fields) {
            foreach ($v in $field.Declaration.Variables) {
                $f = $script:Model.GetDeclaredSymbol($v)
                if (-not $f.IsStatic -and $v.Initializer) { $text += "    `$self.$(Get-FieldName $f) = $(Convert-Expression $v.Initializer.Value)`n" }
            }
        }
        if ($ctor.DeclaringSyntaxReferences.Length) {
            $syntax = $ctor.DeclaringSyntaxReferences[0].GetSyntax([Threading.CancellationToken]::None)
            if ($syntax.Initializer -or @($syntax.Modifiers | Where-Object { $_.Text -eq 'static' }).Count) { Add-Diagnostic $syntax 'constructor chaining/static constructor' }
            if ($syntax.Body) { foreach ($s in $syntax.Body.Statements) { $text += Convert-Statement $s 1 } }
            elseif ($syntax.ExpressionBody) { $text += "    [void]($(Convert-Expression $syntax.ExpressionBody.Expression))`n" }
        }
        $text += "    return ,`$self`n}`n"
    }
    return $text
}

function Test-Integral($typeSymbol) { $typeSymbol -and $typeSymbol.SpecialType.ToString() -in 'System_Int32', 'System_Int64', 'System_Int16', 'System_Byte', 'System_UInt32', 'System_UInt64', 'System_SByte', 'System_UInt16' }
function Test-Floating($typeSymbol) { $typeSymbol -and $typeSymbol.SpecialType.ToString() -in 'System_Double', 'System_Single', 'System_Decimal' }
function Test-String($typeSymbol) { $typeSymbol -and $typeSymbol.SpecialType.ToString() -eq 'System_String' }
function Get-ExprType($expr) { $script:Model.GetTypeInfo($expr).Type }

# Method names map to approved verbs; the rest become Get- (value) or Invoke- (void).
function Get-FunctionName([string] $class, [string] $method, [bool] $returnsValue) {
    $map = [ordered]@{ Get = 'Get'; Set = 'Set'; Is = 'Test'; Has = 'Test'; Can = 'Test'; Compute = 'Measure'; Calculate = 'Measure'
        Format = 'Format'; Parse = 'ConvertFrom'; Convert = 'Convert'; Clear = 'Clear'; Add = 'Add'; Remove = 'Remove'; Find = 'Find'; Reset = 'Reset'; New = 'New'; Create = 'New' }
    foreach ($k in $map.Keys) {
        if ($method -cmatch "^$k(?=[A-Z])") { return '{0}-{1}{2}' -f $map[$k], $class, $method.Substring($k.Length) }
    }
    '{0}-{1}{2}' -f ($(if ($returnsValue) { 'Get' } else { 'Invoke' })), $class, $method
}

function Convert-Method($type, $m) {
    $symbol = $script:Model.GetDeclaredSymbol($m)
    $returnType = Get-PsTypeName $symbol.ReturnType
    $name = Get-MethodFunction $symbol
    if ($symbol.IsGenericMethod -or $symbol.IsVirtual -or $symbol.IsOverride -or $symbol.IsAbstract -or $symbol.ReturnsByRef -or $symbol.ReturnsByRefReadonly -or @($m.Modifiers | Where-Object { $_.Text -in 'async','extern' }).Count) { Add-Diagnostic $m 'generic, virtual, ref-return, async or extern method' }
    $before = $script:Diagnostics.Count
    $script:Methods.Add([pscustomobject]@{ Type = $symbol.ContainingType.ToString(); Method = $symbol.Name; Function = $name; Parameters = @($symbol.Parameters | ForEach-Object { Get-VariableName $_ }) })
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("function $name {")
    [void]$sb.AppendLine('    [CmdletBinding()]')
    if ($returnType) { [void]$sb.AppendLine("    [OutputType([$returnType])]") }
    $params = foreach ($p in $symbol.Parameters) { "        [AllowNull()] [AllowEmptyString()] [AllowEmptyCollection()] [$(Get-StorageType $p.Type)] `$$(Get-VariableName $p)" }
    if (-not $symbol.IsStatic) { $params = @('        [object] $self') + @($params) }
    [void]$sb.AppendLine('    param(')
    if ($params) { [void]$sb.AppendLine(($params -join ",`n")) }
    [void]$sb.AppendLine('    )')
    $line = $m.GetLocation().GetLineSpan().StartLinePosition.Line + 1
    [void]$sb.AppendLine("    # From C# $($type.Identifier.Text).$($m.Identifier.Text) (line $line).")
    if (-not $symbol.IsStatic) { [void]$sb.AppendLine('    if ($null -eq $self) { throw [NullReferenceException]::new() }') }
    if ($m.Body) { foreach ($s in $m.Body.Statements) { [void]$sb.Append((Convert-Statement $s 1)) } }
    elseif ($m.ExpressionBody) { [void]$sb.AppendLine("    return ,($(Convert-Expression $m.ExpressionBody.Expression))") }
    [void]$sb.Append('}')
    $sb.ToString()
}

function Convert-Statement($s, [int] $depth) {
    $pad = '    ' * $depth
    switch ($s.GetType().Name) {
        'LocalDeclarationStatementSyntax' {
            $lines = foreach ($v in $s.Declaration.Variables) {
                $t = Get-StorageType ($script:Model.GetDeclaredSymbol($v).Type)
                $init = if ($v.Initializer) { ' = ' + (Convert-Expression $v.Initializer.Value) } else { '' }
                "$pad[$t] `$$(Get-VariableName ($script:Model.GetDeclaredSymbol($v)))$init`n"
            }
            return ($lines -join '')
        }
        'ExpressionStatementSyntax' { return "${pad}[void]($(Convert-Expression $s.Expression))`n" }
        'ReturnStatementSyntax' { return $(if ($s.Expression) { "${pad}return ,($(Convert-Expression $s.Expression))`n" } else { "${pad}return`n" }) }
        'EmptyStatementSyntax' { return '' }
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
            $inc = ($s.Incrementors | ForEach-Object { '[void](' + (Convert-Expression $_) + ')' }) -join '; '
            return "${pad}$init`n${pad}:loop$($s.Span.Start) for (; $cond; `$($inc)) {`n$(Convert-Embedded $s.Statement ($depth + 1))$pad}`n"
        }
        'ForEachStatementSyntax' {
            $t = Get-ExprType $s.Expression
            if ($t -isnot [Microsoft.CodeAnalysis.IArrayTypeSymbol] -and $t.OriginalDefinition.ToString() -cne 'System.Collections.Generic.List<T>') {
                Add-Diagnostic $s 'foreach requires a single-dimensional array or List<T>'; return ''
            }
            if ($t -is [Microsoft.CodeAnalysis.IArrayTypeSymbol] -and $t.Rank -ne 1) { Add-Diagnostic $s 'multidimensional foreach'; return '' }
            $id = $s.Span.Start
            $v = Get-VariableName ($script:Model.GetDeclaredSymbol($s))
            # Use a real enumerator: List<T> must detect mutation; evaluate collection once.
            return "${pad}`$enumerator$id = ($(Convert-Expression $s.Expression)).GetEnumerator()`n${pad}try {`n${pad}    :loop$id while (`$enumerator$id.MoveNext()) {`n${pad}        [$((Get-PsTypeName ($script:Model.GetDeclaredSymbol($s).Type)))] `$$v = `$enumerator$id.Current`n$(Convert-Embedded $s.Statement ($depth + 2))${pad}    }`n${pad}} finally {`n${pad}    if (`$enumerator$id -is [IDisposable]) { `$enumerator$id.Dispose() }`n${pad}}`n"
        }
        'WhileStatementSyntax' { return "${pad}:loop$($s.Span.Start) while ($(Convert-Expression $s.Condition)) {`n$(Convert-Embedded $s.Statement ($depth + 1))$pad}`n" }
        'BreakStatementSyntax' { return "${pad}break $(Get-JumpLabel $s $false)`n" }
        'ContinueStatementSyntax' { return "${pad}continue $(Get-JumpLabel $s $true)`n" }
        'SwitchStatementSyntax' {
            $id = $s.Span.Start; $subject = "`$switchValue$id"
            $text = "${pad}$subject = $(Convert-Expression $s.Expression)`n${pad}:switch$id do {`n"
            $sections = @($s.Sections | Where-Object { -not @($_.Labels | Where-Object { $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.DefaultSwitchLabelSyntax] }).Count })
            $defaults = @($s.Sections | Where-Object { @($_.Labels | Where-Object { $_ -is [Microsoft.CodeAnalysis.CSharp.Syntax.DefaultSwitchLabelSyntax] }).Count })
            $first = $true
            foreach ($section in $sections) {
                $tests = foreach ($label in $section.Labels) {
                    if ($label -is [Microsoft.CodeAnalysis.CSharp.Syntax.CaseSwitchLabelSyntax]) { "($subject -ceq ($(Convert-Expression $label.Value)))" }
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
        if ($parent.GetType().Name -in 'ForStatementSyntax','ForEachStatementSyntax','WhileStatementSyntax') { return 'loop' + $parent.Span.Start }
        if (-not $continue -and $parent -is [Microsoft.CodeAnalysis.CSharp.Syntax.SwitchStatementSyntax]) { return 'switch' + $parent.Span.Start }
        $parent = $parent.Parent
    }
    Add-Diagnostic $s 'jump target is outside the supported subset'
}

function Convert-Pattern($pattern, [string] $subject) {
    switch ($pattern.GetType().Name) {
        'ConstantPatternSyntax' { return "($subject -ceq ($(Convert-Expression $pattern.Expression)))" }
        'DiscardPatternSyntax' { return '$true' }
        default { Add-Diagnostic $pattern "pattern $($pattern.GetType().Name)"; return '$false' }
    }
}

function Convert-Expression($e) {
    switch ($e.GetType().Name) {
        'LiteralExpressionSyntax' {
            $v = $e.Token.Value
            if ($v -is [string]) { return "'" + ($v -replace "'", "''") + "'" }
            if ($v -is [bool]) { return $(if ($v) { '$true' } else { '$false' }) }
            if ($null -eq $v) { return '$null' }
            if ($v -is [char]) { return "[char]'$v'" }
            return $e.Token.Text -replace '[fFdDmM]$', ''
        }
        'IdentifierNameSyntax' {
            $sym = $script:Model.GetSymbolInfo($e).Symbol
            if ($sym -and $sym.Kind.ToString() -in 'Local', 'Parameter') { return '$' + (Get-VariableName $sym) }
            if ($sym -and $sym.Kind.ToString() -eq 'Field' -and (Test-SourceType $sym.ContainingType)) {
                if ($sym.IsStatic) { return "[$(Get-PsTypeName $sym.ContainingType)]::$((Get-FieldName $sym))" }
                return "`$self.$(Get-FieldName $sym)"
            }
            return "[$($sym.ToString())]"
        }
        'ParenthesizedExpressionSyntax' { return "($(Convert-Expression $e.Expression))" }
        'ThisExpressionSyntax' { return '$self' }
        'PrefixUnaryExpressionSyntax' {
            $op = $e.OperatorToken.Text
            $x = Convert-Expression $e.Operand
            switch ($op) { '!' { return "-not $x" } '-' { return "-$x" } '++' { return "++$x" } '--' { return "--$x" } default { Add-Diagnostic $e "prefix $op"; return "$op$x" } }
        }
        'PostfixUnaryExpressionSyntax' { return "$(Convert-Expression $e.Operand)$($e.OperatorToken.Text)" }
        'AssignmentExpressionSyntax' {
            if ($e.Left -is [Microsoft.CodeAnalysis.CSharp.Syntax.ElementAccessExpressionSyntax]) {
                if ($e.OperatorToken.Text -ne '=') { Add-Diagnostic $e 'compound element assignment'; return '$null' }
                return "(Set-CS2PSElement ($(Convert-Expression $e.Left.Expression)) ($(Convert-Expression $e.Left.ArgumentList.Arguments[0].Expression)) ($(Convert-Expression $e.Right)))"
            }
            return "$(Convert-Expression $e.Left) $($e.OperatorToken.Text) $(Convert-Expression $e.Right)"
        }
        'ConditionalExpressionSyntax' { return "`$(if ($(Convert-Expression $e.Condition)) { $(Convert-Expression $e.WhenTrue) } else { $(Convert-Expression $e.WhenFalse) })" }
        'CastExpressionSyntax' {
            $target = $script:Model.GetTypeInfo($e.Type).Type
            $source = Get-ExprType $e.Expression
            $x = Convert-Expression $e.Expression
            if ((Test-Integral $target) -and (Test-Floating $source)) { return "[$(Get-PsTypeName $target)][Math]::Truncate($x)" }   # C# truncates; PowerShell rounds
            return "[$(Get-PsTypeName $target)]$x"
        }
        'BinaryExpressionSyntax' { return (Convert-Binary $e) }
        'SwitchExpressionSyntax' {
            $subject = "`$switchValue$($e.Span.Start)"
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
            if ($e.Initializer) { return "[$(Get-PsTypeName $t)]@($(($e.Initializer.Expressions | ForEach-Object { Convert-Expression $_ }) -join ', '))" }
            return "[$(Get-PsTypeName $t)]::new($(Convert-Expression $e.Type.RankSpecifiers[0].Sizes[0]))"
        }
        'ImplicitArrayCreationExpressionSyntax' { return "[$(Get-PsTypeName (Get-ExprType $e))]@($(($e.Initializer.Expressions | ForEach-Object { Convert-Expression $_ }) -join ', '))" }
        'ElementAccessExpressionSyntax' {
            if ($e.ArgumentList.Arguments.Count -ne 1) { Add-Diagnostic $e 'multidimensional index'; return '$null' }
            return "(Get-CS2PSElement ($(Convert-Expression $e.Expression)) ($(Convert-Expression $e.ArgumentList.Arguments[0].Expression)))"
        }
        'ObjectCreationExpressionSyntax' {
            if ($e.Initializer) { Add-Diagnostic $e 'object/collection initializer'; return '$null' }
            if (Test-SourceType (Get-ExprType $e)) {
                $sym = $script:Model.GetSymbolInfo($e).Symbol
                $args_ = for ($i = 0; $i -lt $sym.Parameters.Length; $i++) { '-'+(Get-VariableName $sym.Parameters[$i])+' ('+(Convert-Expression $e.ArgumentList.Arguments[$i].Expression)+')' }
                return "($(Get-ConstructorFunction $sym) $($args_ -join ' '))"
            }
            return "[$(Get-PsTypeName (Get-ExprType $e))]::new($(($e.ArgumentList.Arguments | ForEach-Object { Convert-Expression $_.Expression }) -join ', '))"
        }
        'InvocationExpressionSyntax' {
            $args_ = ($e.ArgumentList.Arguments | ForEach-Object { Convert-Expression $_.Expression }) -join ', '
            $sym = $script:Model.GetSymbolInfo($e).Symbol
            if (Test-SourceType $sym.ContainingType) {
                if (@($e.ArgumentList.Arguments | Where-Object { $_.NameColon -or $_.RefKindKeyword.Text }).Count -or $e.ArgumentList.Arguments.Count -ne $sym.Parameters.Length) { Add-Diagnostic $e 'named, optional or by-reference arguments'; return '$null' }
                $parts = @()
                if (-not $sym.IsStatic) {
                    $receiver = if ($e.Expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax]) { Convert-Expression $e.Expression.Expression } else { '$self' }
                    $parts += "-self ($receiver)"
                }
                for ($i = 0; $i -lt $sym.Parameters.Length; $i++) { $parts += '-'+(Get-VariableName $sym.Parameters[$i])+' ('+(Convert-Expression $e.ArgumentList.Arguments[$i].Expression)+')' }
                return "($(Get-MethodFunction $sym) $($parts -join ' '))"
            }
            if ($e.Expression -is [Microsoft.CodeAnalysis.CSharp.Syntax.MemberAccessExpressionSyntax]) {
                if ($sym -and $sym.IsStatic) { return "[$(Get-PsTypeName $sym.ContainingType)]::$($sym.Name)($args_)" }
                return "$(Convert-Expression $e.Expression.Expression).$($e.Expression.Name.Identifier.Text)($args_)"
            }
            Add-Diagnostic $e "call to $($e.Expression) is not supported yet"; return "# cs2ps: unsupported call $e"
        }
        'MemberAccessExpressionSyntax' {
            $sym = $script:Model.GetSymbolInfo($e).Symbol
            if ($sym.Kind.ToString() -eq 'Field' -and (Test-SourceType $sym.ContainingType)) {
                if ($sym.IsStatic) { return "[$(Get-PsTypeName $sym.ContainingType)]::$((Get-FieldName $sym))" }
                return "(Get-CS2PSReceiver ($(Convert-Expression $e.Expression))).$(Get-FieldName $sym)"
            }
            if ($sym -and $sym.IsStatic) { return "[$(Get-PsTypeName $sym.ContainingType)]::$($sym.Name)" }
            return "$(Convert-Expression $e.Expression).$($e.Name.Identifier.Text)"
        }
        default { Add-Diagnostic $e "expression $($e.GetType().Name) is not supported yet"; return "<# cs2ps: unsupported $($e.GetType().Name) #>" }
    }
}

function Convert-Binary($e) {
    $l = Convert-Expression $e.Left; $r = Convert-Expression $e.Right
    $lt = Get-ExprType $e.Left; $rt = Get-ExprType $e.Right
    $op = $e.OperatorToken.Text
    $strings = (Test-String $lt) -or (Test-String $rt)
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
        default { Add-Diagnostic $e "operator $op is not supported yet"; return "<# cs2ps: operator $op #>" }
    }
}
