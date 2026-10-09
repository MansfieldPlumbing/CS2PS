// Copyright (c) .NET Foundation and Contributors. MIT; see ROSLYN-LICENSE.txt.
// Extracted without semantic edits from https://github.com/dotnet/roslyn/blob/ac3aeb5c871a6bac2369a9fa9d2b2f5b27f9d9da/src/Compilers/CSharp/Test/Emit/CodeGen/CodeGenOptimizedNullableOperators.cs#L2013
// Test: TestNullableBoolBinOpsOneNull. Upstream file SHA-256: 54DDF2777AFD019D2DF670B61A50B5B895CC90E604417850EC7F276C9C60CB4C

class Program
{
    static bool? N() { return false; }
    static bool B() { return false; }
    static bool? M1()
    {
        // Generated as temp = N(), temp.GetValueOrDefault() ? null : temp
        return N() & new bool?();
    }
    static bool? M2()
    {
        // Generated as temp = N(), temp.GetValueOrDefault() ? null : temp
        return default(bool?) & N();
    }
    static bool? M3()
    {
        // Generated as temp = N(), temp.GetValueOrDefault() ? temp : null
        return N() | new bool?();
    }
    static bool? M4()
    {
        // Generated as temp = N(), temp.GetValueOrDefault() ? temp : null
        return default(bool?) | N();
    }
    static bool? M5()
    {
        // Generated as B() ? null : new bool?(false)
        return new bool?(B()) & new bool?();
    }
    static bool? M6()
    {
        // Generated as B() ? null : new bool?(false)
        return default(bool?) & new bool?(B());
    }
    static bool? M7()
    {
        // Generated as B() ? new bool?(true) : null
        return new bool?(B()) | new bool?();
    }
    static bool? M8()
    {
        // Generated as B() ? new bool?(true) : null
        return default(bool?) | new bool?(B());
    }
    static void Main() {}
}


