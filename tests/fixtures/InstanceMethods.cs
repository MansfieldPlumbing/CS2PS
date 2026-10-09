// Copyright (c) .NET Foundation and Contributors. MIT; see ROSLYN-LICENSE.txt.
// Extracted without semantic edits from https://github.com/dotnet/roslyn/blob/ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da/src/Compilers/CSharp/Test/Emit/CodeGen/CodeGenTests.cs#L7046
// Test: Temporaries. Upstream file SHA-256: 919176486C83FA111EED5E79165BB81AD29CDE9EFFEC1D636AB7C712FCBA4FDE

using System;
class Program
{
    static void Main()
    {
        bool x = true;
        int y = (x != true).GetType().GetHashCode() - x.GetType().GetHashCode(); // Temps involved
        Console.Write((y + y).ToString()); // Temp involved
    }
    public void test()
    {
        this.bar(1).ToString(); // Temp involved
    }
    public int bar(int x)
    {
        return 0;
    }
}
