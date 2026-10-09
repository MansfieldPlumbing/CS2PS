public static class ConditionalBinding
{
#if ANDROID_36
    public static int ApiLevel() => 36;
    public static string TypeName() => nameof(ConditionalBinding);
#else
#error Android profile must be supplied explicitly.
#endif
}
