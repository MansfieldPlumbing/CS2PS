// Copyright (c) .NET Foundation and Contributors. MIT; see ROSLYN-LICENSE.txt.
// Extracted without semantic edits from https://github.com/dotnet/roslyn/blob/ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da/src/Compilers/CSharp/Test/Emit/CodeGen/CodeGenOperators.cs#L2478
// Test: BuiltInRightShiftOperators. Upstream file SHA-256: 6420214278DC1C54D45D3A45E59478C1BAB767D98F015A6889273911E1FC922C

using System;

class Program
{
    static void Main(string[] args)
    {
        int i = int.MaxValue;
        uint ui = uint.MaxValue;
        long l = long.MaxValue;
        ulong ul = ulong.MaxValue;

        Console.WriteLine(i >> 31);
        Console.WriteLine(i >> 32);
        Console.WriteLine(i >> 33);
        Console.WriteLine(i >> -1);
        Console.WriteLine();

        Console.WriteLine(ui >> 31);
        Console.WriteLine(ui >> 32);
        Console.WriteLine(ui >> 33);
        Console.WriteLine(ui >> -1);
        Console.WriteLine();

        Console.WriteLine(l >> 63);
        Console.WriteLine(l >> 64);
        Console.WriteLine(l >> 65);
        Console.WriteLine(l >> -1);
        Console.WriteLine();

        Console.WriteLine(ul >> 63);
        Console.WriteLine(ul >> 64);
        Console.WriteLine(ul >> 65);
        Console.WriteLine(ul >> -1);
        Console.WriteLine();
    }
}
