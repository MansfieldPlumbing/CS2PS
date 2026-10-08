// Supplemental signedness, count masking, complement and eager boolean cases.
public static class BitBoundaries
{
    public static int Mix(int a, int b) => (a & b) ^ (a | b) ^ ~a;
    public static int Left(int value, int count) => checked(value << count);
    public static int Right(int value, int count) => value >> count;
    public static int Logical(int value, int count) => value >>> count;
    public static uint Unsigned(uint value, int count) => ~value >> count;
    public static long LongLogical(long value, int count) => value >>> count;
    public static int Assign(int value) { value ^= 7; value <<= 33; value >>= 1; return value; }
    public static int Eager() { int i = 0; bool a = false & (++i > 0); bool b = true | (++i > 0); bool c = true ^ (++i > 0); return i; }
}
