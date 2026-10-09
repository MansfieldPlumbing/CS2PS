class FormatBoundaries {
    static [string] Show([object] $text <# Preserve C# null versus empty. #>, [double] $value) {
        return [string]::Format('{{{0}}} [{1,10:N2}] {2:F1}', [object[]]@(($text), ($value), ($value)))
    }
    static [string] Composite([double] $value) {
        return [string]::Format('{0:N2}/{0,8:F1}', [object]($value))
    }
    static [string] Escape([object] $text <# Preserve C# null versus empty. #>) {
        return [string]::Format('it''s {{literal}}: {0}', [object[]]@(($text)))
    }
    static [string] Order() {
        [int] $i = 0
        return [string]::Format('{0},{1},{2}', [object[]]@(($($previousValue = $i; $i = [int]::CreateTruncating[long](([long]($previousValue) + [long](1))) <# C# unchecked int overflow must wrap; operands are not proven bounded. #>; $previousValue)), ($($previousValue_2 = $i; $i = [int]::CreateTruncating[long](([long]($previousValue_2) + [long](1))) <# C# unchecked int overflow must wrap; operands are not proven bounded. #>; $previousValue_2)), ($i)))
    }
    static [string] Empty() {
        return [string]::Format('', [object[]]@())
    }
}

function Get-FormatBoundariesShow { param([object] $text, [double] $value); return ,[FormatBoundaries]::Show($text, $value) }

function Get-FormatBoundariesComposite { param([double] $value); return ,[FormatBoundaries]::Composite($value) }

function Get-FormatBoundariesEscape { param([object] $text); return ,[FormatBoundaries]::Escape($text) }

function Get-FormatBoundariesOrder { param(); return ,[FormatBoundaries]::Order() }

function Get-FormatBoundariesEmpty { param(); return ,[FormatBoundaries]::Empty() }
