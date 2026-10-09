class Module1 {
    static [void] Main() {
        [void]([System.Console]::WriteLine([int]([Module1]::Test1(100))))
    }
    static [int] Test1([int] $x) {
        return [Module1]::Test2($x, [int]::CreateChecked[long](([long](0) - [long]($x))) <# C# checked overflow must throw. #>)
    }
    static [int] Test2([int] $x, [int] $y) {
        return $y
    }
    Module1() {
    }
}

function Invoke-Module1Main { param(); return ,[Module1]::Main() }

function Get-Module1Test1 { param([int] $x); return ,[Module1]::Test1($x) }

function Get-Module1Test2 { param([int] $x, [int] $y); return ,[Module1]::Test2($x, $y) }
