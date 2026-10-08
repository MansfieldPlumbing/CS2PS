// A small fixture exercising the semantic traps between C# and PowerShell:
// integer division, case-sensitive string equality, string concatenation
// with numbers, narrowing casts from floating point, and C-style loops.
public static class ProgressLayout
{
    public static int BarWidth(int percent, int columns)
    {
        if (percent < 0) percent = 0;
        if (percent > 100) percent = 100;
        return columns * percent / 100;
    }

    public static string FormatLabel(string activity, int percent)
    {
        string text = activity + ": " + percent + "%";
        if (text.Length > 20)
        {
            text = text.Substring(0, 17) + "...";
        }
        return text;
    }

    public static bool IsSame(string a, string b)
    {
        return a == b;
    }

    public static int SumTo(int n)
    {
        int total = 0;
        for (int i = 1; i <= n; i++)
        {
            total += i;
        }
        return total;
    }

    public static double Ratio(int a, int b)
    {
        return (double)a / b;
    }

    public static int Midpoint(double a, double b)
    {
        return (int)((a + b) / 2);
    }

    public static int Clamp(int value, int low, int high)
    {
        return value < low ? low : (value > high ? high : value);
    }
}
