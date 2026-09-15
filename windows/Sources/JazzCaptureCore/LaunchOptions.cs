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
/// This type carries only booleans, so no secret -- a token, an endpoint, a bundle -- can ever
/// travel through it or be echoed back from it (#62 design constraint 2). Bare switches with no
/// value form are a stronger guarantee than validating a value: there is syntactically nowhere
/// for one to go.
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
/// <see cref="CaptureAtLaunch"/> is process-scoped: it must never be written into
/// <c>HostSettings</c> or any other persisted document. See <see cref="EffectiveCaptureAtLaunch"/>
/// for how it is combined with the persisted user setting without ever being folded into it.
/// <see cref="ResumeAfterUpdate"/> is also process-scoped; the MSI post-install launch is the
/// only producer. The HKCU Run value must not carry it, so a paused logon stays paused.
/// </para>
/// </remarks>
public sealed record LaunchOptions(bool CaptureAtLaunch, bool ResumeAfterUpdate)
{
    /// <summary>
    /// The capture-at-launch switch. Matched case-insensitively, presence-only, with no value form
    /// and no alias.
    /// </summary>
    public const string CaptureAtLaunchSwitch = "--capture-at-launch";

    /// <summary>
    /// Post-install only: ignore a persisted pause for this process and start recording.
    /// </summary>
    public const string ResumeAfterUpdateSwitch = "--resume-after-update";

    /// <summary>
    /// Parses a process's command-line arguments into <see cref="LaunchOptions"/>.
    /// </summary>
    /// <param name="arguments">
    /// <c>StartupEventArgs.Args</c>, or <see langword="null"/>/empty for a process launched with
    /// none. Every element other than an exact (case-insensitive) match for a recognised switch
    /// is ignored -- not stored, not rendered, not persisted -- so there is no member through
    /// which a command line could ever be echoed.
    /// </param>
    public static LaunchOptions Parse(IReadOnlyList<string>? arguments)
    {
        bool captureAtLaunch = false;
        bool resumeAfterUpdate = false;
        if (arguments is null || arguments.Count == 0)
        {
            return new LaunchOptions(false, false);
        }

        foreach (string argument in arguments)
        {
            if (string.Equals(argument, CaptureAtLaunchSwitch, StringComparison.OrdinalIgnoreCase))
                captureAtLaunch = true;
            else if (string.Equals(argument, ResumeAfterUpdateSwitch, StringComparison.OrdinalIgnoreCase))
                resumeAfterUpdate = true;
        }

        return new LaunchOptions(captureAtLaunch, resumeAfterUpdate);
    }
}
