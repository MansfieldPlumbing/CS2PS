// Copyright (c) .NET Foundation and Contributors. MIT; see ROSLYN-LICENSE.txt.
// Extracted without semantic edits from https://github.com/dotnet/roslyn/blob/ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da/src/Compilers/CSharp/Test/Emit3/Semantics/PatternMatchingTests3.cs#L1249
// Test: TargetTypedSwitch_NaturalTypeWithUntypedArm_01. Upstream file SHA-256: F6237CA104690B51A3348085D8E7BF3F5067CF4604BFD23DB8B15DC8A11954E3

class Program
{
    public static bool? GetBool(string name)
    {
        return name switch
        {
            "a" => true,
            "b" => false,
            _ => null,
        };
    }
}

