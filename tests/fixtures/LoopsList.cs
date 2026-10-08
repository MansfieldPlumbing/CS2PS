// Copyright (c) .NET Foundation and Contributors. MIT; see ROSLYN-LICENSE.txt.
// Extracted without semantic edits from https://github.com/dotnet/roslyn/blob/ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da/src/Compilers/CSharp/Test/Emit/CodeGen/ForeachTest.cs#L170
// Test: TestRemoveValueInForeach. Upstream file SHA-256: EED7A5336863EB0F5F5836677EF4C0563D3BCB5C451B7F70BACFC3C2CFA570F7
using System.Collections;
using System.Collections.Generic;

class C
{
    static public void Main()
    {
        List<int> arrInt = new List<int>();
        arrInt.Add(1);
        foreach (int i in arrInt)
        {
            arrInt.Remove(i);//It will generate error in run-time
        }
    }
}

