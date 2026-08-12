namespace JazzCaptureCoreTests;

/// <summary>
/// A real JPEG for the tests that need one.
/// </summary>
/// <remarks>
/// The archive only ever hashes these bytes, so nothing downstream would notice a placeholder — but
/// an artifact declaring <c>image/jpeg</c> over bytes that are not a JPEG is a lie the fixtures would
/// then carry, and anyone opening one to see what the client produces would find garbage. This is a
/// genuine 8x8 grayscale baseline JPEG at quality 85, 159 bytes.
/// </remarks>
internal static class ScreenshotBytes
{
    private const string Base64 =
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAUDBAQEAwUEBAQFBQUGBwwIBwcHBw8LCwkMEQ8SEhEP"
        + "ERETFhwXExQaFRERGCEYGh0dHx8fExciJCIeJBweHx7/wAALCAAIAAgBAREA/8QAFAABAAAAAAAA"
        + "AAAAAAAAAAAAAv/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AL//Z";

    /// <summary>The JPEG bytes; a fresh array each time, so a test can never mutate the fixture.</summary>
    internal static byte[] TinyJpeg => Convert.FromBase64String(Base64);
}
