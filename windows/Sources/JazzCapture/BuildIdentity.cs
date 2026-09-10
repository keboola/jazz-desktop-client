using System.Reflection;

namespace JazzCapture;

/// <summary>Release identity stamped by the installer version source into the executable.</summary>
public static class BuildIdentity
{
    public static string ProducerVersion { get; } = ReadProducerVersion();

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
