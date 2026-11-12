using System.Reflection;

namespace JazzCapture;

/// <summary>Release identity stamped by the installer version source into the executable.</summary>
public static class BuildIdentity
{
    public static string ProducerVersion { get; } = ReadProducerVersion();

    /// <summary>Built-in Entra ID enrollment server URL; empty when the build has none.</summary>
    public static string DefaultEnrollmentServerUrl { get; } = ReadOptional("JazzDefaultEnrollmentServerUrl");

    /// <summary>Built-in Entra ID app (client) id; empty when the build has none.</summary>
    public static string DefaultEntraClientId { get; } = ReadOptional("JazzDefaultEntraClientId");

    /// <summary>Built-in Jazz API app id (the token audience); empty when the build has none.</summary>
    public static string DefaultEntraApiId { get; } = ReadOptional("JazzDefaultEntraApiId");

    private static string ReadOptional(string key) => Assembly.GetExecutingAssembly()
        .GetCustomAttributes<AssemblyMetadataAttribute>()
        .SingleOrDefault(attribute => attribute.Key == key)?.Value ?? string.Empty;

    private static string ReadProducerVersion()
    {
        string? value = Assembly.GetExecutingAssembly()
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .SingleOrDefault(attribute => attribute.Key == "JazzProducerVersion")?.Value;
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException("The executable is missing its canonical Jazz producer version.");
        }

        return value;
    }
}
