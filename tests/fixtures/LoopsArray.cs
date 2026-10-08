// Copyright (c) .NET Foundation and Contributors. MIT; see ROSLYN-LICENSE.txt.
// Extracted without semantic edits from https://github.com/dotnet/roslyn/blob/ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da/src/Compilers/CSharp/Test/Emit/CodeGen/ForeachTest.cs#L26
// Test: SimpleLoop. Upstream file SHA-256: EED7A5336863EB0F5F5836677EF4C0563D3BCB5C451B7F70BACFC3C2CFA570F7

using System;
public class Test
{
    static void Main(string[] args)
    {
        string[] arr = new string[4]; // Initialize
        arr[0] = "one";               // Element 1
        arr[1] = "two";               // Element 2
        arr[2] = "three";             // Element 3
        arr[3] = "four";              // Element 4
        foreach (string s in arr)
        {
            System.Console.WriteLine(s);
        }
    }
}

