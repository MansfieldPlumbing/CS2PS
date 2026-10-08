# CS2PS repository contract

- Purpose: translate C# into typed, idiomatic PowerShell that keeps C#'s
  meaning. The output is reviewed PowerShell; it is an input to other
  repositories (and to PSLowering), never a build dependency.
- Implementation is PowerShell. Roslyn is loaded by path from the running
  PowerShell's `$PSHOME` to parse and analyze C#; Roslyn compilation is used
  only to produce the comparison assembly in tests. No other language
  implementation.
- Every supported construct carries parity cases: the translated PowerShell
  and the Roslyn-compiled original are called with the same inputs and must
  agree. A construct without parity cases is not supported.
- Unsupported input is reported as a diagnostic with its line and marked in
  the output. Never emit a guess.
- Generated files, reference assemblies and logs go to the ignored `build/`.
- Toolchain: PowerShell 7.7.0-preview.5 on .NET 11.0.0-rc.1.26425.128.
- No secrets, no AI attribution in commits or files.
