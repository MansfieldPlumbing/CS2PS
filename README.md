# CS2PS

CS2PS translates a tested subset of C# into typed PowerShell. It uses Roslyn's
semantic model to resolve types, members, conversions and overflow contexts,
then emits PowerShell and validates the assembled source with SMA's parser.
The implementation is PowerShell; it does not compile C# as a translation shortcut.
Tests compile the original C# only to obtain an independent comparison assembly.

The intended output is readable, reviewable `.ps1`, suitable for reuse without
shipping CS2PS or Roslyn. Eligible class methods can also be passed to
[PSLowering](https://github.com/MansfieldPlumbing/PSLowering) for managed IL emission.
This is an experimental translator, not a general C# compiler or a complete
Android binding generator. Tested-input parity is not a proof for all inputs.

## Requirements and use

Verified on Windows x64 with PowerShell **7.7.0-preview.5** and its bundled
.NET **11.0.0-rc.1.26425.128**. Use Full Language Mode. Roslyn assemblies are
loaded by path from that PowerShell installation's `$PSHOME`. Older PowerShell
versions, Linux and macOS are not currently conformance targets.

```powershell
. ./src/ConvertFrom-CSharp.ps1
$result = ConvertFrom-CSharp -Path ./tests/fixtures/ProgressLayout.cs
$result.Diagnostics
$result.PowerShell
# Save reviewed generated output under build/; inspect diagnostics before use.
New-Item -ItemType Directory -Force ./build | Out-Null
$result.PowerShell | Set-Content ./build/ProgressLayout.ps1
```

The result includes `PowerShell`, `Diagnostics`, `Methods`, `Types`, `Renames`
and `ApiCalls`. `-ReferencePath` supplies explicit CLR reference assemblies;
`-Define` supplies conditional-compilation symbols. `-ClassOnly` omits command
forwarders and rejects translations requiring function/helper semantics.
Default output includes commands such as `Get-ProgressLayoutBarWidth -percent 57
-columns 80`. [Four checked-in goldens](tests/golden/) show actual output.

## Semantic choices

Source names survive unless PowerShell's case-insensitive names or automatic
variables cause a collision; collision records explain readable suffixes.
Typed classes, fields, constructors and eligible methods retain source structure.
Direct CLR calls and plain operators are preferred where the semantic rules allow
it. Exceptional sites carry short comments, rather than hiding differences.

| C# contract | Emission when ordinary PowerShell differs |
| --- | --- |
| Integer division truncates | Typed inline `Math.DivRem(...).Item1` |
| Unchecked fixed-width overflow wraps | Inline typed wrapping or an exact helper where required |
| String concatenation | `String.Concat` |
| Ordinal string equality | Explicit ordinal/null-preserving comparison |
| Observable null versus empty string | Object storage only at affected variables/parameters |
| Array/List bounds and negative indices | Explicit guards or semantic helpers |
| Array return shape | Unary comma to prevent pipeline enumeration |
| Ref/out and struct value semantics | Explicit reference cells or copies |

The tested subset includes loops, switches, primitive/nullable operations,
arrays and `List<T>`, interpolation, checked/unchecked arithmetic, bit operations,
exceptions and simple classes/structs. This is a fixture-defined subset, not
support for every combination of those constructs. Unsupported input yields
line-numbered diagnostics and marked output that throws before translated code
runs. Properties, inheritance, generic source types/methods, iterators and LINQ,
among other constructs, remain outside the supported translation subset.

## Validation

Run the core comparison and diagnostic tests from a fresh checkout using the
pinned PowerShell above; no local workshop or Android cache is needed:

```powershell
./tests/Test-Parity.ps1 -Culture en-US
./tests/Test-Parity.ps1 -Culture fr-FR
./tests/Test-Diagnostics.ps1
```

The [CS2PS Conformance workflow](.github/workflows/verify.yml) uses a clean
`windows-2025` runner, SHA-pinned actions, unchanged pinned PSLowering, and pinned
public Android source. It reuses PSLowering's hash-verified PowerShell downloader
and runs the existing acceptance instrument's `CI` mode. No third-party
PowerShell action, Pester migration, private checkout or repository secret is
required. Generated source, assemblies and receipts are retained as run artifacts.

Its gates are distinct: original C# versus SMA execution, exact golden comparisons,
SMA parsing, call correspondence observations, PSLowering admission reporting,
execution of independently emitted IL, deterministic export and assembly-reference
inspection. Rejected lowerings are recorded with reasons; they are not silently
counted as compiled methods. Hash-pinned ILVerify 10.0.12 checks emitted assemblies
against the pinned runtime's CoreLib. Structural validity does not establish
semantic equivalence. A separate Roslyn comparison executable runs all 34 targeted
vectors per culture under the exact .NET 11 host and asserts that SMA is absent.
Deliberately corrupted generated code must disagree with the original frozen
vectors; ILVerify must reject a damaged assembly. CodeQL and release attestations
are not configured; universal overload-selection proof is not established.

At implementation commit `68e41fa`, local measurements on the pinned runtime were:

| Check | Result |
| --- | --- |
| Original fixture corpus | 30 fixtures; 264 comparisons per culture; 0 differences |
| Including Json.NET, call regressions and Android slices | 341 distinct comparisons per culture; 0 differences |
| Cultures | en-US and fr-FR |
| Unsupported-input cases | 18 passing diagnostic cases |
| Exact goldens / upstream fixture integrity | 4 matching / 17 verified |
| ProgressLayout | 50 executable PS lines / 46 nonblank C# lines (1.09x); 0 semantic helpers |
| Targeted independent IL execution | 34 comparisons per culture; 0 differences; deterministic; CoreLib-only references |
| Targeted lowering admission | ProgressLayout 4/7; JNI naming helpers 3/3 |
| Broader lowering report | 34 admitted, 121 rejected |

Hosted results must be read from the workflow run; the local numbers above do
not imply a hosted run has passed. No performance improvement is claimed here.

## Current gaps

The original **1.5x per-fixture size acceptance remains unmet** on multiple
fixtures. Exact arithmetic and some switch/value semantics still produce verbose
output. Helpers are emitted only when used, but many fixtures still need them.
The pinned lowerer cannot resolve generic `CreateTruncating`/`CreateSaturating`
calls in three ProgressLayout methods. Exact semantics are retained rather than
changing arithmetic to obtain admission. See [output contract](docs/OUTPUT-CONTRACT.md).

`Get-CS2PSSourceMemberClosure -Path <explicit files> -Member <signature>` discovers
transitive source-member references, retained CLR calls and explicit boundaries.
It is a method-body graph, not a whole-program linker: static initialization,
virtual dispatch, implicit members and constructor initialization can prevent
closure. Android audio/lifecycle/TTS inventories are declarations, not runnable
bindings. The verified JNI naming slices are host-side managed logic; they do
not establish Android device execution or JNI lifetime correctness.

The standalone acceptance modes include `ApiCatalog`, `CallMatrix`,
`AndroidBindings`, `OutputContract`, `SourceClosure`, `Baseline` and `Measure`.
Some require prior modes and pinned caches; use the workflow as the reproducible
acquisition/order reference. `Golden` deliberately updates expectations and is
not a verification command. `Measure`/`Verify` retain the stricter size gate and
can fail on the documented outstanding size issues.

Further detail: [CI and ecosystem contracts](docs/CI-INTEGRATION.md), [API inventory](docs/API-CATALOG.md),
[call correspondence](docs/CALL-CORRESPONDENCE.md),
[Android extraction](docs/ANDROID-BINDINGS.md).
Generated files, caches, reference assemblies and logs stay in ignored `build/`.
Upstream Roslyn fixtures retain their [license](tests/fixtures/ROSLYN-LICENSE.txt)
and [provenance](tests/fixtures/provenance.json). No license for CS2PS's original
code has been selected; public visibility alone does not grant an open-source license.
