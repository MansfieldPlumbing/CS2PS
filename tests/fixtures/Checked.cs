// Copyright (c) .NET Foundation and Contributors. MIT; see ROSLYN-LICENSE.txt.
// Extracted without semantic edits from https://github.com/dotnet/roslyn/blob/ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da/src/Compilers/CSharp/Test/Emit/CodeGen/CodeGenTests.cs#L13256
// Test: Bug17007. Upstream file SHA-256: 919176486C83FA111EED5E79165BB81AD29CDE9EFFEC1D636AB7C712FCBA4FDE

class Module1
{
    static void Main()
    {
	    System.Console.WriteLine(Test1(100));
    }

    static int Test1(int x)
    {
	    return Test2(x,checked(-x));
    }

    static int Test2(int x, int y)
    {   
	     return y;
    }
}
