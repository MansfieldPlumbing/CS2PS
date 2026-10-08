// Copyright (c) .NET Foundation and Contributors. MIT; see ROSLYN-LICENSE.txt.
// Extracted without semantic edits from https://github.com/dotnet/roslyn/blob/ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da/src/Compilers/CSharp/Test/Emit/CodeGen/SwitchTests.cs#L172
// Test: NonConstantSwitchArgumentExpression. Upstream file SHA-256: 8A2559010768D72741326AB4614A72FC6D01C52C1DBEF1652639B4FAE3D66229
using System;

public class Test
{
    public static int Main(string [] args)
    {
        int ret = 0;
        int value = 1;
        
        switch (value) {
        case 2:
            ret = 1;
            break;		
        }

        Console.Write(ret);
        return(ret);
    }
}
