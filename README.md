# CS2PS

Translates C# into typed, idiomatic PowerShell, mechanically, keeping C#'s
meaning. It parses with Roslyn from the running PowerShell's own `$PSHOME`
and uses Roslyn's semantic model to make every meaning difference explicit:

| C# | PowerShell that would differ | What CS2PS emits |
|---|---|---|
| `a / b` on integers truncates | `$a / $b` returns a double | Typed inline `[Math]::DivRem(...).Item1` for signed int/long |
| `(int)x` on a double truncates | `[int]$x` rounds half to even | Explicit checked conversion or .NET 9+ saturating truncation |
| String equality is ordinal | Even case-sensitive cultural comparisons differ | Null-aware `[string]::Equals(..., Ordinal)` |
| `"s" + n` concatenates | `+` may add numerically | `[string]::Concat(...)` |

Classes retain source names, fields and constructors. Eligible static and instance
methods become typed class methods; static entrypoints also have approved-verb
function forwarders (`FormatLabel` becomes `Format-<Class>FormatLabel`, `IsSame`
becomes `Test-<Class>IsSame`). Ref/out and source value semantics can require
explicit function fallbacks. Anything outside
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
$r.Methods         # source methods, generated function names and parameter names
```

## Verification

For toolchain-wide API discovery, run `tests/Test-IdiomaticOutput.ps1 -Mode ApiCatalog`.
Query the generated dictionary with `-Mode ApiQuery -ApiPattern '*Newtonsoft.Json*'`.
The optional `ConvertFrom-CSharp -ApiCatalogPath <manifest>` checks external call
sites against exact assembly-qualified declarations and exposes `ApiCalls` evidence.
See [API-CATALOG.md](docs/API-CATALOG.md) for scope, invocations and primary sources.
Generated catalogs remain in ignored `build/`; catalog membership does not imply
semantic parity, platform portability or PSLowering admission.

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

The upstream fixtures are extracted from MIT-licensed `dotnet/roslyn` at commit
`ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da`; fixture headers cite exact source
locations, upstream file hashes and test names. `ROSLYN-LICENSE.txt` retains
the license. `provenance.json` records immutable Git blob identities and
SHA-256 digests, verified against exact upstream literals. The harness checks
these fixture hashes before compiling or loading code. Supplemental fixtures
cover boundary behavior.

| C# | PowerShell difference | Explicit translation |
|---|---|---|
| Distinct symbols, including `value`/`Value` | Names ignore case; automatic variables can collide | Preserve names; readable suffixes only for collisions (`value_2`) |
| Array/List indexing | Negative indices count backward; array misses return null | Bounds/null checks and the C# exception type |
| `foreach` over `List<T>` | Collection mutation may go undetected | Real .NET enumerator with disposal in `finally` |
| `return` of an array | The pipeline enumerates it | Unary comma preserves the array, including empty/singleton arrays |
| Expression statements | Method/assignment results can enter the pipeline | `[void]` suppresses incidental output |
| `switch` statements/expressions | PowerShell matching ignores case and enumerates inputs | Evaluate once, ordinal constant tests, first matching arm |
| `continue` inside a switch | PowerShell can continue the switch | Label the actual enclosing C# loop |
| Null strings | A typed PowerShell string becomes empty | Object storage where null identity is observable; string storage where proven safe |
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
| Nullable value types | Null coercion, members and lifted operators differ | Null-or-boxed-value storage, explicit `HasValue`/`Value`, lifted arithmetic/comparison and nullable boolean truth tables |
| `??` / `??=` | Repeated evaluation changes side effects | Evaluate the left side once and the fallback only when null |
| Floating arithmetic | Division by zero and NaN comparisons differ | IEEE zero division and comparisons, with typed rounding at each operation |
| Runtime overload resolution | PowerShell uses runtime argument types | Invoke the exact signature selected by Roslyn, including single `out`/`ref` arguments |
| Reference equality | PowerShell may compare values or enumerate arrays | `[object]::ReferenceEquals` for class, array and object comparisons |

## Supported now

Fixture-backed support includes `for`/`while` and array/List `foreach`;
constant-case switch statements and constant/discard switch expressions;
simple class fields, constructors and instance methods; simple struct value
copies; local/parameter `out` and `ref`; interpolation and composite formatting;
checked/unchecked integer arithmetic and numeric casts; bit operations and
shifts; UTF-16 character arithmetic; throw/catch/rethrow/finally; and nullable
primitive values, lifted operators and coalescing. Fields, functions and
variables are named from their symbols so case-only distinctions survive.
Primitive numeric types, bool, string, object, arrays and `List<T>` are typed
according to Roslyn. String and nullable storage preserves null explicitly.

## Boundaries

Unsupported input produces line-numbered diagnostics and marked output that
throws before any translated code runs. This includes properties, inheritance,
interfaces, enums, records, generic source types/methods, attributes, iterators,
LINQ, exception filters, readonly/volatile/const fields, static field
initializers, constructor chaining, source-struct arrays and nullable source
structs. Source calls require explicit positional arguments; runtime generic,
named, optional and multiple-by-reference calls are diagnostics. Expanded
`string.Format` params spans use the equivalent `object[]` overload.
Compound assignments and increments with effectful lvalues are diagnostics.

The verified toolchain is PowerShell `7.7.0-preview.5` on .NET
`11.0.0-rc.1.26425.128`, Windows x64. Numeric behavior follows this runtime,
including floating-to-integer saturation and minimum-integer remainder
overflow. Full Language Mode and path-based assembly loading are required;
the translator never compiles C# to implement a translation. Only the test
harness builds a comparison assembly, and all generated scripts, assemblies
and logs remain in ignored `build/`.

Semantic references: the C# specification's
[statements](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/language-specification/statements),
[expressions](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/language-specification/expressions),
[structs](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/language-specification/structs)
and [types](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/language-specification/types);
the .NET documentation for
[floating-to-integer saturation](https://learn.microsoft.com/en-us/dotnet/core/compatibility/jit/9.0/fp-to-integer)
and [integer remainder](https://learn.microsoft.com/en-us/dotnet/api/system.reflection.emit.opcodes.rem).
