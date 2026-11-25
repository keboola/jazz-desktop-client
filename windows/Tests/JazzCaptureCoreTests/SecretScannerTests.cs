using System.Diagnostics;
using System.Text;
using System.Text.Json;
using JazzCaptureCore;

namespace JazzCaptureCoreTests;

/// <summary>
/// Runs the shared vectors of <c>contract/secret-rules.vectors.json</c> through
/// <see cref="SecretScanner"/>. The Jazz server runs the same vectors against its own scanner.
/// </summary>
public sealed class SecretScannerTests
{
    public static IEnumerable<object[]> Vectors()
    {
        string path = Path.Combine(ContractPaths.Root(), "contract", "secret-rules.vectors.json");
        using JsonDocument document = JsonDocument.Parse(File.ReadAllText(path, Encoding.UTF8));
        int index = 0;
        foreach (JsonElement vector in document.RootElement.GetProperty("vectors").EnumerateArray())
        {
            yield return new object[]
            {
                index++,
                vector.GetProperty("rule").GetString()!,
                vector.GetProperty("field").GetString()!,
                vector.GetProperty("input").GetString()!,
                vector.GetProperty("expected").GetString()!,
                vector.GetProperty("count").GetInt32(),
            };
        }
    }

    [Theory]
    [MemberData(nameof(Vectors))]
    public void VectorProducesExpectedTextAndCount(
        int index, string rule, string field, string input, string expected, int count)
    {
        SecretField secretField = field switch
        {
            "typedText" => SecretField.TypedText,
            "title" => SecretField.Title,
            "url" => SecretField.Url,
            _ => throw new ArgumentOutOfRangeException(nameof(field), field, "unknown vector field"),
        };

        SecretScanResult result = SecretScanner.Default.Scan(input, secretField);

        Assert.True(expected == result.Text, $"vector {index} ({rule}, {field})");
        Assert.True(count == result.Count, $"vector {index} ({rule}, {field}) count");
    }

    [Fact]
    public void EmbeddedRulesAreTheContractFile()
    {
        string path = Path.Combine(ContractPaths.Root(), "contract", "secret-rules.json");
        SecretScanner fromFile = SecretScanner.FromJson(File.ReadAllText(path, Encoding.UTF8));

        Assert.Equal(1, SecretScanner.Default.Version);
        Assert.Equal(fromFile.Version, SecretScanner.Default.Version);
        Assert.Equal("[SECRET]", SecretScanner.Default.Replacement);
    }

    [Fact]
    public void VectorsCoverEveryRule()
    {
        string root = ContractPaths.Root();
        using JsonDocument rules = JsonDocument.Parse(
            File.ReadAllText(Path.Combine(root, "contract", "secret-rules.json"), Encoding.UTF8));
        using JsonDocument vectors = JsonDocument.Parse(
            File.ReadAllText(Path.Combine(root, "contract", "secret-rules.vectors.json"), Encoding.UTF8));

        var covered = vectors.RootElement.GetProperty("vectors").EnumerateArray()
            .Select(vector => vector.GetProperty("rule").GetString()!)
            .ToHashSet();

        foreach (JsonElement rule in rules.RootElement.GetProperty("rules").EnumerateArray())
        {
            Assert.Contains(rule.GetProperty("id").GetString()!, covered);
        }

        Assert.Contains("entropy", covered);
        Assert.Contains("passwordLike", covered);
    }

    [Fact]
    public void ScanIsIdempotent()
    {
        const string input = "password=Sup3r&Secret1 AKIAIOSFODNN7EXAMPLE";
        SecretScanResult first = SecretScanner.Default.Scan(input, SecretField.Title);
        SecretScanResult second = SecretScanner.Default.Scan(first.Text, SecretField.Title);

        Assert.Equal(2, first.Count);
        Assert.Equal(first.Text, second.Text);
        Assert.Equal(0, second.Count);
    }

    [Fact]
    public void NullAndEmptyInputAreReturnedAsEmpty()
    {
        Assert.Equal(new SecretScanResult(string.Empty, 0), SecretScanner.Default.Scan(null, SecretField.Title));
        Assert.Equal(new SecretScanResult(string.Empty, 0), SecretScanner.Default.Scan(string.Empty, SecretField.Url));
    }

    [Theory]
    [InlineData(SecretField.TypedText)]
    [InlineData(SecretField.Title)]
    [InlineData(SecretField.Url)]
    public void BinaryLookingInputNeverThrows(SecretField field)
    {
        var random = new Random(12345);
        char[] noise = new char[10_000];
        for (int i = 0; i < noise.Length; i++)
        {
            noise[i] = (char)random.Next(0, 0x10000);
        }

        string[] inputs =
        {
            new string(noise),
            new string('\0', 5_000),
            new string('A', 20_000),
            string.Concat(Enumerable.Repeat("a.", 5_000)),
            string.Concat(Enumerable.Repeat("http://a:", 10_000)),
            string.Concat(Enumerable.Repeat("password=", 10_000)),
            Convert.ToBase64String(RandomBytes(random, 8_000)),
            "\ud800 lone surrogate \udc00",
        };

        foreach (string input in inputs)
        {
            SecretScanResult result = SecretScanner.Default.Scan(input, field);
            Assert.NotNull(result.Text);
        }
    }

    [Theory]
    [InlineData(SecretField.TypedText)]
    [InlineData(SecretField.Title)]
    [InlineData(SecretField.Url)]
    public void TenKilobyteStringIsScannedQuickly(SecretField field)
    {
        string text = string.Concat(Enumerable.Repeat("The quick brown fox https://example.com/a/b?c=d ", 250))[..10_000];
        SecretScanner.Default.Scan("warm up", field);

        var timer = Stopwatch.StartNew();
        SecretScanResult result = SecretScanner.Default.Scan(text, field);
        timer.Stop();

        Assert.Equal(0, result.Count);
        Assert.True(timer.Elapsed < TimeSpan.FromSeconds(2), $"took {timer.Elapsed.TotalMilliseconds} ms");
    }

    private static byte[] RandomBytes(Random random, int length)
    {
        byte[] bytes = new byte[length];
        random.NextBytes(bytes);
        return bytes;
    }
}
