class FormatBoundaries {
    static [object] Show([object] $text, [double] $value) {
        return [string]::Format('{{{0}}} [{1,10:N2}] {2:F1}', [object[]]@(($text), ($value), ($value)))
    }
    static [object] Composite([double] $value) {
        return (Invoke-CS2PSRuntime ([string]) ($null) 'Format' ([type[]]@([string], [object])) ([object[]]@(('{0:N2}/{0,8:F1}'), ($value))) $true) <# Reflection preserves the selected object/null, ref or expanded params signature. #>
    }
    static [object] Escape([object] $text) {
        return [string]::Format('it''s {{literal}}: {0}', [object[]]@(($text)))
    }
    static [object] Order() {
        [int] $i = 0
        return [string]::Format('{0},{1},{2}', [object[]]@(($($previousValue = $i; $i = [int]::CreateTruncating[long](([long]($previousValue) + [long](1))) <# C# unchecked int overflow must wrap; operands are not proven bounded. #>; $previousValue)), ($($previousValue_2 = $i; $i = [int]::CreateTruncating[long](([long]($previousValue_2) + [long](1))) <# C# unchecked int overflow must wrap; operands are not proven bounded. #>; $previousValue_2)), ($i)))
    }
    static [object] Empty() {
        return [string]::Format('', [object[]]@())
    }
}

function Get-FormatBoundariesShow { param([object] $text, [double] $value); return ,[FormatBoundaries]::Show($text, $value) }

function Get-FormatBoundariesComposite { param([double] $value); return ,[FormatBoundaries]::Composite($value) }

function Get-FormatBoundariesEscape { param([object] $text); return ,[FormatBoundaries]::Escape($text) }

function Get-FormatBoundariesOrder { param(); return ,[FormatBoundaries]::Order() }

function Get-FormatBoundariesEmpty { param(); return ,[FormatBoundaries]::Empty() }

# Semantic support used by this file.
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
