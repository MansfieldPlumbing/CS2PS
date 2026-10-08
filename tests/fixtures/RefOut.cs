// Copyright (c) .NET Foundation and Contributors. MIT; see ROSLYN-LICENSE.txt.
// Extracted without semantic edits from https://github.com/dotnet/roslyn/blob/ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da/src/Compilers/CSharp/Test/Emit/CodeGen/CodeGenRefOutTests.cs#L54
// Test: TestOneReferenceMultipleParameters. Upstream file SHA-256: DC410F91CBE55543209F7BCB4853DEFD256E54D10E13FDBF29DD0969B14E2417

class C
{
    static void Main()
    {
        int z = 0;
        Test(ref z, out z);
        System.Console.WriteLine(z);
    }

    static void Test(ref int x, out int y)
    {
        x = 1;
        y = 2;
    }
}
