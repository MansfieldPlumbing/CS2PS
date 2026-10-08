// Supplemental copy, nested value and shared reference semantics.
public class Box { public int Value; }
public struct Point
{
    public int X;
    public int x;
    public Box Shared;
    public Point(int n) { X = n; x = 2; Shared = new Box(); }
    public int Increment() { X++; return X; }
}
public struct Pair { public Point P; public int Tag; }
public static class StructBoundaries
{
    public static int Modify(Point value) { value.X = 99; value.Shared.Value = 7; return value.X; }
    public static Point Copy(Point value) { return value; }
    public static int Exercise(int n)
    {
        Point a = new Point(n);
        Point b = a;
        b.Increment();
        int result = Modify(b);
        Point c = Copy(a);
        c.X = 20;
        return a.X + b.X + c.X + a.Shared.Value + a.x + result;
    }
    public static int Nested()
    {
        Pair a = default(Pair);
        a.P.X = 4;
        Pair b = a;
        b.P.X = 8;
        return a.P.X + b.P.X + a.Tag;
    }
    public static int Zero() { Point p = new Point(); return p.X + p.x; }
}
