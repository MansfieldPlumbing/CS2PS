# cs2ps

Translates C# into typed, idiomatic PowerShell, mechanically, keeping C#'s
meaning. It parses with Roslyn from the running PowerShell's own `$PSHOME`
and uses Roslyn's semantic model to make every meaning difference explicit:

| C# | PowerShell that would differ | What cs2ps emits |
|---|---|---|
| `a / b` on integers truncates | `$a / $b` returns a double | `[Math]::DivRem($a, $b).Item1` |
| `(int)x` on a double truncates | `[int]$x` rounds half to even | `[int][Math]::Truncate($x)` |
| `a == b` on strings is case-sensitive | `-eq` ignores case | `-ceq` (and `-cne`, `-clt`, ...) |
| `"s" + n` concatenates | `+` may add numerically | `[string]::Concat(...)` |

Static methods become advanced functions with typed parameters and
`[OutputType]`; method names map to approved verbs (`FormatLabel` becomes
`Format-<Class>Label`, `IsSame` becomes `Test-<Class>Same`). Anything outside
the supported subset is reported as a diagnostic with its line and marked in
the output; nothing is guessed.

cs2ps is a development tool. Its output enters other repositories only as
reviewed PowerShell that names its source and revision, and nothing in a
build depends on cs2ps or Roslyn.

## Use

```powershell
. ./src/ConvertFrom-CSharp.ps1
$r = ConvertFrom-CSharp -Path ./Some.cs
$r.PowerShell      # the generated functions
$r.Diagnostics     # unsupported constructs, with line numbers
```

## Verification

`tests/Test-Parity.ps1` translates a fixture, compiles the same C# with Roslyn
into the ignored `build/` folder as a comparison only, calls both with the
same inputs and reports every difference. The first fixture
(`tests/fixtures/ProgressLayout.cs`): 23 calls, 0 differences.

## Supported now

Static methods; parameters and locals of simple types; `if`/`else`, `for`,
`foreach`, `while`, `break`, `continue`, `return`; assignment, compound
assignment, `++`/`--`; arithmetic, comparison, logical, bitwise and
conditional expressions; casts; calls to static .NET members and to instance
members of values.

## Next

Instance classes as PowerShell classes or records plus functions; properties
and fields; `switch`; `try`/`catch`/`finally`; arrays and collections;
`out`/`ref`; nested types (flattened); iterators (lists); LINQ (loops);
string interpolation; checked and unchecked integer overflow. First real
input: PowerShell's ConsoleHost progress layout (`PendingProgress.cs`,
`ProgressNode.cs`).
