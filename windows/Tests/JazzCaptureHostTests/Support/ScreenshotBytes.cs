namespace JazzCaptureHostTests;

/// <summary>
/// A real JPEG for the host tests that need one. Mirrors
/// <c>JazzCaptureCoreTests.ScreenshotBytes</c>, which is <c>internal</c> to the Core test project
/// and therefore not visible here.
/// </summary>
/// <remarks>
/// The staging area only ever hashes and round-trips these bytes, so nothing downstream would
/// notice a placeholder -- but an artifact declaring <c>image/jpeg</c> over bytes that are not a
/// JPEG is a lie the fixtures would then carry. This is a genuine 8x8 grayscale baseline JPEG at
/// quality 85, 159 bytes.
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
