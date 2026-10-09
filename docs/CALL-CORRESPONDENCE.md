# Compiler-informed call correspondence

The API catalog answers which CLR declaration exists. Roslyn resolves the source
invocation. A compact annotation on that invocation chooses a verified PowerShell
form; it does not introduce another intermediate language or replace either binder.

| Outcome | Rule in this spike | Emission |
| --- | --- | --- |
| Direct | Exact literals, no arguments, or an object argument that cannot distinguish applicable signatures | Ordinary static or instance call |
| Adapted | Explicit parameter casts recognized by the running SMA compiler; conversion preserves the value | Ordinary call with those casts |
| Exact fallback | Nullable string conversion, ref/out copy-back, params/span representation, or unresolved signature | Exact reflection helper with a local reason |
| Unsupported | Existing translator diagnostics reject the construct | Diagnostic and marked output; no guessed call |

These classifications describe emission decisions, not a complete behavioral
specification for the API. The bounded report covers 75 supported external
invocation sites in the 30 fixtures. The historical 78-record counter included
three duplicate visits: two nested GetType invocations and one ToString argument
in InstanceMethods.cs. Removing unused argument conversion and deferring fallback
receiver conversion fixes the counter. Source spans independently validate coverage
against Roslyn invocation nodes, including distinct calls on the same line.
An unsupported construct rejected
before invocation mapping is outside that denominator. Constructors, properties,
operators, source-defined calls and dedicated nullable operations are outside this
spike's matrix. Receiver null checks and pipeline/result handling remain separate
translator responsibilities; a direct call can still need a receiver guard.

## Binding authority

The inspected SMA revision is `149ab5cd6cad34869177f86ef9a3da8414f85dc6`.
[Compiler.GetTypeConstraintForMethodResolution](https://github.com/PowerShell/PowerShell/blob/149ab5cd6cad34869177f86ef9a3da8414f85dc6/src/System.Management.Automation/engine/parser/Compiler.cs#L1033)
extracts an explicit argument cast's type.
[GetInvokeMemberConstraints](https://github.com/PowerShell/PowerShell/blob/149ab5cd6cad34869177f86ef9a3da8414f85dc6/src/System.Management.Automation/engine/parser/Compiler.cs#L5790)
passes these constraints to invocation binding.
[Adapter.FindBestCandidate](https://github.com/PowerShell/PowerShell/blob/149ab5cd6cad34869177f86ef9a3da8414f85dc6/src/System.Management.Automation/engine/CoreAdapter.cs#L984)
prefers candidates satisfying them; its parameter constraint check uses exact type
equality. This requires an applicable selected candidate, not merely a cast somewhere
in the expression. Exact literals have the selected parameter's runtime type.

The emitter verifies a unique public reflected signature, constructs an actual SMA
`InvokeMemberExpressionAst` from parsed expression children, and asks the running
compiler's constraint extractor to verify inserted casts. A narrow serializer writes
that invocation; it does not repair source afterward. The complete generated file
is independently parsed in acceptance. The internal SMA method is version-sensitive:
if unavailable, emission retains the exact fallback. Runtime/catalog identities are
recorded in the receipt and catalog import rejects a mismatched runtime.

When all arity-applicable signatures agree on an object parameter, that argument
needs no cast: its boxing/reference conversion cannot distinguish the candidates.
The selected non-generic, non-params signature has exact arity; the binder prefers
fixed non-expanded candidates and then fewer parameters on ties. Json.NET also has
params converter overloads, but their first parameter is the same object type.
Competing signatures include generic, optional and params candidates in this check;
generic candidates prevent this cast omission.
Otherwise, `[object]($value)` preserves null and constrains an object overload even when the
boxed value is a string or number. `[string]($value)` changes null to empty, so the
direct rule requires a non-null source proof for string arguments. The current
analysis is deliberately conservative: a fallback is a remaining proof gap, not
an assertion that PowerShell can never express the call directly. Expanded .NET 11
params spans still use the existing exact formatting adaptation; this spike does
not claim that the original span signature and object-array signature are identical.

## Reproduce

Run the existing acceptance instrument with the recorded PowerShell executable:

```powershell
C:/bin/pwsh/pwsh.exe -NoProfile -File ./tests/Test-IdiomaticOutput.ps1 -Mode CallMatrix
```

First generate an API catalog with `-Mode ApiCatalog` if none exists. CallMatrix
reconstructs its baseline from local commit
`4d8433c6725b1499ff5a2d604eee9fc4fc31a96d` when absent. Existing baselines are never
overwritten. Generated sources, snapshots and the complete receipt stay in
`build/call-matrix/`. It checks stable site identities, all 30 generated files with
SMA, four exact goldens, 264 original cases plus five Json.NET cases and sixteen
binding regressions in each culture, and the existing diagnostic suite. It verifies
the pinned PSLowering SHA and digests before reporting admission/rejection reasons.
Admission is independent of source parity; rejected methods are reported honestly.

The Json.NET call is an additional site reported separately from the 75 source sites.
Its output is `[Newtonsoft.Json.JsonConvert]::SerializeObject($value)`.
The supplemental binding cases use the same Roslyn comparison harness rather than
a second oracle. Result types, exception types, console output and evaluation order
remain part of that comparison.

This bounded spike does not complete the original per-fixture size or lowering
acceptance. Use the broader Verify mode for those outstanding gates; CallMatrix
does not weaken them or modify PSLowering.

## Measured result on the recorded toolchain

The 2026-10-09 run preserves 269 existing comparisons and adds 16 binding
regressions: 285 calls, zero differences, independently in en-US and fr-FR.
All 15 diagnostic cases and 17 upstream fixture integrity checks pass. All 30
outputs parse through SMA and all four goldens compare exactly.

| Call classification | Source sites |
| --- | ---: |
| Direct without added casts | 22 |
| Adapted direct call | 48 |
| Exact reflection fallback | 5 |
| Unsupported within this supported-site denominator | 0 |

The source-site baseline is 61 ordinary calls and 14 reflection calls. Reflection
falls to five; nine sites become ordinary calls. The separate Json.NET site is
direct without a cast. FormatBoundaries loses its reflection helper completely.
ProgressLayout retains zero helpers.

Pinned PSLowering admits 33 methods and rejects 122. Of the rejected entries,
33 require function semantics outside its class-method admission interface.
The other 89 are class-method rejections with exact reasons in the receipt;
examples include unsupported generic numeric conversion calls and command ASTs.
These are outstanding admission gaps, not parity failures.

Remaining reflection sites:

| Fixture and C# line | Reason retained |
| --- | --- |
| InstanceMethods.cs:12 | String argument not proved non-null; a cast changes null to empty |
| LoopsArray.cs:17 | Array element string not proved non-null |
| RefBoundaries.cs:7 | Ref/out cell copy-back and exception handling |
| RefBoundaries.cs:8 | Ref/out cell copy-back and exception handling |
| SemanticBoundaries.cs:10 | Expanded params span still uses the existing object-array formatting adaptation |
