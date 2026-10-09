// Supplemental representation and compiler-selected runtime overload cases.
using System;
public static class SemanticBoundaries
{
    public static bool Text(string a, string b) => a == b;
    public static int Switch(string a) => a switch { "é" => 1, _ => 2 };
    public static bool ArrayIdentity() { int[] a = new int[0]; int[] b = new int[0]; return a == a && a != b; }
    public static bool BoxIdentity() { object a = new object(); object b = new object(); return a == a && a != b; }
    public static string Overload() { object value = null; return Convert.ToString(value); }
    public static string Params() => string.Format("{0},{1},{2},{3}", 1, 2, 3, 4);
    public static float Single(float a, float b) => a + b;
    public static double Zero(double a, double b) => a / b;
    public static bool Nan(double a, double b) => a == b;
    public static bool NanLess(double a, double b) => a < b;
    public static char Index(string s, int n) => s[n];
}
