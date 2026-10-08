// Supplemental switch boundary and control-flow parity cases.
public static class SwitchBoundaries
{
    public static int Match(string text)
    {
        int value = 9;
        switch (text) { case "a": value = 1; break; case "A": value = 2; break; case null: value = 3; break; default: value = 4; break; }
        return value;
    }
    public static int Expression(string text) => text switch { "a" => 1, "A" => 2, null => 3, _ => 4 };
    public static int Missing(int value) => value switch { 1 => 7 };
    public static int Guard(int value) => value switch { 1 when value > 0 => 7, _ => 8 };
    public static int Flow()
    {
        int sum = 0;
        for (int i = 0; i < 4; i++)
        {
            switch (i) { case 0: continue; case 1: case 2: sum += 2; break; default: sum += 3; break; }
            sum++;
        }
        return sum;
    }
}
