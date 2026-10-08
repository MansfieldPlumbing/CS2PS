// Copyright (c) .NET Foundation and Contributors. MIT; see ROSLYN-LICENSE.txt.
// Extracted without semantic edits from https://github.com/dotnet/roslyn/blob/ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da/src/Compilers/CSharp/Test/Emit/CodeGen/CodeGenTests.cs#L3086
// Test: RefInstanceField. Upstream file SHA-256: 919176486C83FA111EED5E79165BB81AD29CDE9EFFEC1D636AB7C712FCBA4FDE

public class D
{
  
    public class Moo
    {
        public int I;

        public Moo()
        {
        }
    }

    public static void Main()
    {
        Moo obj = new Moo();

        System.Console.Write(obj.I);
        obj.I = 42;
        System.Console.Write(obj.I);
        obj.I = 7;
        System.Console.Write(obj.I);
    }
}

