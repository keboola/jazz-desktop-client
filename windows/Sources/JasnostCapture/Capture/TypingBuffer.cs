using System.Text;

namespace JasnostCapture.Capture;

/// <summary>
/// Accumulates printable keystrokes into a per-field string and flushes one typed run at a boundary
/// (ANNEX-HOST section 2). It mirrors the macOS <c>TypingAccumulator</c>: backspace edits the buffer,
/// Alt+Backspace deletes a word, and a UI Automation read-back of the rendered value wins over key
/// concatenation when one is available, so IME, autocorrect and cursor edits are captured correctly.
/// </summary>
/// <remarks>
/// The buffer also carries the focus snapshot taken when typing began — role, accessible name, a
/// focus-identity key, and the field's sensitivity — because reconciliation is admitted only when the
/// field observed at the flush boundary is still the field that was typed into.
/// </remarks>
public sealed class TypingBuffer
{
    private readonly int _reconcileMaxBytes;
    private readonly StringBuilder _buffer = new();

    /// <summary>Creates a buffer bounding how large a reconciled read-back it will trust.</summary>
    /// <param name="reconcileMaxBytes">Longest UTF-8 read-back that may replace the key buffer.</param>
    public TypingBuffer(int reconcileMaxBytes) => _reconcileMaxBytes = reconcileMaxBytes;

    /// <summary>Whether nothing has been buffered since the last flush.</summary>
    public bool IsEmpty => _buffer.Length == 0;

    /// <summary>The control-type role of the field being typed into.</summary>
    public string? TargetRole { get; private set; }

    /// <summary>The accessible name of the field being typed into.</summary>
    public string? TargetName { get; private set; }

    /// <summary>The focus identity <c>identifier|role|label</c> the buffer belongs to.</summary>
    public string? FocusKey { get; private set; }

    /// <summary>Whether the field being typed into is sensitive.</summary>
    public bool IsSensitive { get; private set; }

    /// <summary>Snapshots the focus when a run begins, so later reconciliation can be validated.</summary>
    public void BeginRun(string? role, string? name, string? focusKey, bool sensitive)
    {
        TargetRole = role;
        TargetName = name;
        FocusKey = focusKey;
        IsSensitive = sensitive;
    }

    /// <summary>Appends produced characters to the buffer.</summary>
    public void Append(string characters) => _buffer.Append(characters);

    /// <summary>Removes the last character, if any.</summary>
    public void Backspace()
    {
        if (_buffer.Length > 0)
        {
            _buffer.Length--;
        }
    }

    /// <summary>Removes trailing whitespace and then the preceding word.</summary>
    public void WordBackspace()
    {
        while (_buffer.Length > 0 && char.IsWhiteSpace(_buffer[^1]))
        {
            _buffer.Length--;
        }

        while (_buffer.Length > 0 && !char.IsWhiteSpace(_buffer[^1]))
        {
            _buffer.Length--;
        }
    }

    /// <summary>
    /// Returns the best available value for the run and clears the buffer. A non-empty read-back
    /// within the size bound and belonging to the same focus wins; otherwise the raw key buffer is
    /// returned.
    /// </summary>
    /// <param name="reconciledValue">The field's rendered value, or <see langword="null"/>.</param>
    /// <param name="reconciledFocusKey">Focus identity of that read-back, for the identity check.</param>
    public string Flush(string? reconciledValue, string? reconciledFocusKey)
    {
        string buffered = _buffer.ToString();
        _buffer.Clear();

        bool sameFocus = FocusKey is not null && FocusKey == reconciledFocusKey;
        if (sameFocus
            && !IsSensitive
            && reconciledValue is not null
            && reconciledValue.Trim().Length > 0
            && Encoding.UTF8.GetByteCount(reconciledValue) <= _reconcileMaxBytes)
        {
            return reconciledValue;
        }

        return buffered;
    }

    /// <summary>Clears the buffer and the focus snapshot without producing a value.</summary>
    public void Reset()
    {
        _buffer.Clear();
        TargetRole = null;
        TargetName = null;
        FocusKey = null;
        IsSensitive = false;
    }
}
