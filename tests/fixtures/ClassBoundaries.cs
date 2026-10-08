// Supplemental simple class identity, constructor and method parity cases.
public class Counter
{
    public int value;
    public int Value = 3;
    public string label;
    public Counter(int value) { this.value = value; }
    public int Add(int amount) { value += amount; return value + Value; }
    public int Read() { return value; }
    public int read() { return Value; }
    public int Twice(int amount) { return Add(amount) + Add(amount); }
}
public static class ClassBoundaries
{
    public static int Exercise(int n)
    {
        Counter a = new Counter(n);
        Counter b = a;
        b.value = 8;
        return a.Twice(2) + b.Read() + b.read();
    }
    public static bool Identity()
    {
        Counter a = new Counter(1);
        Counter b = new Counter(1);
        Counter c = a;
        return a != b && a == c;
    }
    public static string Defaults() { Counter c = new Counter(0); return c.label; }
    public static int NullField() { Counter c = null; return c.value; }
    public static int NullMethod() { Counter c = null; return c.Read(); }
}
