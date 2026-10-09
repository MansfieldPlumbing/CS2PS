# CI and ecosystem contracts

## Hosted-only security boundary

All automatic push, pull-request and scheduled jobs must use GitHub-hosted runners.
Manual workflow_dispatch jobs must also remain hosted: manual dispatch is not local
hardware authorization. The personal workstation and Android devices must never
become runners or be connected to remotely triggered public workflows.
Do not install/register runner services, use self-hosted labels or private runner
groups targeting local machines, open inbound ports, or create tunnels to local
Windows, phone, ADB or FastRPC endpoints. Preserve read-only verification tokens,
immutable dependencies and narrow sanitized artifacts. Device credentials and
signing secrets must not enter ordinary PR workflows. Preserve working hosted CI.

Workflow definitions were audited on 2026-10-09 at CS2PS
`f596ecc7d4ef232f0d0fb08642a361bb5720a9c1` and the other immutable revisions below:
five workflows across CS2PS, PSLowering, QuickPS and JS2PS all target hosted Windows
and declare contents: read. None specifies self-hosted runners, private runner
groups, tunnels or local device commands. Pwsh and Kokoro-Hexagon have no committed
workflows at their inspected revisions. This source audit does not certify future
workflow changes or arbitrary third-party code. QuickPS and both JS2PS workflows
still reference checkout@v7 rather than a full SHA; immutable action pinning remains
a recorded gap in those repositories, whose files were not changed here.
The repositories' Actions runner-registration APIs also reported zero self-hosted
runners for each of the six repositories at audit time. Organization-wide runner
registrations and local service inventories were not inspected.

Hardware checks unavailable on hosted infrastructure are **NOT RUN** in CI.
Run them only in a separately authorized local PowerShell session, never from a
public PR, scheduled job or remote dispatch. For example, after locally staging
Pwsh's lowering probe with tools/Build-LoweringProbe.ps1 and installing a reviewed
debuggable Pwsh app, run this from the Pwsh checkout, substituting the explicitly
approved device model:

```powershell
pwsh -NoProfile -File ./tools/Invoke-DeviceScript.ps1 `
    -Path ./build/probes/lowering -Device '<approved device model>' -AliveSeconds 20
```

This command is provided for local execution only and was **NOT RUN** here.
It verifies the staged managed probe; it does not verify Hexagon DSP behavior.
Physical DSP tests remain separate locally authorized consumer gates.

## CS2PS authority and evidence

`docs/OUTPUT-CONTRACT.md` defines the output boundary. CI uses the existing
`tests/Test-IdiomaticOutput.ps1 -Mode CI`, not a second testing framework.
The workflow acquires pinned public sources into ignored build/cache, with no
private checkout dependencies or verification credentials beyond read access.
PSLowering is unchanged at `1afabe056235a570da29e268824784557d4f6cdd`;
its Git archive SHA-256 is
`816E789E4326B6506644A87D1EDF5D75EA4ED29893BAC2422A964F0D0E418C97`.
The bootstrap script, PowerShell archive, independent .NET runtime archive and
ILVerify package each have committed content digests checked before execution.

Cheap committed-source parsing and fixture integrity run before API inventory
and compiler/runtime tests. The ordinary workflow never runs Golden mode.
Tracked source/test changes during execution fail the final checkout check.
Review of intentional expectation changes remains necessary: a workflow stored
in the candidate repository cannot make malicious changes to itself impossible.

| Gate | Owner | Exercised scope |
| --- | --- | --- |
| Roslyn original vs SMA | Test-Parity.ps1; CallMatrix/AndroidBindings/SourceClosure modes | 341 distinct vectors per culture, en-US/fr-FR; values/types, ordinal strings, array shape, exceptions and console effects |
| Exact expected PS1 | CallMatrix | Four goldens; no automatic updates |
| Fail-closed translation | Test-Diagnostics.ps1 | 18 diagnostic cases |
| Runtime binding observations | Test-Parity.ps1 -TraceBinding | Signatures observed for exercised methods; trace lacks declaring type/site identity, so not a universal overload proof |
| Actual lowering consumer | OutputContract | CS2PS-generated ProgressLayout and JNI naming slice; admitted methods only; two exports; CoreLib-only references; source/oracle/vector identities in receipts |
| Dotnet-only semantic execution | ILVerify mode; reference/ConsumerOracle.cs | All 34 admitted vectors per culture; original C# compiled only as comparison executable; checks no SMA assembly is loaded |
| Structural IL verification | ILVerify mode | dotnet-ilverify 10.0.12, SHA-256 pinned; explicit System.Private.CoreLib reference from exact target runtime; two emitted assemblies |
| Behavioral negative controls | ILVerify mode | Generated Clamp replaced with constant zero; original C# and vectors unchanged; four differences across two cultures; independent dotnet process also rejects it |
| Structural negative control | ILVerify mode | Damaged assembly must be rejected after positive assembly checks pass |

The ILVerify tool targets net10.0 and is explicitly hosted by the exact downloaded
.NET 11 runtime. This does not require the runner's preinstalled runtime to match.
Structural verification is independent of PSLowering; it does not prove semantics.
The comparison executable is test-only C#, not a translator implementation or
production runtime wrapper. Targeted lowered assemblies retain CoreLib-only references.

Receipts retain runtime/compiler identities, source/vector digests, admission
reasons, assembly hashes/references and observed outcomes. Workflow artifacts
contain selected generated outputs and receipts, not source caches or credentials.
Missing artifacts are not evidence of PASS. Full 1.5x size acceptance and universal
lowering admission remain unmet; CI conformance does not waive those requirements.

The larger JNI closure currently discovers three methods and two type-initialization
boundaries; `Closed=false`. Its 12 method-body comparisons per culture do not
translate Java.Interop initialization, generated Xamarin partial types, JNI ownership
or platform runtime dependencies. Only ToPascalCase from that larger slice admits;
the other methods retain explicit lowering gaps. Audio/lifecycle/TTS declarations
remain inventories, not translated executable bindings.

## Inspected ecosystem

These are immutable source inspections, not claims that other repositories' jobs
were run here. Existing CI entries below describe committed workflow coverage.
All cross-repository execution outside CS2PS is **NOT RUN** in this campaign.

| Repository / inspected revision | Existing gates and committed CI | Hosted runner opportunity / owner | Emulator or hardware boundary / missing coverage | Contract |
| --- | --- | --- | --- | --- |
| [PSLowering](https://github.com/MansfieldPlumbing/PSLowering/tree/1afabe056235a570da29e268824784557d4f6cdd) | verify.yml bootstraps pinned PowerShell/.NET and runs tests/Test-ConsolidatedRunner.ps1 | Compiler admission, deterministic persistence and tests/Test-DotnetHost.ps1 run on Windows | No Android/DSP execution implied | Common typed PS1-to-IL compiler; source semantics and diagnostics belong here |
| [QuickPS](https://github.com/MansfieldPlumbing/QuickPS/tree/f1b1c9083d448c3ee893f878122de758849d4022) | verify.yml runs tests/Verify.ps1, Geometry3D.Verify.ps1 and Camera3D.Verify.ps1 | tools/Build-Appliance.ps1 owns explicit source composition; tests/Managed.Verify.ps1 -Composition checks deterministic CoreLib-only IL | Managed composition is not invoked by inspected workflow; interactive native UI/audio fidelity requires suitable Windows session/devices, not an Android emulator | Reviewed generated classes enter an explicit source set; native ABI, callback ownership and packaging stay with QuickPS |
| [Pwsh](https://github.com/MansfieldPlumbing/Pwsh/tree/3110a85a63a48b2dc1500364cb508d06f3ea3f91) | No committed Actions workflow found in complete inspected tree; setup.ps1 owns staged build/manufacturing | setup.ps1 -ValidateManifest, tools/Test-Parsers.ps1 and Test-UpstreamPins.ps1 are host candidates; tools/Build-LoweringProbe.ps1 stages compiler/oracle fixtures | x64 Android emulator can test host/startup and managed probes; arm64 device validates real deployment. Emulator/device gates not configured or run here | Lowered reviewed logic integrates with general PowerShell host/APK; do not remove general host capabilities to shrink an appliance |
| [JS2PS](https://github.com/MansfieldPlumbing/JS2PS/tree/919efd2a174218c522d1d2470117ae86f0142d72) | verify.yml runs tests/Verify.ps1; provenance.yml runs Verify-FixtureProvenance.ps1 weekly/manually | Existing semantic admission/fixture suite is host work; retain original JS oracle and source integrity | A passing JS admission gate does not prove native UI/browser-service equivalence or downstream IL; broader TS/browser contracts need explicit cases | Typed PS1 output shares compiler boundary while JS/TS semantics remain JS2PS-owned |
| [Kokoro-Hexagon](https://github.com/MansfieldPlumbing/Kokoro-Hexagon/tree/a12f7c92376799995f98e922fa930548742e01cf) | No committed Actions workflow found in complete inspected tree | tools/Test-DspQueueLayout.ps1 is host-only; Test-HexagonEmission.ps1 compares emitted bytes with an independent assembler, requiring pinned tool acquisition | Invoke-DeviceJob.ps1 and connected neural/DSP tests need physical supported Snapdragon/Hexagon. Android emulator cannot validate CDSP/HVX/HMX, admission, coherency or device audio | Native DSP emission and physical receipts remain separate from managed lowering; Build-KokoroApk.ps1 consumes a hash-identified base APK |

The inspected consumers use different PSLowering pins: QuickPS
`26fe7a864b19e70cfd6937ab062335a05fac3232`, Pwsh's lowering probe
`25427b25d9a7f4fd16568d74568cf6d2641b13e0`. CS2PS admission at its own pin does
not certify either consumer pin. Pin changes require the affected consumer gates.

## Integration and check placement

Recommend making **CS2PS Conformance / conformance** a required PR check after
its hosted run is green. Keep fixture integrity, goldens, diagnostics, two-culture
parity, targeted lowering, dotnet-only execution, ILVerify and negative controls
together as the minimum contract. Branch protection itself is not configured here.

For reviewed handoff, retain original repository/revision/member/source hash,
CS2PS revision, generated source digest and boundary/admission receipts. Consumers
select those immutable PS1 files explicitly. Reuse QuickPS composition rather
than implementing a CS2PS composer. CS2PS remains a development tool, not a build
dependency. Unclosed source dependencies must be resolved or explicitly excluded
from a narrowly defined method-body contract before claiming integration.

Recommend required host checks in each owning repository for its existing
deterministic/admission tests. Add managed composition to QuickPS only through
its own change. Use scheduled/manual runs for pinned upstream provenance refresh,
multi-repository pin compatibility and Android emulator startup/managed probes.
Physical DSP/native audio receipts belong in locally authorized device runs with explicit
hardware identity retained privately. Do not place device credentials or signing
keys in ordinary PR jobs. Use native reusable workflows only when duplication
actually warrants it; no central orchestration service is needed.

Not implemented here: consumer-repository workflow changes, Android emulator
tests, physical device tests, blanket overload proofs, release attestations,
cross-repository required checks, or complete size/lowering acceptance.
