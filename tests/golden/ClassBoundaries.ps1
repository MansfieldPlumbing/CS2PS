class Counter {
    [int] $value
    [int] $Value_2
    [object] $label
    [int] Add([int] $amount) {
        $this.value = [int]::CreateTruncating[long](([long]($this.value) + [long]($amount))) <# C# unchecked int overflow must wrap; operands are not proven bounded. #>
        return [int]::CreateTruncating[long](([long]($this.value) + [long]($this.Value_2))) <# C# unchecked int overflow must wrap; operands are not proven bounded. #>
    }
    [int] Read() {
        return $this.value
    }
    [int] read_2() {
        return $this.Value_2
    }
    [int] Twice([int] $amount) {
        return [int]::CreateTruncating[long](([long]($this.Add($amount)) + [long]($this.Add($amount)))) <# C# unchecked int overflow must wrap; operands are not proven bounded. #>
    }
    Counter([int] $value) {
        $this.Value_2 = 3
        $this.value = $value
    }
}

class ClassBoundaries {
    static [int] Exercise([int] $n) {
        [Counter] $a = [Counter]::new($n)
        [Counter] $b = $a
        (Get-CS2PSReceiver ($b) <# C# null dereferences throw NullReferenceException. #>).value = 8
        return [int]::CreateTruncating[long](([long]([int]::CreateTruncating[long](([long]((Get-CS2PSReceiver ($a) <# C# null dereferences throw NullReferenceException. #>).Twice(2)) + [long]((Get-CS2PSReceiver ($b) <# C# null dereferences throw NullReferenceException. #>).Read()))) <# C# unchecked int overflow must wrap; operands are not proven bounded. #>) + [long]((Get-CS2PSReceiver ($b) <# C# null dereferences throw NullReferenceException. #>).read_2()))) <# C# unchecked int overflow must wrap; operands are not proven bounded. #>
    }
    static [bool] Identity() {
        [Counter] $a = [Counter]::new(1)
        [Counter] $b = [Counter]::new(1)
        [Counter] $c = $a
        return (-not ([object]::ReferenceEquals($a, $b))) -and ([object]::ReferenceEquals($a, $c))
    }
    static [object] Defaults() {
        [Counter] $c = [Counter]::new(0)
        return (Get-CS2PSReceiver ($c) <# C# null dereferences throw NullReferenceException. #>).label
    }
    static [int] NullField() {
        [Counter] $c = $null
        return (Get-CS2PSReceiver ($c) <# C# null dereferences throw NullReferenceException. #>).value
    }
    static [int] NullMethod() {
        [Counter] $c = $null
        return (Get-CS2PSReceiver ($c) <# C# null dereferences throw NullReferenceException. #>).Read()
    }
}









function Get-ClassBoundariesExercise { param([int] $n); return ,[ClassBoundaries]::Exercise($n) }

function Get-ClassBoundariesIdentity { param(); return ,[ClassBoundaries]::Identity() }

function Get-ClassBoundariesDefaults { param(); return ,[ClassBoundaries]::Defaults() }

function Get-ClassBoundariesNullField { param(); return ,[ClassBoundaries]::NullField() }

function Get-ClassBoundariesNullMethod { param(); return ,[ClassBoundaries]::NullMethod() }

# Semantic support used by this file.
function Get-CS2PSReceiver($value) {
    if ($null -eq $value) { throw [NullReferenceException]::new() }
    return ,$value
}
