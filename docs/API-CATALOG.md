# API discovery and call guidance

The catalog makes the target toolchain discoverable before deeper instrumentation.
It inventories public and protected managed declarations in the supplied assembly
roots, recursively walks namespaces and nested types, and records assembly-reference
edges and type forwarders. The default root is the running PowerShell's `$PSHOME`:
the .NET runtime libraries, SMA, Roslyn, Newtonsoft.Json and other shipped managed
libraries. Additional assembly directories or files can be supplied explicitly.

This is a comprehensive inventory of that defined input set, not every package on
NuGet. CoreCLR native exports and implementation internals are outside the managed
API inventory. Missing dependencies and different referenced identities remain
visible; discovery neither downloads packages nor silently establishes compatibility.

## Invocation

Use the recorded target executable, currently `C:/bin/pwsh/pwsh.exe`:

```powershell
./tests/Test-IdiomaticOutput.ps1 -Mode ApiCatalog
# Revalidate an existing generation without rebuilding its inventory:
$receipt = Get-Content ./build/api-catalog/current.json -Raw | ConvertFrom-Json
./tests/Test-IdiomaticOutput.ps1 -Mode ApiCatalog -ApiCatalogPath $receipt.ManifestPath
./tests/Test-IdiomaticOutput.ps1 -Mode ApiQuery -ApiAssembly Newtonsoft.Json `
    -ApiPattern '*Newtonsoft.Json.JsonConvert*'

. ./src/ConvertFrom-CSharp.ps1
$receipt = Get-Content ./build/api-catalog/current.json -Raw | ConvertFrom-Json
$result = ConvertFrom-CSharp -Path ./tests/fixtures/ProgressLayout.cs `
    -ApiCatalogPath $receipt.ManifestPath
$result.ApiCalls

$catalog = Import-CS2PSApiCatalog -Path $receipt.ManifestPath
$identity = ($catalog.Manifest.Assemblies | Where-Object Name -EQ 'Newtonsoft.Json').Identity
Get-CS2PSApiDependencyClosure -Catalog $catalog -AssemblyIdentity $identity
```

All generated inventories and receipts stay under `build/api-catalog/`. Each
generation is retained separately. The manifest records assembly identities and
SHA-256 digests, the executing runtime identities, counts and integrity hashes for
the per-assembly dictionaries. Exact lookups use the assembly identity together
with Roslyn's documentation declaration ID, preserving overloads and generic arity.
Lookup reads only the required assembly dictionary for an exact qualified query.
Metadata declarations that share a documentation ID remain separate variants;
translation rejects an ambiguous exact lookup rather than discarding an entry.
The target Roslyn declaration IDs include return-type suffixes; obtain IDs from
the catalog or selected symbol rather than assuming an older XML ID convention.

Dependency closure follows exact references and unique installed candidates,
retaining missing references and identity differences on every edge. `-ExactOnly`
limits traversal to exact identities. This is an assembly discovery graph, not
proof of binary compatibility or a method-level source extraction closure.
For source that calls an additional library, supply its assembly explicitly with
`ConvertFrom-CSharp -ReferencePath <dll>`. These are Roslyn metadata references;
the translator does not execute or compile the library. The parity harness accepts
the same reference paths for the original comparison assembly.

The inventory includes constructors, methods, accessors, operators, fields,
properties, events, parameter names/types/ref kinds/defaults, generic constraints,
inheritance, interfaces and declared attributes. Attributes expose available
platform, obsolete, trimming and dynamic-code annotations; absence of an attribute
does not establish portability or freedom from side effects. Type and assembly
attributes must also be considered when examining a member.

## Translation boundary

Catalog-assisted conversion checks supported external invocation sites against the
exact selected declaration. It reports the source line, signature identity, direct
or reflection form and conservative call-policy reasons in `ApiCalls`. It does not
add runtime dependencies to generated PowerShell. Ordinary conversion also uses
the same call-policy function, and does not require a generated catalog.

A call-policy `Candidate=true` is not a universal binder proof. The current conservative
policy still requires a runtime-resolvable exact signature at the call site and
retains explicit handling for object/string/null, params, ref/out, generic and
ref-like cases. Existing dedicated emission rules remain in control. Catalog
membership does not expand the supported C# subset.

Behavioral contracts are marked `Unreviewed` and lowering support `Unknown` unless
separately established. A signature does not tell us every exception, mutation,
native dependency or callback behavior. Differential parity and pinned PSLowering
admission remain independent gates. The catalog spike checks that catalog-assisted
translation produces exactly the same output and diagnostics for every fixture.
It also compares a catalog-selected Json.NET serialization call against compiled
C# for five integer boundary inputs in both en-US and fr-FR. This verifies that
specific overload on the target runtime, not all Json.NET semantics.
The four checked-in style goldens are compared exactly in this mode as well.

## Authoritative discovery routes

- [.NET API Catalog](https://apisof.net/) and its
  [Microsoft-maintained implementation](https://github.com/dotnet/apisof.net):
  framework/package availability, obsolescence and operating-system information.
- [.NET API reference sources](https://github.com/dotnet/dotnet-api-docs): API
  documentation; match the relevant version before adopting behavioral claims.
- [.NET 11 release metadata](https://github.com/dotnet/core/blob/main/release-notes/11.0/releases.json):
  release discovery, not a substitute for the installed artifact identity.
- [Newtonsoft reference](https://www.newtonsoft.com/json/help/html/Introduction.htm)
  and [source](https://github.com/JamesNK/Newtonsoft.Json): Json.NET's own contract.
- [Roslyn declaration identifiers](https://learn.microsoft.com/en-us/dotnet/api/microsoft.codeanalysis.documentationcommentid):
  exact declaration addressing.
- [Pinned SMA binder](https://github.com/PowerShell/PowerShell/blob/149ab5cd6cad34869177f86ef9a3da8414f85dc6/src/System.Management.Automation/engine/CoreAdapter.cs):
  overload-selection implementation for the recorded SMA source revision.

These are discovery pointers, not vendored version-matched semantic evidence.
No remote executable or package is acquired by the inventory operation. Future
contract entries should cite a pinned source or version-matched specification and
the parity cases that justify using the rule. Add rules for actual consumer calls
or useful API families instead of manually cataloguing unrelated library behavior.
