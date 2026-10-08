// Supplemental UTF-16 numeric promotion, wrapping and ordinal comparisons.
public static class CharBoundaries
{
    public static int Add(char a, char b) => a + b;
    public static int Difference(char a, char b) => a - b;
    public static char Advance(char value, int amount) => unchecked((char)(value + amount));
    public static char Increment(char value) { value++; return value; }
    public static char CheckedIncrement(char value) { checked { value++; return value; } }
    public static bool Equal(char a, char b) => a == b;
    public static bool Less(char a, char b) => a < b;
    public static decimal Decimal(char value) { decimal result = value; return result; }
    public static int Constant() => '\'' + '\n';
    public static char Wrap(int value) => (char)value;
}
