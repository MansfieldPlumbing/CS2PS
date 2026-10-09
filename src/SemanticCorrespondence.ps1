# Call correspondence rules annotate Roslyn operations; they are not another IR.
function ConvertTo-CS2PSExpressionAst([string] $Text) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -or $ast.EndBlock.Statements.Count -ne 1 -or
        $ast.EndBlock.Statements[0] -isnot [System.Management.Automation.Language.PipelineAst] -or
        $ast.EndBlock.Statements[0].PipelineElements.Count -ne 1 -or
        $ast.EndBlock.Statements[0].PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
        throw "Expected one PowerShell expression: $Text"
    }
    $ast.EndBlock.Statements[0].PipelineElements[0].Expression.Copy()
}

function New-CS2PSInvocationAst([string] $Target, [string] $Name, [string[]] $Arguments, [bool] $Static) {
    $targetAst = ConvertTo-CS2PSExpressionAst $Target
    $extent = $targetAst.Extent
    $member = [System.Management.Automation.Language.StringConstantExpressionAst]::new(
        $extent, $Name, [System.Management.Automation.Language.StringConstantType]::BareWord)
    $argumentAsts = [System.Management.Automation.Language.ExpressionAst[]]@(
        foreach ($argument in $Arguments) { ConvertTo-CS2PSExpressionAst $argument })
    [System.Management.Automation.Language.InvokeMemberExpressionAst]::new($extent, $targetAst, $member, $argumentAsts, $Static)
}

function Write-CS2PSInvocationAst([System.Management.Automation.Language.InvokeMemberExpressionAst] $Ast) {
    # Children already have validated source extents; no source repair pass follows.
    $separator = if ($Ast.Static) { '::' } else { '.' }
    $Ast.Expression.Extent.Text + $separator + $Ast.Member.Value + '(' +
        (($Ast.Arguments | ForEach-Object { $_.Extent.Text }) -join ', ') + ')'
}

function Get-CS2PSInvocationCorrespondence($Method, $Expression, [string[]] $Values) {
    $reasons = [Collections.Generic.List[string]]::new()
    if ($Method.IsGenericMethod) { $reasons.Add('Generic invocation has no admitted binding rule.') }
    if ($Method.ReturnsByRef -or $Method.ReturnsByRefReadonly) { $reasons.Add('By-reference return needs an explicit representation.') }
    foreach ($parameter in $Method.Parameters) {
        if ($parameter.RefKind.ToString() -ne 'None') { $reasons.Add('Ref/out cells require copy-back and exception handling.') }
        if ($parameter.IsParams) { $reasons.Add('Expanded params require an array/span correspondence rule.') }
        if ($parameter.Type.IsRefLikeType -or $parameter.Type.TypeKind.ToString() -in 'Pointer','FunctionPointer') { $reasons.Add('Ref-like or pointer values cannot use this managed argument rule.') }
    }
    $runtimeType = (Get-PsTypeName $Method.ContainingType) -as [type]
    $parameterTypes = [type[]]@($Method.Parameters | ForEach-Object { (Get-PsTypeName $_.Type) -as [type] })
    $selected = $null
    $applicableArity = @()
    if ($runtimeType -and -not ($parameterTypes -contains $null) -and -not $reasons.Count) {
        $flags = if ($Method.IsStatic) { [Reflection.BindingFlags]'Public,Static' } else { [Reflection.BindingFlags]'Public,Instance' }
        $methods = @($runtimeType.GetMethods($flags) | Where-Object Name -IEQ $Method.Name)
        $applicableArity = @($methods | Where-Object {
            $parameters = $_.GetParameters()
            $hasParams = $parameters.Count -and @($parameters[-1].CustomAttributes | Where-Object {$_.AttributeType.FullName -in 'System.ParamArrayAttribute','System.Runtime.CompilerServices.ParamCollectionAttribute'}).Count
            $required = @($parameters | Where-Object {-not $_.IsOptional}).Count - [int][bool]$hasParams
            $required -le $Values.Count -and ($parameters.Count -ge $Values.Count -or $hasParams)
        })
        $matches = @($methods | Where-Object {
            if ($_.Name -ine $Method.Name -or $_.IsGenericMethod -or $_.GetParameters().Count -ne $parameterTypes.Count) { return $false }
            $parameters = $_.GetParameters()
            for ($i=0; $i -lt $parameters.Count; $i++) { if ($parameters[$i].ParameterType -ne $parameterTypes[$i]) { return $false } }
            return $true
        })
        if ($matches.Count -eq 1) { $selected = $matches[0] }
    }
    if (-not $selected -and -not $reasons.Count) { $reasons.Add('Selected CLR signature is not uniquely available in the running toolchain.') }
    $arguments = [Collections.Generic.List[string]]::new()
    $casts = 0
    if (-not $reasons.Count) {
        for ($i=0; $i -lt $Values.Count; $i++) {
            $source = if ($i -lt $Expression.ArgumentList.Arguments.Count) { $Expression.ArgumentList.Arguments[$i].Expression } else { $null }
            $parameter = $Method.Parameters[$i]
            if ($parameter.Type.SpecialType.ToString() -eq 'System_String' -and -not (Test-ProvenNonNull $source)) {
                $reasons.Add('A string cast would collapse observable null to empty; an untyped null cannot constrain this overload.')
                break
            }
            if ($source -is [Microsoft.CodeAnalysis.CSharp.Syntax.LiteralExpressionSyntax] -and
                (Get-ExprType $source).SpecialType -eq $parameter.Type.SpecialType) { $arguments.Add($Values[$i]) }
            elseif ($parameter.Type.SpecialType.ToString() -eq 'System_Object' -and $applicableArity.Count -and
                -not @($applicableArity | Where-Object {
                    $_.IsGenericMethod -or $_.GetParameters().Count -le $i -or $_.GetParameters()[$i].ParameterType -ne [object]
                }).Count) {
                # All applicable signatures agree here. Boxing/reference conversion
                # cannot change their ranking; non-expanded fixed arity wins ties.
                $arguments.Add($Values[$i])
            }
            else { $arguments.Add("[$(Get-PsTypeName $parameter.Type)]($($Values[$i]))"); $casts++ }
        }
    }
    $callAst = $null
    if (-not $reasons.Count) {
        $target = if ($Method.IsStatic) { "[$(Get-PsTypeName $Method.ContainingType)]" } else { Convert-Receiver $Expression.Expression.Expression }
        $callAst = New-CS2PSInvocationAst $target $Method.Name $arguments.ToArray() $Method.IsStatic
        # Ask the running SMA compiler which constraints it extracts, rather than
        # maintaining a second implementation of its cast-recognition algorithm.
        $compiler = [System.Management.Automation.PSObject].Assembly.GetType('System.Management.Automation.Language.Compiler')
        $constraintMethod = $compiler.GetMethod('GetTypeConstraintForMethodResolution', [Reflection.BindingFlags]'Static,NonPublic')
        if (-not $constraintMethod) { $reasons.Add('Running SMA does not expose the inspected invocation-constraint mechanism.') }
        else {
            for ($i=0; $i -lt $callAst.Arguments.Count; $i++) {
                if ($arguments[$i] -cne $Values[$i] -and $constraintMethod.Invoke($null,[object[]]@($callAst.Arguments[$i])) -ne $parameterTypes[$i]) {
                    $reasons.Add('SMA did not extract the selected parameter type from the argument cast.')
                }
            }
        }
    }
    $expectedTrace = $null
    if ($selected) {
        $adapter = [System.Management.Automation.PSObject].Assembly.GetType('System.Management.Automation.DotNetAdapter')
        $formatter = $adapter.GetMethod('GetMethodInfoOverloadDefinition',[Reflection.BindingFlags]'Static,NonPublic')
        if ($formatter) { $expectedTrace = $formatter.Invoke($null,[object[]]@($selected.Name,$selected.PSObject.BaseObject,0)) }
    }
    [pscustomobject]@{
        Outcome = if ($reasons.Count) { 'Exact fallback' } elseif ($casts) { 'Adapted' } else { 'Direct' }
        Rule = if ($reasons.Count) { 'ExactSignatureInvocation' } else { 'ExactTypedArguments' }
        Reasons = @($reasons); Ast = $callAst; Casts = $casts
        SelectedSignature = if ($selected) { $selected.ToString() } else { $Method.ToString() }
        Proof = 'Signature availability and SMA argument constraints; runtime overload selection is not universally proved.'
        ExpectedTrace = $expectedTrace
        Evidence = 'https://github.com/PowerShell/PowerShell/blob/149ab5cd6cad34869177f86ef9a3da8414f85dc6/src/System.Management.Automation/engine/parser/Compiler.cs#L1033'
    }
}
