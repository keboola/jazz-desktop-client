namespace JazzCaptureCore;

/// <summary>
/// The result of parsing this process's command line, exactly once, at startup.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="Parse"/> is the only command-line surface this client has. <c>App.OnStartup</c>
/// reads <c>StartupEventArgs.Args</c> and calls this once; nothing else in the codebase reads
/// <c>Environment.GetCommandLineArgs()</c> or any other argv surface, and nothing here should
/// start doing so.
/// </para>
/// <para>
/// This type carries exactly one <see langword="bool"/> and nothing else, so no secret -- a
/// token, an endpoint, a bundle -- can ever travel through it or be echoed back from it (#62
/// design constraint 2). A bare switch with no value form is a stronger guarantee than validating
/// a value: there is syntactically nowhere for one to go.
/// </para>
/// <para>
/// Unknown and malformed arguments are ignored deliberately, never fatal. This process is
/// launched by Explorer, the Start Menu shortcut, the HKCU Run value, and by hand; failing
/// startup on a stray argument would turn a typo into a total capture outage, the opposite of
/// every other failure posture in this client (<c>HostSettingsStore</c> degrades to seeds rather
/// than throwing; <c>App.xaml.cs</c> catches a staging failure narrowly rather than aborting
/// startup).
/// </para>
/// <para>
/// There is no "off" form, so a contradiction between two arguments is not expressible -- that is
/// a direct consequence of the switch being a bare flag (#76 §2.1). Whoever adds a negative form
/// later (tracked against #60's managed-policy layer) has to define that rule deliberately rather
/// than inherit one from this type's current, simpler behaviour.
/// </para>
/// <para>
/// <see cref="CaptureAtLaunch"/> is process-scoped: it must never be written into
/// <c>HostSettings</c> or any other persisted document. See <see cref="EffectiveCaptureAtLaunch"/>
/// for how it is combined with the persisted user setting without ever being folded into it.
/// </para>
/// </remarks>
public sealed record LaunchOptions(bool CaptureAtLaunch)
{
    /// <summary>
    /// The one recognised switch. Matched case-insensitively, presence-only, with no value form
    /// and no alias.
    /// </summary>
    public const string CaptureAtLaunchSwitch = "--capture-at-launch";

    /// <summary>
    /// Parses a process's command-line arguments into <see cref="LaunchOptions"/>.
    /// </summary>
    /// <param name="arguments">
    /// <c>StartupEventArgs.Args</c>, or <see langword="null"/>/empty for a process launched with
    /// none. Every element other than an exact (case-insensitive) match for
    /// <see cref="CaptureAtLaunchSwitch"/> is ignored -- not stored, not rendered, not persisted --
    /// so there is no member through which a command line could ever be echoed.
    /// </param>
    public static LaunchOptions Parse(IReadOnlyList<string>? arguments)
    {
        if (arguments is null || arguments.Count == 0)
        {
            return new LaunchOptions(false);
        }

        foreach (string argument in arguments)
        {
            if (string.Equals(argument, CaptureAtLaunchSwitch, StringComparison.OrdinalIgnoreCase))
            {
                return new LaunchOptions(true);
            }
        }

        return new LaunchOptions(false);
    }
}
