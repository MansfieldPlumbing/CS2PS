// Supplemental formatting, escaping, null and evaluation-order cases.
public static class FormatBoundaries
{
    public static string Show(string text, double value) => $"{{{text}}} [{value,10:N2}] {value:F1}";
    public static string Composite(double value) { return string.Format("{0:N2}/{0,8:F1}", value); }
    public static string Escape(string text) => $@"it's {{literal}}: {text}";
    public static string Order() { int i = 0; return $"{i++},{i++},{i}"; }
    public static string Empty() => $"";
}
