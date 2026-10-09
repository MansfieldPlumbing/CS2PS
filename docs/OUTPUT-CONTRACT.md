# Typed output and extraction contract

CS2PS emits reviewed PowerShell source. Its contract is idiomatic source with
explicit semantic adjustments, not source shaped around one compiler revision.
The CLR catalog is an identity inventory; it is not an equivalence certificate.

## QuickPS comparison

Reference: MansfieldPlumbing/QuickPS commit
`f1b1c9083d448c3ee893f878122de758849d4022`, inspected through immutable Git objects.
The relevant files are `src/managed/AudioCapture.ps1`,
`src/managed/MediaSessionEvents.ps1`, `tools/Build-Appliance.ps1`,
`docs/PSLOWERING-REQUIREMENTS.md` and `tests/Managed.Verify.ps1`.
No QuickPS files were modified and no Windows runtime implementation was imported.

The useful source structure is typed classes, explicit state and ordinary CLR
calls. Native imports, callback ownership and platform lifetimes remain the
consumer's contracts. Native-capable QuickPS source does not by itself prove
Android execution or admission of another source program.

QuickPS already owns explicit source-set composition: selected files, duplicate
path/type rejection, AST validation, source hashes, source-position markers and
deterministic assembly emission. Do not duplicate that appliance composer in
CS2PS. A discovered C# closure should become an explicit selection of reviewed
PS1 units for the downstream build. Its current builder only accepts files in its
own repository and class declarations; it is not directly callable against this
checkout. Cross-project inputs still require the agreed immutable handoff.

`ConvertFrom-CSharp -ClassOnly` suppresses convenience forwarding functions.
It fails closed if a method requires function semantics or semantic helpers;
it never silently omits them. Class-only source is suitable for downstream
composition but still needs independent lowering admission. Default output keeps
the existing named command interface, including `Get-ProgressLayoutBarWidth`.

## Semantic evidence

- The converter checks support-source parsing, intermediate body parsing and the
  complete assembled PS1. Parse errors become line-numbered diagnostics and the
  returned program is a throwing stub. Generated positions are identified as such.
- String return types narrow to `[string]` only on supported successful-return
  proofs: non-null construction/concatenation, verified local storage and specified
  String operations. Nullable returns remain `[object]`.
- Local string storage analysis consults Roslyn data flow and rejects captured
  locals. The first-unconditional-Length guard optimization requires successful
  data-flow/control-flow analysis, no extra entry point, and no capture or write
  that can invalidate its fact. Its fact stays inside the current statement.
  These are bounded rules, not a general path-sensitive nullability analysis.
- A string compared only with a nonempty constant may use `[string]`: null and
  empty both compare unequal. Null-sensitive equality and null returns retain
  `[object]`. The two JNI dereferencing parameters also retain `[object]` because
  null must throw or return unchanged on the original path.
- Direct CLR `get_Chars` preserves C# negative/out-of-range string-index behavior.
  Ordinary PowerShell indexing has different behavior. The adjustment is commented
  at the site; array/List helper elimination needs its own bounds proof.
- Omitted external arguments are emitted from Roslyn's supported explicit constant
  defaults. No default value is invented. Unsupported defaults remain diagnostics.

Invocation correspondence records signature availability and SMA-recognized casts.
It does **not** claim universal overload-selection proof. `Test-Parity.ps1
-TraceBinding` captures the running SMA `MethodInvocation` trace and compares its
reported signatures with the Roslyn-selected CLR method's SMA-formatted definition.
The formatter and trace are traced to pinned SMA `CoreAdapter.cs:2148` and
`runtime/Binding/Binders.cs:6966` at
`149ab5cd6cad34869177f86ef9a3da8414f85dc6`.
Receipts identify observed and unobserved signatures for each source method.
Trace text omits the declaring type and source call position; these observations
are evidence for exercised inputs, not a universal or per-site binding proof.

## Separate executable gates

Run with PowerShell 7.7.0-preview.5 / .NET 11 RC1:

```powershell
./tests/Test-IdiomaticOutput.ps1 -Mode OutputContract
./tests/Test-IdiomaticOutput.ps1 -Mode CallMatrix
./tests/Test-IdiomaticOutput.ps1 -Mode AndroidBindings
./tests/Test-IdiomaticOutput.ps1 -Mode SourceClosure
```

OutputContract checks class-only SMA execution against the original comparison
assembly in en-US and fr-FR, admission by the unchanged PSLowering pin
`1afabe056235a570da29e268824784557d4f6cdd`, two deterministic exports to different
directories with the same assembly name, independent IL parity including exceptions
and null returns, and assembly references. The only allowed managed reference in
these targeted outputs is System.Private.CoreLib. QuickPS uses a different compiler
pin; its results do not implicitly update this one.

Measured targeted results are recorded in `build/output-contract/receipt.json`:

| Output | Semantic helper calls | Admitted methods | Independent IL cases/culture |
| --- | ---: | ---: | ---: |
| ProgressLayout | 0 | 4/7 | 9 |
| JavaNativeTypeManager naming helpers | 0 | 3/3 | 25 |

Both assembly exports are deterministic and reference only CoreLib. The rejected
ProgressLayout methods are BarWidth, SumTo and Midpoint: the pinned lowerer cannot
resolve their generic CreateTruncating/CreateSaturating calls. Preserve the exact
numeric contracts and report this as a compiler gap. Do not substitute rounding,
checked overflow or double division merely to improve admission.

Four exact goldens remain in `tests/golden/`. Golden mode is an explicit update
operation and backs up changed expectations under build; verification never
updates them. The original corpus still has broader size/admission failures;
the targeted improvements are not a claim that every original acceptance gate passes.

## Source-member closure

`Get-CS2PSSourceMemberClosure -Path <explicit C# files> -Member <method signature>`
builds a Roslyn model and traverses referenced source methods, fields, properties
and events, with a visited set for recursion. It records exact source positions,
hashes and retained CLR API/assembly identities. Supply ApiCatalogPath to classify
these against the existing inventory; it does not expand that catalog.

This is a method-body graph, not a whole-program linker. Unresolved selected
source, static initialization, implicit/source-generated members, constructor
initialization and source virtual dispatch are explicit boundaries. A boundary
keeps Closed false. External CLR terminals remain semantically unreviewed until
an emission rule establishes their contract. Unrelated unresolved source is not
silently turned into product stubs.

The pinned Android example follows ToCliType(string) to ToCliTypePart(string) and
ToPascalCase(string,int). SourceClosure writes the original three method bodies
into the same explicitly scoped comparison-host form as AndroidBindings, and
compares 12 cases per culture. It also tests cross-file recursive graph discovery
and omission of an unrelated member. Two original upstream static initializers
remain boundaries; this proves the extracted bodies, not original type startup.
Only ToPascalCase is currently admitted in the larger slice. Array/indexing and
retained call helpers in the other two methods remain explicit compiler/emitter
gaps, recorded with generated positions in `build/source-closure/receipt.json`.

All generated source, trace files, comparison assemblies and receipts stay under
build. No Android device execution is claimed by these host-side gates.
