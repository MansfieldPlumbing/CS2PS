// Binding regressions supplement the stable 30-fixture corpus.
public static class CallMappings
{
    public static string BoxedText(object value) => System.Convert.ToString(value);
    public static string Format(object value) => string.Format("[{0}]", value);
    public static int Parse(string text) => int.Parse(text);
    public static string Once() { int i = 0; return string.Format("{0}/{1}", i++, i++); }
    public static int Write(object value) { System.Console.Write("[{0}]", value); return 1; }
}
