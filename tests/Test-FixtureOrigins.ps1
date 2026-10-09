[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$dir = Join-Path $PSScriptRoot 'fixtures'
$records = @(Get-Content -Raw -LiteralPath (Join-Path $dir 'provenance.json') | ConvertFrom-Json)
$seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($record in $records) {
    if (-not $seen.Add($record.Fixture) -or $record.Fixture -cne [IO.Path]::GetFileName($record.Fixture)) { throw 'Invalid or duplicate fixture identity' }
    if ($record.Repository -cne 'https://github.com/dotnet/roslyn' -or $record.Commit -cne 'ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da' -or $record.SourceGitBlob -notmatch '^[0-9a-f]{40}$' -or $record.SourceSHA256 -notmatch '^[A-F0-9]{64}$') { throw 'Invalid immutable source identity' }
    $file = Join-Path $dir $record.Fixture
    if ((Get-FileHash -LiteralPath $file).Hash -cne $record.FixtureSHA256) { throw "Fixture integrity mismatch: $($record.Fixture)" }
}
foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.cs') {
    if (Select-String -LiteralPath $file.FullName -Pattern '^// Extracted without semantic edits' -Quiet) { if (-not $seen.Contains($file.Name)) { throw 'Unpinned upstream fixture' } }
}
if ((Get-FileHash -LiteralPath (Join-Path $dir 'ROSLYN-LICENSE.txt')).Hash -cne 'AE48DF11A335DC1A615F4F938B69CBA73BCF4485C4F97AF49B38EFB0F216353B') { throw 'License integrity mismatch' }
"origin fixtures $($records.Count), integrity failures 0"
