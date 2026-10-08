// Copyright (c) .NET Foundation and Contributors. MIT; see ROSLYN-LICENSE.txt.
// Extracted without semantic edits from https://github.com/dotnet/roslyn/blob/ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da/src/Compilers/CSharp/Test/Emit/CodeGen/CodeGenStructsAndEnum.cs#L597
// Test: UseStructLocal. Upstream file SHA-256: 42463425197C4677A62ACF33DB3F2374B9B429D456ED01D46B162AD1CC919BDB

using System;

struct GetProperty
{
    int i;
    GetProperty(int x)
    {
        i = x;
    }

    static void Main()
    {
        GetProperty t = new GetProperty(123);
        Console.Write(t.i);
    }
}

