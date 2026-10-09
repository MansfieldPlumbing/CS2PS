// Supplemental nullable values, lifted operators and lazy coalescing.
using System;
public static class NullableBoundaries
{
    public static int? Add(int? a, int? b) => a + b;
    public static bool Equal(int? a, int? b) => a == b;
    public static bool Less(int? a, int? b) => a < b;
    public static bool Has(int? a) => a.HasValue;
    public static int Value(int? a) => a.Value;
    public static int Default(int? a, int b) => a.GetValueOrDefault(b);
    public static int Zero(int? a) => a.GetValueOrDefault();
    public static int Coalesce(int? a) => a ?? Side();
    public static int Side() { Console.Write("side"); return 5; }
    public static int? Increment(int? a) { a++; return a; }
    public static int? Negate(int? a) => -a;
    public static int? Divide(int? a, int? b) => a / b;
    public static int Cast(int? a) => (int)a;
    public static long? Widen(int? a) => (long?)a;
    public static int Assign(int? a) { a ??= 5; a += 2; return a.Value; }
    public static bool? And(bool? a, bool? b) => a & b;
    public static bool? Or(bool? a, bool? b) => a | b;
    public static bool? Xor(bool? a, bool? b) => a ^ b;
    public static bool? Not(bool? a) => !a;
    public static int Eager() { int i = 0; bool? a = null; bool? b = a & (++i > 0); return i; }
    public static int DefaultEvaluation(int? a) { int i = 0; int n = a.GetValueOrDefault(++i); return n * 10 + i; }
    public static string Text(int? a) => a.ToString();
    public static int? Empty() => default(int?);
    public static double? Floating(double? a, double? b) => a / b;
    public static bool FloatingEqual(double? a, double? b) => a == b;
}
