# CS2PS

Translates C# into typed, idiomatic PowerShell, mechanically, keeping C#'s
meaning. It parses with Roslyn from the running PowerShell's own `$PSHOME`
and uses Roslyn's semantic model to make every meaning difference explicit:

| C# | PowerShell that would differ | What CS2PS emits |
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

CS2PS is a development tool. Its output enters other repositories only as
reviewed PowerShell that names its source and revision, and nothing in a
build depends on CS2PS or Roslyn.

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

With no arguments the harness checks every `.cs` fixture using its adjacent
`.cases.json`, comparing value types, ordinal strings, array shape, console
output and exception types. Generated scripts are parsed before loading.
`tests/Test-Diagnostics.ps1` checks marked, line-numbered, non-executable
output for unsupported input. Full Language Mode is required for Roslyn's
managed semantic API and the comparison assembly; no protection is disabled.

The loop fixtures are extracted from MIT-licensed `dotnet/roslyn` at commit
`ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da`; fixture headers cite exact source
locations, upstream file hashes and test names. `ROSLYN-LICENSE.txt` retains
the license. Supplemental fixtures cover boundary behavior.

| C# | PowerShell difference | Explicit translation |
|---|---|---|
| Distinct symbols, including `value`/`Value` | Names ignore case; automatic variables can collide | Syntax-position symbol names (`v123`) |
| Array/List indexing | Negative indices count backward; array misses return null | Bounds/null checks and the C# exception type |
| `foreach` over `List<T>` | Collection mutation may go undetected | Real .NET enumerator with disposal in `finally` |
| `return` of an array | The pipeline enumerates it | Unary comma preserves the array, including empty/singleton arrays |
| Expression statements | Method/assignment results can enter the pipeline | `[void]` suppresses incidental output |
| `switch` statements/expressions | PowerShell matching ignores case and enumerates inputs | Evaluate once, ordinal constant tests, first matching arm |
| `continue` inside a switch | PowerShell can continue the switch | Label the actual enclosing C# loop |
| Null strings | A typed PowerShell string becomes empty | Preserve null in object storage |
| Simple class fields and methods | Case-insensitive members and function dispatch differ | Symbol-named fields, constructor factories and explicit receiver functions |
| Class assignment | Objects must retain shared identity | Preserve the same object reference; null receivers throw |
| Simple struct assignment, parameters and returns | PowerShell classes have reference semantics | Explicit copies at value boundaries; nested value fields copy, reference fields remain shared |
| `out`/`ref` locals and parameters | Ordinary function arguments copy their values | `[ref]` cells and `.Value` accesses; aliases and forwarding retain the same storage |
| String interpolation and composite formatting | Expansion and formatting rules differ | .NET composite format strings, ordered values, alignment, format specifiers and current culture |
| Checked/unchecked integer arithmetic and narrowing | PowerShell widens arithmetic and rejects out-of-range casts | Exact wide intermediates, fixed-width wrapping or `OverflowException`, with lexical context |
| Shifts, bitwise operations and complement | Width, signedness and shift counts can differ | Typed results, count masks of 31/63, arithmetic/logical right shift |
| Boolean `&` / `\|` / `^` | `-and` / `-or` short-circuit | Evaluate both operands before combining |
| `char` arithmetic and comparison | PowerShell may treat characters as text | UTF-16 numeric promotion, ordinal comparison, checked overflow or 16-bit wrapping |
| Exceptions, typed catches, rethrow and `finally` | PowerShell wraps runtime exceptions | Unwrap invocation wrappers, dispatch catches in order, retain rethrow and finally control flow; null throws become `NullReferenceException` |

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
