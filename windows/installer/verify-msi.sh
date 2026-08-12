#!/usr/bin/env bash
#
# Dumps and asserts the contents of a Jazz Capture MSI on macOS or Linux, using GNU msitools.
#
#     windows/installer/verify-msi.sh [path/to/Jazz.msi]
#
# This is the shell twin of Verify-Msi.ps1 and checks the same claims. That is the whole reason the
# cross-platform build path is allowed to exist: the `wixl` package is only defensible if something
# mechanical says it is the same product as the Windows-built one, rather than a reviewer reading
# two files in two schemas and hoping.
#
# The four claims, in both scripts:
#
#     per-user        no elevation is required and nothing is written under HKLM
#     install path    the payload lands in %LOCALAPPDATA%\Jazz\App and nowhere else
#     start at login  one HKCU Run value points at the installed executable
#     data safety     uninstall removes the App directory and never %LOCALAPPDATA%\Jazz

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
msi="${1:-$here/artifacts/Jazz.msi}"

command -v msiinfo >/dev/null || { echo "ERROR: msiinfo is not on PATH (brew install msitools)." >&2; exit 1; }
test -f "$msi" || { echo "ERROR: no package to verify at $msi. Run build-msi.sh first." >&2; exit 1; }

read_property() {
    dotnet msbuild "$here/Jazz.Version.props" -getProperty:"$1" -nologo | tr -d '\r'
}

expected_version="$(read_property JazzProductVersion)"
expected_product_code="$(read_property JazzProductCode)"
expected_upgrade_code="$(read_property JazzUpgradeCode)"
expected_data_folder="$(read_property JazzDataFolderName)"
expected_install_folder="$(read_property JazzInstallFolderName)"
expected_run_key="$(read_property JazzRunKey)"
expected_run_value="$(read_property JazzRunValueName)"
expected_executable="$(read_property JazzExecutableName)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# msiinfo prints three header lines per table: column names, column types, then the table name and
# its key columns. Everything after that is data. The rows come out in the MSI's own IDT text
# format, which is CRLF-terminated, so the carriage returns are stripped here - otherwise every
# comparison against the last column on a line silently fails against an invisible character.
dump_table() {
    msiinfo export "$msi" "$1" 2>/dev/null | tail -n +4 | tr -d '\r' > "$work/$1" || true
    touch "$work/$1"
}

for table in Property Directory Registry Component File RemoveFile Upgrade Shortcut; do
    dump_table "$table"
done

failures=0
assert() { # claim, 0 for pass and anything else for fail, detail shown only on failure
    local claim="$1" ok="$2" detail="${3:-}"
    if [ "$ok" = "0" ]; then
        echo "  PASS  $claim"
    else
        echo "  FAIL  $claim${detail:+ -- $detail}"
        failures=$((failures + 1))
    fi
}

# Every check below is written as `ok=0; <test> || ok=1`. The `|| ok=1` is not decoration: a bare
# failing test under `set -e` would end the script at the first failed assertion instead of
# reporting all of them.
ok=0

property() { awk -F'\t' -v k="$1" '$1==k {print $2; exit}' "$work/Property"; }
long_name() { printf '%s' "$1" | cut -d: -f1 | awk -F'|' '{print $NF}'; }
directory_parent() { awk -F'\t' -v id="$1" '$1==id {print $2; exit}' "$work/Directory"; }
directory_name() { long_name "$(awk -F'\t' -v id="$1" '$1==id {print $3; exit}' "$work/Directory")"; }

# ------------------------------------------------------------------ the tables, for the record ---

echo "=== Property ==="
sed 's/^/  /' "$work/Property"

echo
echo "=== Directory (the named ones; harvested subdirectories are counted) ==="
grep -v -E '^(dir|cmp)[0-9A-F]{32}' "$work/Directory" | sed 's/^/  /' || true
echo "  ... $(grep -c -E '^dir[0-9A-F]{32}' "$work/Directory" || true) generated directory rows"

echo
echo "=== Registry ==="
sed 's/^/  /' "$work/Registry"

echo
echo "=== RemoveFile (what uninstall deletes beyond the installed files) ==="
sed 's/^/  /' "$work/RemoveFile"

echo
echo "=== Upgrade ==="
sed 's/^/  /' "$work/Upgrade"

echo
echo "=== Shortcut ==="
sed 's/^/  /' "$work/Shortcut"

echo
echo "=== File ==="
echo "  $(wc -l < "$work/File" | tr -d ' ') files"

# ----------------------------------------------------------------------------- the assertions ---

echo
echo "=== Assertions ==="

# --- identity and the upgrade rule ---------------------------------------------------------------
ok=0; [ "$(property ProductVersion)" = "$expected_version" ] || ok=1
assert "ProductVersion is $expected_version" "$ok" "found '$(property ProductVersion)'"

ok=0; [ "$(property ProductCode)" = "{$expected_product_code}" ] || ok=1
assert "ProductCode is derived from the version" "$ok" "found '$(property ProductCode)'"

ok=0; [ "$(property UpgradeCode)" = "{$expected_upgrade_code}" ] || ok=1
assert "UpgradeCode is the stable product identity" "$ok" "found '$(property UpgradeCode)'"

ok=0; grep -q "^{$expected_upgrade_code}" "$work/Upgrade" || ok=1
assert "a major-upgrade rule replaces older builds" "$ok" \
    "the Upgrade table has no row for the UpgradeCode, so a newer build would install beside the old one"

# --- per-user, no elevation ------------------------------------------------------------------------
# Summary word-count bit 3 (value 8) means "elevated privileges are not required to install".
word_count="$(msiinfo suminfo "$msi" | awk '/^Source:/ {print $2}')"
echo "  (summary word count = $word_count)"
ok=0; [ $(( word_count & 8 )) -eq 8 ] || ok=1
assert "the package declares that it needs no elevation" "$ok" "word count $word_count"

ok=0; [ "$(property ALLUSERS)" != "1" ] || ok=1
assert "ALLUSERS is not set to a per-machine install" "$ok" "ALLUSERS='$(property ALLUSERS)'"

hklm_rows="$(awk -F'\t' '$2=="2"' "$work/Registry" || true)"
ok=0; [ -z "$hklm_rows" ] || ok=1
assert "nothing is written under HKLM" "$ok" "$(printf '%s' "$hklm_rows" | grep -c . || true) HKLM rows"

# Component attribute bit 256 is msidbComponentAttributes64bit. The payload is win-x64, so a
# component without it would be subject to the WOW64 file and registry redirections.
not_64bit="$(awk -F'\t' 'int($4) % 512 < 256 {print $1}' "$work/Component" || true)"
ok=0; [ -z "$not_64bit" ] || ok=1
assert "every component is marked 64-bit" "$ok" \
    "$(printf '%s' "$not_64bit" | grep -c . || true) components are not"

roots="$(awk -F'\t' '
    { parent[$1] = $2 }
    END {
        for (id in parent) {
            current = id
            for (guard = 0; guard < 64; guard++) {
                up = parent[current]
                if (up == "" || up == "TARGETDIR" || up == current) break
                current = up
            }
            print current
        }
    }' "$work/Directory" | sort -u)"
stray_roots="$(printf '%s\n' "$roots" | grep -v -E '^(TARGETDIR|LocalAppDataFolder|ProgramMenuFolder)$' || true)"
ok=0; [ -z "$stray_roots" ] || ok=1
assert "every directory is rooted in the user's profile" "$ok" "stray roots: $(printf '%s' "$stray_roots" | tr '\n' ' ')"

# --- the install path --------------------------------------------------------------------------
ok=0; [ "$(directory_parent INSTALLFOLDER)" = "JazzDataFolder" ] || ok=1
assert "the payload directory is a child of the data root" "$ok" "parent is '$(directory_parent INSTALLFOLDER)'"

ok=0; [ "$(directory_name INSTALLFOLDER)" = "$expected_install_folder" ] || ok=1
assert "the payload directory is named $expected_install_folder" "$ok" "named '$(directory_name INSTALLFOLDER)'"

ok=0
{ [ "$(directory_parent JazzDataFolder)" = "LocalAppDataFolder" ] &&
  [ "$(directory_name JazzDataFolder)" = "$expected_data_folder" ]; } || ok=1
assert "the data root is %LOCALAPPDATA%\\$expected_data_folder" "$ok" \
    "parent '$(directory_parent JazzDataFolder)', name '$(directory_name JazzDataFolder)'"

exe_rows="$(awk -F'\t' -v exe="$expected_executable" '{ n = $3; sub(/^.*\|/, "", n); if (n == exe) print }' "$work/File")"
exe_row_count="$(printf '%s' "$exe_rows" | grep -c . || true)"
ok=0; [ "$exe_row_count" = "1" ] || ok=1
assert "the tray host executable is in the payload" "$ok" \
    "$exe_row_count files named $expected_executable"

exe_component="$(printf '%s' "$exe_rows" | awk -F'\t' '{print $2; exit}')"
exe_directory="$(awk -F'\t' -v c="$exe_component" '$1==c {print $3; exit}' "$work/Component")"
exe_under_installfolder=1
current="$exe_directory"
for _ in 1 2 3 4 5 6 7 8; do
    [ -z "$current" ] && break
    if [ "$current" = "INSTALLFOLDER" ]; then exe_under_installfolder=0; break; fi
    current="$(directory_parent "$current")"
done
assert "the tray host installs into the payload directory" "$exe_under_installfolder" \
    "its component installs into '$exe_directory'"

# Nothing may be installed straight into the data root: that directory belongs to the user's
# recordings, and a file the installer owns there would be a file uninstall deletes there.
components_in_data_root="$(awk -F'\t' '$3=="JazzDataFolder" || $3=="LocalAppDataFolder" {print $1}' "$work/Component" || true)"
ok=0; [ -z "$components_in_data_root" ] || ok=1
assert "no component installs into the data root itself" "$ok" \
    "$(printf '%s' "$components_in_data_root" | tr '\n' ' ')"

# --- start at login --------------------------------------------------------------------------------
# The key is passed through the environment rather than `awk -v`, which would interpret the
# backslashes in Software\Microsoft\Windows\... as escape sequences and match nothing.
run_rows="$(JAZZ_RUN_KEY="$expected_run_key" awk -F'\t' '$3==ENVIRON["JAZZ_RUN_KEY"]' "$work/Registry" || true)"
run_row_count="$(printf '%s' "$run_rows" | grep -c . || true)"
ok=0; [ "$run_row_count" = "1" ] || ok=1
assert "exactly one Run value is registered" "$ok" "$run_row_count rows under $expected_run_key"

run_root="$(printf '%s' "$run_rows" | awk -F'\t' '{print $2; exit}')"
ok=0; [ "$run_root" = "1" ] || ok=1
assert "the Run value is under HKCU" "$ok" "Root=$run_root"

run_name="$(printf '%s' "$run_rows" | awk -F'\t' '{print $4; exit}')"
ok=0; [ "$run_name" = "$expected_run_value" ] || ok=1
assert "the Run value is named $expected_run_value" "$ok" "named '$run_name'"

run_value="$(printf '%s' "$run_rows" | awk -F'\t' '{print $5; exit}')"
ok=0; [ "$run_value" = "\"[INSTALLFOLDER]$expected_executable\"" ] || ok=1
assert "the Run value launches the installed executable" "$ok" "value '$run_value'"

# --- uninstall leaves captured data alone ------------------------------------------------------------
removes_install_folder="$(awk -F'\t' '$4=="INSTALLFOLDER" {print $1}' "$work/RemoveFile" || true)"
ok=0; [ -n "$removes_install_folder" ] || ok=1
assert "uninstall removes the payload directory" "$ok" \
    "no RemoveFile row targets INSTALLFOLDER, so an empty %LOCALAPPDATA%\\$expected_data_folder\\$expected_install_folder would be left behind"

# The claim this repository cannot afford to get wrong. Recordings, queued archives and the settings
# document live directly in %LOCALAPPDATA%\Jazz; if uninstall ever lists that directory, it deletes
# evidence the user has not exported yet.
removes_data_root="$(awk -F'\t' '$4=="JazzDataFolder" || $4=="LocalAppDataFolder" {print $1}' "$work/RemoveFile" || true)"
ok=0; [ -z "$removes_data_root" ] || ok=1
assert "uninstall never touches the capture data root" "$ok" \
    "$(printf '%s' "$removes_data_root" | tr '\n' ' ')"

removes_start_menu_root="$(awk -F'\t' '$4=="ProgramMenuFolder" {print $1}' "$work/RemoveFile" || true)"
ok=0; [ -z "$removes_start_menu_root" ] || ok=1
assert "uninstall never removes the shared Start Menu folder" "$ok" \
    "$(printf '%s' "$removes_start_menu_root" | tr '\n' ' ')"

# ------------------------------------------------------------------------------------------------

echo
if [ "$failures" -gt 0 ]; then
    echo "$failures assertion(s) failed."
    exit 1
fi

echo "The package is per-user, installs into %LOCALAPPDATA%\\$expected_data_folder\\$expected_install_folder, starts at login through HKCU, and leaves captured data alone on uninstall."
echo "It is unsigned: SmartScreen will warn on first run."
