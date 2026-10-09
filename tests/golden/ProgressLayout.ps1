class ProgressLayout {
    static [int] BarWidth([int] $percent, [int] $columns) {
        if (($percent -lt 0)) {
            $percent = 0
        }
        if (($percent -gt 100)) {
            $percent = 100
        }
        return [Math]::DivRem([int]([int]::CreateTruncating[long](([long]($columns) * [long]($percent))) <# C# unchecked int overflow must wrap; operands are not proven bounded. #>), [int](100)).Item1 <# C# integer division truncates and preserves division exceptions. #>
    }
    static [object] FormatLabel([string] $activity, [int] $percent) {
        [string] $text = [string]::Concat([string]::Concat([string]::Concat($activity, ': '), $percent), '%')
        if (($text.Length -gt 20)) {
            $text = [string]::Concat($text.Substring(0, 17), '...')
        }
        return $text
    }
    static [bool] IsSame([object] $a, [object] $b) {
        return ([object]::Equals($a, $b) <# String.Equals is ordinal; object arguments preserve null versus empty. #>)
    }
    static [int] SumTo([int] $n) {
        [int] $total = 0
        :loop for ([int] $i = 1; ($i -le $n); $i = [int]::CreateTruncating[long](([long]($i) + [long](1))) <# C# unchecked int overflow must wrap; operands are not proven bounded. #>) {
            $total = [int]::CreateTruncating[long](([long]($total) + [long]($i))) <# C# unchecked int overflow must wrap; operands are not proven bounded. #>
        }
        return $total
    }
    static [double] Ratio([int] $a, [int] $b) {
        return ([double]([double]$a) / [double]($b))
    }
    static [int] Midpoint([double] $a, [double] $b) {
        return [int]::CreateSaturating[double]((([double]((([double]($a) + [double]($b)))) / [double](2)))) <# C# floating conversion truncates and saturates on this runtime. #>
    }
    static [int] Clamp([int] $value, [int] $low, [int] $high) {
        return $(if (($value -lt $low)) { $low } else { ($(if (($value -gt $high)) { $high } else { $value })) })
    }
}

function Get-ProgressLayoutBarWidth { param([int] $percent, [int] $columns); return ,[ProgressLayout]::BarWidth($percent, $columns) }

function Format-ProgressLayoutFormatLabel { param([string] $activity, [int] $percent); return ,[ProgressLayout]::FormatLabel($activity, $percent) }

function Test-ProgressLayoutIsSame { param([object] $a, [object] $b); return ,[ProgressLayout]::IsSame($a, $b) }

function Get-ProgressLayoutSumTo { param([int] $n); return ,[ProgressLayout]::SumTo($n) }

function Get-ProgressLayoutRatio { param([int] $a, [int] $b); return ,[ProgressLayout]::Ratio($a, $b) }

function Get-ProgressLayoutMidpoint { param([double] $a, [double] $b); return ,[ProgressLayout]::Midpoint($a, $b) }

function Get-ProgressLayoutClamp { param([int] $value, [int] $low, [int] $high); return ,[ProgressLayout]::Clamp($value, $low, $high) }
