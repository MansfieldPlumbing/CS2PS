# CS2PS repository contract

- Read the shared mission at C:/Dev/Pwsh-Development/docs/mission/MISSION.md and relevant capability
  entries at C:/Dev/Pwsh-Development/docs/mission/CAPABILITY-MAP.md. CS2PS's immediate consumer purpose
  includes reusing C# Android binding/control logic in Pwsh. This context does
  not broaden the current task or authorize changes to other repositories.

- Purpose: translate C# into typed, idiomatic PowerShell that keeps C#'s
  meaning. The output is reviewed PowerShell; it is an input to other
  repositories (and to PSLowering), never a build dependency.
- Implementation is PowerShell. Roslyn is loaded by path from the running
  PowerShell's `$PSHOME` to parse and analyze C#; Roslyn compilation is used
  only to produce the comparison assembly in tests. No other language
  implementation.
- API discovery starts at docs/API-CATALOG.md. The existing acceptance instrument's
  ApiCatalog and ApiQuery modes inventory the target toolchain and explicit extra
  assembly roots. Use exact assembly/declaration identities; inventory membership
  is not proof of behavior, runtime binding, portability or lowering admission.
  Resolve documented questions before adding execution tracing.
- Call emission rules and their compiler-source evidence live in
  docs/CALL-CORRESPONDENCE.md. Use the existing CallMatrix acceptance mode;
  catalog membership alone must not select an emission form.
- Typed output, QuickPS source-set handoff, separate executable gates and source-member
  extraction boundaries live in docs/OUTPUT-CONTRACT.md. Use OutputContract and
  SourceClosure in the existing acceptance instrument. Runtime trace observations
  and parity are evidence for exercised inputs, not universal binding proofs.
- Android audio/JNI/lifecycle/TTS extraction starts at docs/ANDROID-BINDINGS.md
  and the existing AndroidBindings mode. Declaration counts are not executable
  bindings; keep source closure, parity, lowering and device receipts separate.
- Every supported construct carries parity cases: the translated PowerShell
  and the Roslyn-compiled original are called with the same inputs and must
  agree. A construct without parity cases is not supported.
- Unsupported input is reported as a diagnostic with its line and marked in
  the output. Never emit a guess.
- Generated files, reference assemblies and logs go to the ignored `build/`.
- Toolchain: PowerShell 7.7.0-preview.5 on .NET 11.0.0-rc.1.26425.128.
- No secrets, no AI attribution in commits or files.

<!-- shared-pwsh-mission:start -->
<!-- Current campaign: CS2PS reuses required Android/.NET C# logic for finishing
Kokoro-Hexagon and shipping Pwsh on Android. Complete the authorized idiomatic-output
acceptance; use pinned real consumers to identify integration gaps without replacing
the scope, weakening parity or changing PSLowering. -->
## PowerShell workshop and shared mission

C:/Dev/Pwsh-Development is our shared private GitHub-backed workshop for PowerShell
campaigns. Start at docs/WORKSHOP.md there; read docs/mission/MISSION.md and relevant
entries in CAPABILITY-MAP.md and RESEARCH-MAP.md. TELOS.md records the broader purpose.
These named guidance files are shared reading entrypoints. Guidance and coordination
may use current local documents; product inputs still require the project's pinned
source and integrity rules. This distinction does not authorize unrelated builds,
checkout changes or product edits.

Preserve portable programmable computing and application manufacturing, including
Android scripting/server capabilities and Windows native delivery. A console is a
frontend; a compact appliance is an output configuration. Judge techniques by source,
contracts and execution evidence. Current implementation limits are not universal
technical limits.

Orient before investigating: find capabilities, authoritative homes, invocation
routes and evidence through maintained discovery entries. Prefer our PowerShell
tools and harnesses when they fit; close recurring gaps within the task and retain
independent verification. Surface stale guidance, contradictory contracts, misplaced
artifacts and missing discovery routes; correct them within scope or record a precise
handoff. Preserve improvements beyond the session. Broad environment cleanup remains
Scott's work.

Look outward before looking deeper. Find published implementations, specifications,
manuals and prior receipts before instrumentation or reverse engineering. Distinguish
an incomplete search from undocumented behavior. Investigate the residual consumer
question and retain the answer. Use neutral team language. The workshop supports the
current project's deliverable; it does not replace it.
<!-- shared-pwsh-mission:end -->
