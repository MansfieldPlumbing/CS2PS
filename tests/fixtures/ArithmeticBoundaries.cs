// Supplemental fixed-width arithmetic and lexical overflow contexts.
public static class ArithmeticBoundaries
{
    public static int Add(int a, int b) => checked(a + b);
    public static int Wrap(int a, int b) => unchecked(a + b);
    public static int Multiply(int a, int b) { checked { return a * b; } }
    public static int Narrow(long value) => unchecked((int)value);
    public static byte NarrowByte(int value) => unchecked((byte)value);
    public static byte CheckedByte(int value) => checked((byte)value);
    public static int Divide(int a, int b) => a / b;
    public static int Remainder(int a, int b) => a % b;
    public static int Nested(int a) { checked { return unchecked(a + 1); } }
    public static int Increment(int a) { checked { return a++; } }
    public static long LongWrap(long value) => unchecked(value + 1);
    public static ulong UnsignedWrap(ulong value) => unchecked(value + 1);
    public static int Floating(double value) => unchecked((int)value);
    public static int CheckedFloating(double value) => checked((int)value);
    public static byte FloatingByte(double value) => unchecked((byte)value);
}
