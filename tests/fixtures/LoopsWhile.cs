// Copyright (c) .NET Foundation and Contributors. MIT; see ROSLYN-LICENSE.txt.
// Extracted without semantic edits from https://github.com/dotnet/roslyn/blob/ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da/src/Compilers/CSharp/Test/Emit/CodeGen/CodeGenTests.cs#L5461
// Test: BranchesAndReturn. Upstream file SHA-256: 919176486C83FA111EED5E79165BB81AD29CDE9EFFEC1D636AB7C712FCBA4FDE

public class D
{
    static int R;

    static void M(bool getLocal, int arg)
    {
        int y = 123;

        if (getLocal)
        {
            while (getLocal)
            {
                if (!getLocal)
                {
                    R = y;
                }
                else
                {
                    R = y;
                    return;
                }
            }
            return;
        }
        else
        {
            R = arg;
            return;
        }
    }

    public static void Main()
    {
        M(false, 42);
        System.Console.Write(D.R);
        M(true, 42);
        System.Console.Write(D.R);
    }
}

