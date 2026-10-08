// Copyright (c) .NET Foundation and Contributors. MIT; see ROSLYN-LICENSE.txt.
// Extracted without semantic edits from https://github.com/dotnet/roslyn/blob/ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da/src/Compilers/CSharp/Test/Emit/CodeGen/CodeGenTryFinally.cs#L234
// Test: TryCatch. Upstream file SHA-256: 3ED12E5626219FD67ECF94AAFA47A6210FDDEDAA37ED37A87D35BCB102B1C856
using System;
class C
{
    static void Main()
    {
        M(1);
        M(0);
    }
    static void M(int f)
    {
        try
        {
            Console.Write("before, ");
            N(f);
            Console.Write("after, ");
        }
        catch (Exception)
        {
            Console.Write("catch, ");
        }
    }
    static void N(int f)
    {
        if (f > 0)
            throw new Exception();
    }
}
