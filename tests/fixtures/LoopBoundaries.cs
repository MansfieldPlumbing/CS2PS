// Supplemental regression cases; upstream loop fixtures retain their source.
using System.Collections.Generic;
public static class LoopBoundaries
{
    public static int Scan(int[] values)
    {
        int sum = 0;
        for (int i = 0; i < values.Length; i++)
        {
            if (values[i] < 0) continue;
            if (values[i] == 99) break;
            sum += values[i];
        }
        int j = 0;
        while (j < values.Length) { sum += values[j]; j++; }
        foreach (int item in values) { sum += item; }
        return sum;
    }
    public static int ScanList(List<int> values)
    {
        int sum = 0;
        for (int i = 0; i < values.Count; i++) sum += values[i];
        int j = 0;
        while (j < values.Count) { sum += values[j]; j++; }
        foreach (int value in values) sum += value;
        return sum;
    }
    public static int Names(int value, int Value)
    {
        int PID = value;
        { int x = Value; PID += x; }
        { int x = 7; PID += x; }
        return PID;
    }
    public static int Index(int[] values, int i) { return values[i]; }
    public static int Mutate(List<int> values)
    {
        foreach (int item in values) { values.Add(item); }
        return values.Count;
    }
    public static int[] Identity(int[] values) { return values; }
}
