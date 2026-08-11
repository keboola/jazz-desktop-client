using JasnostCaptureCore.Input;

namespace JasnostCaptureCoreTests;

/// <summary>
/// Pins the classification order and VK mapping of ANNEX-HOST section 2. The classifier is the one
/// host-adjacent piece that is pure and testable off Windows, so its contract is fixed here.
/// </summary>
public sealed class KeyClassifierTests
{
    // Virtual-key codes used by the vectors below.
    private const ushort VkBack = 0x08;
    private const ushort VkTab = 0x09;
    private const ushort VkReturn = 0x0D;
    private const ushort VkEscape = 0x1B;
    private const ushort VkSpace = 0x20;
    private const ushort VkPageUp = 0x21;
    private const ushort VkPageDown = 0x22;
    private const ushort VkEnd = 0x23;
    private const ushort VkHome = 0x24;
    private const ushort VkLeft = 0x25;
    private const ushort VkUp = 0x26;
    private const ushort VkRight = 0x27;
    private const ushort VkDown = 0x28;
    private const ushort VkDelete = 0x2E;
    private const ushort VkA = 0x41;
    private const ushort VkS = 0x53;
    private const ushort VkZ = 0x5A;
    private const ushort Vk1 = 0x31;

    [Fact]
    public void Printable_Character_Becomes_Text()
    {
        Assert.Equal(KeyAction.Text("a"), Classify(VkA, "a"));
        Assert.Equal(KeyAction.Text(" "), Classify(VkSpace, " "));
    }

    [Fact]
    public void No_Characters_For_Printable_Vk_Is_Ignored()
    {
        Assert.Equal(KeyAction.Ignored, Classify(VkA, chars: null));
        Assert.Equal(KeyAction.Ignored, Classify(VkA, chars: string.Empty));
    }

    [Fact]
    public void Control_Character_Is_Ignored()
    {
        // Sub-space control characters and 0x7F (DEL) are never typed text.
        Assert.Equal(KeyAction.Ignored, Classify(VkA, ((char)0x01).ToString()));
        Assert.Equal(KeyAction.Ignored, Classify(VkA, ((char)0x7F).ToString()));
    }

    [Fact]
    public void Backspace_Is_Checked_Before_Chords()
    {
        Assert.Equal(KeyAction.Backspace, Classify(VkBack, chars: null));
        // Alt+Backspace deletes a word; classified before the chord rule so the accumulator can
        // reproduce the edit rather than emit a shortcut.
        Assert.Equal(KeyAction.WordBackspace, Classify(VkBack, chars: null, alt: true));
    }

    [Fact]
    public void Backspace_With_Ctrl_Or_Win_Is_A_Shortcut()
    {
        // Once Ctrl or Win is held, Backspace is no longer a buffer edit.
        Assert.Equal(KeyAction.Shortcut("Ctrl+Backspace"), Classify(VkBack, chars: null, ctrl: true));
        Assert.Equal(KeyAction.Shortcut("Win+Backspace"), Classify(VkBack, chars: null, win: true));
    }

    [Fact]
    public void Ctrl_Chord_Becomes_Shortcut()
    {
        Assert.Equal(KeyAction.Shortcut("Ctrl+S"), Classify(VkS, "s", ctrl: true));
        Assert.Equal(KeyAction.Shortcut("Ctrl+Shift+Z"), Classify(VkZ, "z", ctrl: true, shift: true));
        Assert.Equal(KeyAction.Shortcut("Win+1"), Classify(Vk1, "1", win: true));
    }

    [Fact]
    public void Chord_Modifier_Order_Is_Win_Ctrl_Alt_Shift()
    {
        Assert.Equal(
            KeyAction.Shortcut("Win+Ctrl+Alt+Shift+A"),
            Classify(VkA, "a", ctrl: true, alt: true, shift: true, win: true));
    }

    [Fact]
    public void Named_Keys_Become_Special()
    {
        Assert.Equal(KeyAction.Special("Enter"), Classify(VkReturn, "\r"));
        Assert.Equal(KeyAction.Special("Tab"), Classify(VkTab, "\t"));
        Assert.Equal(KeyAction.Special("Escape"), Classify(VkEscape, ""));
        Assert.Equal(KeyAction.Special("ArrowLeft"), Classify(VkLeft, chars: null));
        Assert.Equal(KeyAction.Special("ArrowRight"), Classify(VkRight, chars: null));
        Assert.Equal(KeyAction.Special("ArrowUp"), Classify(VkUp, chars: null));
        Assert.Equal(KeyAction.Special("ArrowDown"), Classify(VkDown, chars: null));
        Assert.Equal(KeyAction.Special("Home"), Classify(VkHome, chars: null));
        Assert.Equal(KeyAction.Special("End"), Classify(VkEnd, chars: null));
        Assert.Equal(KeyAction.Special("PageUp"), Classify(VkPageUp, chars: null));
        Assert.Equal(KeyAction.Special("PageDown"), Classify(VkPageDown, chars: null));
        Assert.Equal(KeyAction.Special("ForwardDelete"), Classify(VkDelete, chars: null));
    }

    [Fact]
    public void Named_Key_In_Chord_Uses_Its_Name()
    {
        Assert.Equal(
            KeyAction.Shortcut("Ctrl+Alt+ForwardDelete"),
            Classify(VkDelete, chars: null, ctrl: true, alt: true));
    }

    [Fact]
    public void Lone_Modifier_Is_Ignored()
    {
        // A modifier virtual-key on its own carries no character and is not a named key.
        const ushort vkShift = 0x10;
        Assert.Equal(KeyAction.Ignored, Classify(vkShift, chars: null, shift: true));
    }

    private static KeyAction Classify(
        ushort vk,
        string? chars,
        bool ctrl = false,
        bool alt = false,
        bool shift = false,
        bool win = false) =>
        KeyClassifier.Classify(vk, chars, ctrl, alt, shift, win);
}
