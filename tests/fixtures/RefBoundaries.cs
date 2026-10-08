// Supplemental ref/out propagation, aliasing and .NET out arguments.
public static class RefBoundaries
{
    public static int Change(ref int value, out int doubled) { value += 3; doubled = value * 2; return doubled + value; }
    public static int Wrapper(int value) { int output; return Change(ref value, out output) + output + value; }
    public static int Forward(ref int value) { int output; return Change(ref value, out output); }
    public static int Parse(string text) { int number; bool ok = int.TryParse(text, out number); return ok ? number : -1; }
    public static int Declaration(string text) { bool ok = int.TryParse(text, out int number); return ok ? number : -1; }
}
