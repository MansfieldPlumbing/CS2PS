// Copyright (c) .NET Foundation and Contributors. MIT; see ROSLYN-LICENSE.txt.
// Extracted without semantic edits from https://github.com/dotnet/roslyn/blob/ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da/src/Compilers/CSharp/Test/Emit/CodeGen/ForLoopsTests.cs#L23
// Test: ForLoop. Upstream file SHA-256: 13F2F0234532638CB84420FFAD157085DE7CED1C3E8BBD52C0A882B227A6DC21
class C
{
    static void Main()
    {
        int x = 3;
        for (int i = 0; i < 3; i = i + 1)
        {
            x = x * 3;
        }
        System.Console.Write("{0}", x);
    }
}
