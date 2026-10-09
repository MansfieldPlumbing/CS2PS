$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'src/ConvertFrom-CSharp.ps1')
$cases = @(
    'public class C { public static void F() { lock (new object()) {} } }',
    'public class C { public static int F() { System.Func<int> f = () => 1; return f(); } }',
    'public class C { public static void F() { foreach (char c in "abc") {} } }',
    'public class C { public static int F() { int[,] a = new int[1,1]; return a[0,0]; } }',
    'public class C { public static void F() { try {} catch (System.Exception) when (true) {} } }',
    'public class C { public int P { get; set; } public static int F() => 1; }',
    'public class C { public readonly int X; public static int F() => 1; }',
    'public class C { static C() {} public static int F() => 1; }',
    'public enum E { A } public class C { public static int F() => 1; }',
    'public class C { public static int F(int x = 1) => x; }',
    'public class C { public static T F<T>(T x) => x; }',
    'public struct S { public int X; } public class C { public static void F() { S[] a = new S[1]; } }',
    'public struct S { public int X; } public class C { public static void F() { S? a = null; } }',
    'public class C { public static int F() => unknown; }',
    'public class C { public int X; public static int F(C[] a) { int i = 0; return a[i++].X++; } }'
)
foreach ($source in $cases) {
    $result = ConvertFrom-CSharp -Source $source
    if (-not $result.Diagnostics.Count -or @($result.Diagnostics | Where-Object { $_.Line -lt 1 }).Count) { throw 'Expected a line-numbered diagnostic' }
    if ($result.PowerShell -notmatch '# CS2PS: unsupported at line' -or $result.PowerShell -notmatch 'throw \[NotSupportedException\]') { throw 'Diagnostic output must be marked and fail closed' }
}
"diagnostic cases $($cases.Count), failures 0"
