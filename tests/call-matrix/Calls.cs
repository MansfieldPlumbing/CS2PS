// Binding regressions supplement the stable 30-fixture corpus.
public static class CallMappings
{
    public static string BoxedText(object value) => System.Convert.ToString(value);
    public static string Format(object value) => string.Format("[{0}]", value);
    public static int Parse(string text) => int.Parse(text);
    public static string Once() { int i = 0; return string.Format("{0}/{1}", i++, i++); }
    public static int Write(object value) { System.Console.Write("[{0}]", value); return 1; }
    public static int BeforeNullCheck(string text) { System.Console.Write("before"); return text.Length; }
    public static bool ShortCircuit(bool enabled, string text) { return enabled && text.Length > 0; }
    public static int ClearedInsideBranch(string text) { if (text.Length > 0) { text = null; return text.Length; } return 0; }
    public static bool Empty(string text) { return text == ""; }
    public static bool Named(string text) { return text == "named"; }
    public static char Indexed(string text, int index) { return text[index]; }
    public static string NullableResult(string text) { return text; }
}
