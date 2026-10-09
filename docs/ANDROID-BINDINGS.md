# Android binding batch

Immediate targets are audio, JNI, application lifecycle and TTS for the Pwsh/Kokoro
delivery. This batch distinguishes declaration discovery, C# binding, translation,
managed parity, lowering admission and Android execution. None implies the next.

Run the existing instrument with the recorded toolchain:

```powershell
C:/bin/pwsh/pwsh.exe -NoProfile -File ./tests/Test-IdiomaticOutput.ps1 -Mode AndroidBindings
```

Source is dotnet/android commit `37f8b4a65cf7eb1fca9808ea7b724e5db1e7dba5`,
acquired with Git archive from the shared vendor mirror into this repository's
`build/cache/android-bindings/`. The cached archive, individual files and upstream
licenses have SHA-256 integrity records. The mirror's checkout is never changed.

## Outputs

| Artifact under build/android-bindings | Purpose |
| --- | --- |
| api-36-bindings.json | Exact API-36 Java/JNI declarations, overload descriptors, static/instance flags, parameters and field values |
| source-inventory.json | Hand-written C# member locations and per-file translation attempts, compiler messages and subset diagnostics |
| attempts/ | Marked, fail-closed translation results for each source file; not runnable bindings |
| JavaNativeTypeManager.cs and .ps1 | Three extracted upstream naming methods and their generated PowerShell |
| JavaNativeTypeManager.cases.json | Independent comparison inputs for those original method bodies |
| receipt.json | Counts, parity and lowering results with scope and runtime identity |
| JavaNativeTypeManager.lowered.dll | Admitted naming-policy method emitted as an independent managed assembly and compared to the original |

The API XML is a generator input, not generated C# implementation. TTS resides
there even though this source revision has no hand-written TextToSpeech.cs.
Inheritance and callback interfaces must be followed when selecting a consumer's
dependency closure; this inventory covers declarations on the selected types and
does not pretend to include every inherited operation or runtime dependency.

Query an overload without searching folders:

```powershell
$api = Get-Content ./build/android-bindings/api-36-bindings.json -Raw | ConvertFrom-Json
$api.Members | Where-Object { $_.Type -eq 'android.media.AudioTrack' -and $_.Name -eq 'write' }
$api.Members | Where-Object { $_.Type -eq 'android.speech.tts.TextToSpeech' -and $_.Name -eq 'speak' }
```

No JNI ownership, callback lifetime or exception contract is inferred from a
descriptor. A declaration is marked DeclarationOnly until implementation and
execution evidence establish those contracts.

## First measured batch

| Family | Selected types | Declarations |
| --- | ---: | ---: |
| Audio | 7 | 685 |
| Application lifecycle and dispatch | 7 | 420 |
| TTS client, engine/service and callbacks | 7 | 124 |

The 1,229 declarations contain 829 methods, 23 constructors and 377 fields.
The selected C# source files contain 340 method/constructor declarations under
the explicitly recorded NET/JAVA_INTEROP/API-36 inventory profile.

All 33 source files were attempted independently. Twenty-nine have C# binding
errors, three have subset diagnostics, and one has no executable methods under
this profile. These are file-level observations, not 340 unsupported methods.
The source-set/generated-code/reference-assembly closure remains to be supplied.
Additional managed reference directories or files can be passed using
`-ReferencePath`; their paths and digests are recorded in source-inventory.json.
Compiler configuration also matters: unsafe code, generated LibraryImport
implementations and build symbols cannot be treated as ordinary missing methods.

The three extracted naming methods preserve their upstream declarations and
bodies in a minimal comparison host, without Android stubs or rewritten logic:

- ToJniName(string, int): object/primitive/array JNI name construction.
- ToPascalCase(string, int): managed naming normalization.
- IsPackageNamePreservedForAssembly(string): Mono.Android package-name policy.

They pass 25 cases in each of en-US and fr-FR, including null, empty strings,
primitive and array descriptors, negative ranks, casing and Unicode. This proves
the extracted logic on the host, not the complete upstream class or assembly.
The namespace wrapper is normalized for the comparison host; method bodies remain
unchanged. No C# is compiled for product implementation.

Pinned PSLowering admits IsPackageNamePreservedForAssembly and rejects the other
two because generated null/bounds guards are PowerShell command calls. Those
rejections remain recorded; PSLowering is unchanged. No device execution occurred.
The admitted method is also exported and invoked against the original comparison
assembly, rather than stopping at admission. Its result and dependency receipt
remain separate from SMA parity.
The measured output is 2,048 bytes with System.Private.CoreLib as its only assembly
reference, and five lowered comparisons per culture with zero differences. This is
one naming-policy method, not the footprint of an Android runtime or application.

## Consumer order and remaining boundaries

The first delivery-shaped binding queue is:

1. JNI thread environment, class/method ID lookup, Java exceptions and reference
   ownership. These underpin every following group.
2. AudioTrack setup, buffer sizing, PCM writes, play/pause/stop and release;
   AudioRecord initialization/read/stop/release where input is needed.
3. Activity/Application lifecycle and Handler/Looper dispatch, with thread and
   callback lifetime ownership.
4. TextToSpeech initialization, speak/stop/shutdown and utterance callbacks;
   independently, TextToSpeechService/SynthesisRequest/SynthesisCallback for an
   Android TTS engine. Client and service integration are different contracts.

Local read-only discovery found the existing JNI dispatcher documented in
`C:/Dev/pwsh/docs/android-facade.md` and exposed by AndroidCanvas.psm1's
Get-JavaClass/Get-JavaMethod/Invoke-JavaCall functions. That is an integration
discovery pointer, not an immutable product input or authorization to modify Pwsh.
Reuse its verified contract rather than transplanting the Mono.Android runtime.

For C# extraction, the next closure work is generated binding source and matching
Java.Interop/Android metadata, followed by selected source-member dependencies.
Supplying a reference assembly alone does not merge a compiled type with a source
partial class. Do not replace missing dependencies with arbitrary stubs, strip
interop attributes, or erase lifetime/exception behavior just to get a successful
translation count.

The batch exposed two translator robustness gaps now covered: explicit
preprocessor symbols are shared by translation and the comparison assembly;
Roslyn-proven nameof constants emit literals. Unsupported declarations stop
before deeper emission, and unresolved dynamic invocations get a diagnostic
instead of an internal crash. The existing parity corpus remains a separate gate.
The diagnostic suite retains its original 15 cases and adds a dynamic-invocation
case. The conditional-profile fixture also compares a nameof result.

Run `-Mode CallMatrix` alongside this mode to preserve the existing gate. That
suite has 285 comparisons per culture; this batch adds 25 upstream helper cases
and two conditional/nameof cases, giving 312 SMA comparisons per culture in total,
plus the five independent lowered comparisons. The existing four exact goldens
and 17 upstream fixture integrity checks still pass.
