// Copyright (c) .NET Foundation and Contributors. MIT; see ROSLYN-LICENSE.txt.
// Extracted without semantic edits from https://github.com/dotnet/roslyn/blob/ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da/src/Compilers/CSharp/Test/Emit/CodeGen/CodeGenInterpolatedString.cs#L20
// Test: AlternateVerbatimString. Upstream file SHA-256: 08074A6CF51996BBDDA898F67907873E7A8E466BE7BE81390BBE1EE31DF62784

class C
{
    static void Main()
    {
        int i = 42;
        var s = @$"{i}
{i}";
        System.Console.Write(s);
        var s2 = $@"";
    }
}
