// Copyright (c) .NET Foundation and Contributors. MIT; see ROSLYN-LICENSE.txt.
// Extracted without semantic edits from https://github.com/dotnet/roslyn/blob/ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da/src/Compilers/CSharp/Test/Emit/CodeGen/CodeGenTests.cs#L9248
// Test: ImplicitConversionCharToDecimal. Upstream file SHA-256: 919176486C83FA111EED5E79165BB81AD29CDE9EFFEC1D636AB7C712FCBA4FDE

public class Test
{
    static void Main() 
    {
        char source = '\x1';
        decimal	dest = source;
    } 
}
