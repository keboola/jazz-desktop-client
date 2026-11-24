using System.Text.RegularExpressions;

namespace JazzCaptureCore.Consent;

public enum ConsentBlockKind
{
    Heading,
    Paragraph,
    ListItem,
}

/// <summary>A run of text with one style.</summary>
public sealed record ConsentSpan(string Text, bool Bold, bool Italic);

/// <param name="Level">Heading level from 1 to 6. Zero for other blocks.</param>
public sealed record ConsentBlock(ConsentBlockKind Kind, int Level, IReadOnlyList<ConsentSpan> Spans)
{
    public string PlainText => string.Concat(Spans.Select(span => span.Text));
}

/// <summary>
/// Reads the small Markdown subset the served consent texts use: headings, paragraphs, bullet
/// lists, bold and italic. Anything else is shown as plain text. The result holds no markup, so the
/// UI cannot run or fetch anything from a served body.
/// </summary>
public static class ConsentMarkdown
{
    private static readonly Regex Heading = new(@"^(#{1,6})\s+(.*)$", RegexOptions.CultureInvariant);
    private static readonly Regex Bullet = new(@"^\s*[-*]\s+(.*)$", RegexOptions.CultureInvariant);
    private static readonly Regex Emphasis = new(
        @"\*\*(?!\s)(?<bold>[^*]+?)(?<!\s)\*\*|\*(?!\s)(?<italic>[^*]+?)(?<!\s)\*",
        RegexOptions.CultureInvariant);

    public static IReadOnlyList<ConsentBlock> Parse(string body)
    {
        ArgumentNullException.ThrowIfNull(body);

        var blocks = new List<ConsentBlock>();
        var paragraph = new List<string>();

        void FlushParagraph()
        {
            if (paragraph.Count == 0) return;
            blocks.Add(new ConsentBlock(ConsentBlockKind.Paragraph, 0, Spans(string.Join(" ", paragraph))));
            paragraph.Clear();
        }

        foreach (string raw in body.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            string line = raw.TrimEnd();
            if (line.Length == 0)
            {
                FlushParagraph();
                continue;
            }

            Match heading = Heading.Match(line);
            if (heading.Success)
            {
                FlushParagraph();
                blocks.Add(new ConsentBlock(
                    ConsentBlockKind.Heading,
                    heading.Groups[1].Length,
                    Spans(heading.Groups[2].Value.Trim())));
                continue;
            }

            Match bullet = Bullet.Match(line);
            if (bullet.Success)
            {
                FlushParagraph();
                blocks.Add(new ConsentBlock(ConsentBlockKind.ListItem, 0, Spans(bullet.Groups[1].Value.Trim())));
                continue;
            }

            paragraph.Add(line.Trim());
        }

        FlushParagraph();
        return blocks;
    }

    private static IReadOnlyList<ConsentSpan> Spans(string text)
    {
        var spans = new List<ConsentSpan>();
        int position = 0;
        foreach (Match match in Emphasis.Matches(text))
        {
            if (match.Index > position)
                spans.Add(new ConsentSpan(text[position..match.Index], false, false));
            if (match.Groups["bold"].Success)
                spans.Add(new ConsentSpan(match.Groups["bold"].Value, true, false));
            else
                spans.Add(new ConsentSpan(match.Groups["italic"].Value, false, true));
            position = match.Index + match.Length;
        }

        if (position < text.Length)
            spans.Add(new ConsentSpan(text[position..], false, false));
        return spans;
    }
}
