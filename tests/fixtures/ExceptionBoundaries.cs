// Supplemental catch ordering, rethrow, null throws and finally semantics.
using System;
public static class ExceptionBoundaries
{
    public static string Catch(int n)
    {
        string result = "";
        try { if (n == 0) throw new ArgumentException("bad"); if (n == 1) throw new InvalidOperationException("other"); result = "ok"; }
        catch (ArgumentException ex) { result = ex.Message; }
        catch (Exception) { result = "general"; }
        finally { result += "!"; }
        return result;
    }
    public static int ReturnFinally()
    {
        int n = 2;
        try { return n; } finally { n = 7; Console.Write(n); }
    }
    public static int FinallyThrows() { try { return 7; } finally { throw new InvalidOperationException(); } }
    public static int Rethrow() { try { throw new ArgumentException(); } catch (Exception) { throw; } }
    public static int ThrowNull() { throw null; }
    public static int ThrowExpression(bool fail) => fail ? throw new ArgumentException() : 4;
    public static string RuntimeCatch() { try { int.Parse("bad"); return "ok"; } catch (FormatException) { return "format"; } }
    public static int NullMethod() { object obj = null; try { obj.ToString(); } catch (NullReferenceException) { return 3; } return 4; }
}
