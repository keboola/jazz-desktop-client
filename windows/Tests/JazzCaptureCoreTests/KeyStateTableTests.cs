using JazzCaptureCore.Input;

namespace JazzCaptureCoreTests;

/// <summary>
/// Pins the key-state table the low-level keyboard hook maintains for <c>ToUnicodeEx</c> and for
/// modifier detection.
/// </summary>
/// <remarks>
/// These are regression tests for two specific defects. <c>WH_KEYBOARD_LL</c> only ever reports the
/// side-specific modifier codes, so a table that does not maintain the generic indices reports no
/// modifiers at all — no chord is ever a shortcut and every character translates unshifted. And a
/// toggle bit that is cleared on key-up loses the Caps Lock state after the first press.
/// </remarks>
public sealed class KeyStateTableTests
{
    [Fact]
    public void LeftShiftDownSetsTheGenericShiftIndex()
    {
        var table = new KeyStateTable();
        table.Update(KeyStateTable.LeftShift, isDown: true);

        Assert.True(table.IsDown(KeyStateTable.LeftShift));
        Assert.True(table.IsDown(KeyStateTable.Shift));
        Assert.False(table.IsDown(KeyStateTable.RightShift));
    }

    [Theory]
    [InlineData(KeyStateTable.LeftControl, KeyStateTable.Control)]
    [InlineData(KeyStateTable.RightControl, KeyStateTable.Control)]
    [InlineData(KeyStateTable.LeftMenu, KeyStateTable.Menu)]
    [InlineData(KeyStateTable.RightMenu, KeyStateTable.Menu)]
    [InlineData(KeyStateTable.RightShift, KeyStateTable.Shift)]
    public void EverySideSpecificModifierMaintainsItsGenericIndex(int side, int generic)
    {
        var table = new KeyStateTable();

        table.Update(side, isDown: true);
        Assert.True(table.IsDown(generic));

        table.Update(side, isDown: false);
        Assert.False(table.IsDown(generic));
    }

    [Fact]
    public void ReleasingOneOfTwoHeldShiftsKeepsTheGenericIndexDown()
    {
        var table = new KeyStateTable();
        table.Update(KeyStateTable.LeftShift, isDown: true);
        table.Update(KeyStateTable.RightShift, isDown: true);

        table.Update(KeyStateTable.LeftShift, isDown: false);

        Assert.False(table.IsDown(KeyStateTable.LeftShift));
        Assert.True(table.IsDown(KeyStateTable.RightShift));
        Assert.True(table.IsDown(KeyStateTable.Shift));

        table.Update(KeyStateTable.RightShift, isDown: false);
        Assert.False(table.IsDown(KeyStateTable.Shift));
    }

    [Fact]
    public void TheGenericIndexIsVisibleInTheSnapshotToUnicodeExReceives()
    {
        var table = new KeyStateTable();
        table.Update(KeyStateTable.LeftShift, isDown: true);

        byte[] snapshot = table.Snapshot();

        Assert.Equal(KeyStateTable.Length, snapshot.Length);
        Assert.Equal(KeyStateTable.DownBit, (byte)(snapshot[KeyStateTable.Shift] & KeyStateTable.DownBit));
        Assert.Equal(KeyStateTable.DownBit, (byte)(snapshot[KeyStateTable.LeftShift] & KeyStateTable.DownBit));
    }

    [Fact]
    public void CapsLockToggleSurvivesTheKeyUp()
    {
        var table = new KeyStateTable();

        table.Update(KeyStateTable.CapsLock, isDown: true);
        table.Update(KeyStateTable.CapsLock, isDown: false);

        Assert.True(table.IsToggled(KeyStateTable.CapsLock));
        Assert.False(table.IsDown(KeyStateTable.CapsLock));

        table.Update(KeyStateTable.CapsLock, isDown: true);
        table.Update(KeyStateTable.CapsLock, isDown: false);

        Assert.False(table.IsToggled(KeyStateTable.CapsLock));
    }

    [Fact]
    public void AutoRepeatWhileATogglekeyIsHeldDoesNotFlickerTheToggle()
    {
        var table = new KeyStateTable();

        table.Update(KeyStateTable.CapsLock, isDown: true);
        table.Update(KeyStateTable.CapsLock, isDown: true);
        table.Update(KeyStateTable.CapsLock, isDown: true);

        Assert.True(table.IsToggled(KeyStateTable.CapsLock));
    }

    [Fact]
    public void SeededToggleStateIsWhatTheSessionInherited()
    {
        var table = new KeyStateTable();
        table.SeedToggle(KeyStateTable.CapsLock, isOn: true);

        Assert.True(table.IsToggled(KeyStateTable.CapsLock));
        Assert.Equal(
            KeyStateTable.ToggleBit,
            (byte)(table.Snapshot()[KeyStateTable.CapsLock] & KeyStateTable.ToggleBit));

        // The first physical press after an inherited "on" turns it off, as the OS does.
        table.Update(KeyStateTable.CapsLock, isDown: true);
        Assert.False(table.IsToggled(KeyStateTable.CapsLock));
    }

    [Fact]
    public void SeedingIgnoresKeysThatAreNotToggleKeys()
    {
        var table = new KeyStateTable();
        table.SeedToggle(KeyStateTable.LeftShift, isOn: true);

        Assert.False(table.IsToggled(KeyStateTable.LeftShift));
    }

    [Fact]
    public void CtrlCIsDetectableFromTheSideSpecificStream()
    {
        const int vkC = 0x43;
        var table = new KeyStateTable();

        table.Update(KeyStateTable.LeftControl, isDown: true);
        table.Update(vkC, isDown: true);

        Assert.True(table.IsDown(KeyStateTable.Control));
        Assert.False(table.IsDown(KeyStateTable.Shift));
        Assert.False(table.IsDown(KeyStateTable.Menu));
        Assert.False(table.IsWindowsDown());

        table.Update(vkC, isDown: false);
        table.Update(KeyStateTable.LeftControl, isDown: false);
        Assert.False(table.IsDown(KeyStateTable.Control));
    }

    [Fact]
    public void AltGrRaisesBothControlAndMenuJustAsWindowsReportsIt()
    {
        var table = new KeyStateTable();

        // A right-Alt press on a European layout arrives as left-Control plus right-Alt.
        table.Update(KeyStateTable.LeftControl, isDown: true);
        table.Update(KeyStateTable.RightMenu, isDown: true);

        Assert.True(table.IsDown(KeyStateTable.Control));
        Assert.True(table.IsDown(KeyStateTable.Menu));
    }

    [Fact]
    public void EitherWindowsKeyCountsAsTheWindowsModifier()
    {
        var table = new KeyStateTable();
        Assert.False(table.IsWindowsDown());

        table.Update(KeyStateTable.RightWindows, isDown: true);
        Assert.True(table.IsWindowsDown());

        table.Update(KeyStateTable.RightWindows, isDown: false);
        Assert.False(table.IsWindowsDown());
    }

    [Fact]
    public void OutOfRangeVirtualKeysAreIgnoredRatherThanThrowing()
    {
        var table = new KeyStateTable();

        table.Update(-1, isDown: true);
        table.Update(KeyStateTable.Length, isDown: true);
        table.Update(9999, isDown: true);

        Assert.False(table.IsDown(-1));
        Assert.False(table.IsDown(KeyStateTable.Length));
        Assert.Equal(new byte[KeyStateTable.Length], table.Snapshot());
    }

    [Fact]
    public void CopyToRejectsABufferTooSmallForTheTable()
    {
        var table = new KeyStateTable();

        Assert.Throws<ArgumentException>(() => table.CopyTo(new byte[KeyStateTable.Length - 1]));
    }

    [Fact]
    public void CopyToFillsTheCallersReusedBuffer()
    {
        var table = new KeyStateTable();
        table.Update(KeyStateTable.RightControl, isDown: true);

        var buffer = new byte[KeyStateTable.Length];
        table.CopyTo(buffer);

        Assert.Equal(KeyStateTable.DownBit, (byte)(buffer[KeyStateTable.Control] & KeyStateTable.DownBit));
    }
}
