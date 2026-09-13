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
# The five claims, in both scripts:
#
#     per-user        no elevation is required and nothing is written under HKLM
#     install path    the payload lands in %LOCALAPPDATA%\Jazz\App and nowhere else
#     start at login  one HKCU Run value points at the installed executable
#     data safety     uninstall removes the App directory and never %LOCALAPPDATA%\Jazz
#     capture policy  one HKCU installer preference is remembered, defaults to "0", is written as
#                     REG_SZ, and the package contains zero custom actions (#60 slice 2)

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
msi="${1:-$here/artifacts/Jazz.msi}"

command -v msiinfo >/dev/null || { echo "ERROR: msiinfo is not on PATH (brew install msitools)." >&2; exit 1; }
test -f "$msi" || { echo "ERROR: no package to verify at $msi. Run build-msi.sh first." >&2; exit 1; }

read_property() {
    dotnet msbuild "$here/Jazz.Version.props" -getProperty:"$1" -nologo | tr -d '\r'
}

expected_product_name="$(read_property JazzProductName)"
expected_version="$(read_property JazzProductVersion)"
expected_product_code="$(read_property JazzProductCode)"
expected_upgrade_code="$(read_property JazzUpgradeCode)"
expected_data_folder="$(read_property JazzDataFolderName)"
expected_install_folder="$(read_property JazzInstallFolderName)"
expected_run_key="$(read_property JazzRunKey)"
expected_run_value="$(read_property JazzRunValueName)"
expected_executable="$(read_property JazzExecutableName)"
expected_start_menu_folder="$(read_property JazzStartMenuFolderName)"
expected_shortcut_name="$(read_property JazzShortcutName)"
expected_manufacturer="$(read_property JazzManufacturer)"
expected_policy_value="$(read_property JazzPolicyValueName)"
expected_policy_property="$(read_property JazzPolicyPropertyName)"

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

for table in Property Directory Registry Component File RemoveFile Upgrade Shortcut InstallExecuteSequence CustomAction AppSearch RegLocator LaunchCondition FeatureComponents; do
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
echo "=== InstallExecuteSequence ==="
sed 's/^/  /' "$work/InstallExecuteSequence"

echo
echo "=== CustomAction ==="
sed 's/^/  /' "$work/CustomAction"

echo
echo "=== AppSearch / RegLocator (the remembered installer preference) ==="
sed 's/^/  appsearch /' "$work/AppSearch"
sed 's/^/  reglocator /' "$work/RegLocator"

echo
echo "=== LaunchCondition ==="
sed 's/^/  /' "$work/LaunchCondition"

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
ok=0; [ "$(property ProductName)" = "$expected_product_name" ] || ok=1
assert "ProductName is $expected_product_name" "$ok" "found '$(property ProductName)'"

ok=0; [ "$(property ProductVersion)" = "$expected_version" ] || ok=1
assert "ProductVersion is $expected_version" "$ok" "found '$(property ProductVersion)'"

ok=0; [ "$(property ProductCode)" = "{$expected_product_code}" ] || ok=1
assert "ProductCode is derived from the version" "$ok" "found '$(property ProductCode)'"

ok=0; [ "$(property UpgradeCode)" = "{$expected_upgrade_code}" ] || ok=1
assert "UpgradeCode is the stable product identity" "$ok" "found '$(property UpgradeCode)'"

sequence_of() {
    awk -F '\t' -v action="$1" '$1 == action { print $3; exit }' "$work/InstallExecuteSequence"
}
install_initialize="$(sequence_of InstallInitialize)"
remove_existing="$(sequence_of RemoveExistingProducts)"
install_finalize="$(sequence_of InstallFinalize)"
ok=0
if [ -n "$install_initialize" ] && [ -n "$remove_existing" ] && [ -n "$install_finalize" ] &&
   [ "$install_initialize" -lt "$remove_existing" ] && [ "$remove_existing" -lt "$install_finalize" ]; then
    ok=0
else
    ok=1
fi
assert "RemoveExistingProducts is inside the rollback transaction" "$ok" \
    "expected InstallInitialize < RemoveExistingProducts < InstallFinalize"

ok=0
if grep -Eqi 'JAZZ_TEST_ONLY|JazzTestOnly|FailAfterRemoveExisting' \
    "$work/Property" "$work/CustomAction" "$work/InstallExecuteSequence"; then ok=1; fi
assert "release package contains no test-only rollback hook" "$ok"

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

ok=0
{ [ "$(directory_parent ShortcutFolder)" = "ProgramMenuFolder" ] &&
  [ "$(directory_name ShortcutFolder)" = "$expected_start_menu_folder" ]; } || ok=1
assert "the Start Menu folder is $expected_start_menu_folder" "$ok" \
    "parent '$(directory_parent ShortcutFolder)', name '$(directory_name ShortcutFolder)'"

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

# --- the deployable installer preference (#60 slice 2) -------------------------------------------
expected_policy_key="Software\\$expected_manufacturer\\$expected_data_folder\\Policy"

ok=0; [ "$(property "$expected_policy_property")" = "0" ] || ok=1
assert "$expected_policy_property carries the no-opinion default" "$ok" \
    "found '$(property "$expected_policy_property")'"

ok=0
printf ';%s;' "$(property SecureCustomProperties)" | grep -q ";$expected_policy_property;" || ok=1
assert "$expected_policy_property is a secure custom property" "$ok" \
    "SecureCustomProperties='$(property SecureCustomProperties)'"

app_search_rows="$(JAZZ_POLICY_PROPERTY="$expected_policy_property" \
    awk -F'\t' '$1==ENVIRON["JAZZ_POLICY_PROPERTY"]' "$work/AppSearch" || true)"
app_search_count="$(printf '%s' "$app_search_rows" | grep -c . || true)"
ok=0; [ "$app_search_count" = "1" ] || ok=1
assert "exactly one AppSearch row remembers the installer preference" "$ok" "$app_search_count rows"

policy_signature="$(printf '%s' "$app_search_rows" | awk -F'\t' '{print $2; exit}')"
reg_rows="$(JAZZ_SIG="$policy_signature" awk -F'\t' '$1==ENVIRON["JAZZ_SIG"]' "$work/RegLocator" || true)"
reg_count="$(printf '%s' "$reg_rows" | grep -c . || true)"
reg_root="$(printf '%s' "$reg_rows" | awk -F'\t' '{print $2; exit}')"
reg_key="$(printf '%s' "$reg_rows" | awk -F'\t' '{print $3; exit}')"
reg_name="$(printf '%s' "$reg_rows" | awk -F'\t' '{print $4; exit}')"
reg_type="$(printf '%s' "$reg_rows" | awk -F'\t' '{print $5; exit}')"
ok=0
{ [ "$reg_count" = "1" ] && [ "$reg_root" = "1" ] && [ "$reg_key" = "$expected_policy_key" ] &&
  [ "$reg_name" = "$expected_policy_value" ] && [ "$reg_type" = "18" ]; } || ok=1
# RegLocator type 18 is raw (2) | 64-bit (16). `wixl -a x64` and InstallerPlatform=x64 both produce
# it, which is what makes the two databases comparable at all.
assert "the search reads the HKCU policy value in the 64-bit view" "$ok" \
    "count=$reg_count root=$reg_root key='$reg_key' name='$reg_name' type=$reg_type"

hklm_searches="$(awk -F'\t' '$2=="2"' "$work/RegLocator" || true)"
ok=0; [ -z "$hklm_searches" ] || ok=1
assert "nothing is read from HKLM either" "$ok" "$(printf '%s' "$hklm_searches" | grep -c . || true) rows"

policy_rows="$(JAZZ_POLICY_KEY="$expected_policy_key" \
    awk -F'\t' '$3==ENVIRON["JAZZ_POLICY_KEY"]' "$work/Registry" || true)"
policy_count="$(printf '%s' "$policy_rows" | grep -c . || true)"
policy_id="$(printf '%s' "$policy_rows" | awk -F'\t' '{print $1; exit}')"
policy_root="$(printf '%s' "$policy_rows" | awk -F'\t' '{print $2; exit}')"
policy_name="$(printf '%s' "$policy_rows" | awk -F'\t' '{print $4; exit}')"
policy_written="$(printf '%s' "$policy_rows" | awk -F'\t' '{print $5; exit}')"
policy_component="$(printf '%s' "$policy_rows" | awk -F'\t' '{print $6; exit}')"
ok=0
{ [ "$policy_count" = "1" ] && [ "$policy_root" = "1" ] &&
  [ "$policy_name" = "$expected_policy_value" ] &&
  [ "$policy_written" = "[$expected_policy_property]" ]; } || ok=1
# No '#', '#%' or '[~]' prefix: the value column is written as REG_SZ, which is one of the only two
# registry kinds CaptureAtLaunchPolicyStore accepts.
assert "exactly one REG_SZ row writes the installer preference" "$ok" \
    "count=$policy_count root=$policy_root name='$policy_name' value='$policy_written'"

# Component columns: Component, ComponentId, Directory_, Attributes, Condition, KeyPath.
policy_directory="$(JAZZ_CMP="$policy_component" awk -F'\t' '$1==ENVIRON["JAZZ_CMP"] {print $3; exit}' "$work/Component")"
policy_keypath="$(JAZZ_CMP="$policy_component" awk -F'\t' '$1==ENVIRON["JAZZ_CMP"] {print $6; exit}' "$work/Component")"
ok=0
{ [ "$policy_directory" = "INSTALLFOLDER" ] && [ "$policy_keypath" = "$policy_id" ]; } || ok=1
assert "the policy component installs into the payload directory and is its key path" "$ok" \
    "directory '$policy_directory', keypath '$policy_keypath' vs registry id '$policy_id'"

ok=0; [ ! -s "$work/CustomAction" ] || ok=1
assert "the package contains no custom actions at all" "$ok" \
    "$(grep -c . "$work/CustomAction" || true) CustomAction rows"

launch_condition_count="$(grep -c . "$work/LaunchCondition" || true)"
launch_condition="$(awk -F'\t' '{print $1; exit}' "$work/LaunchCondition")"
ok=0
{ [ "$launch_condition_count" = "1" ] && [ "$launch_condition" = "NOT WIX_DOWNGRADE_DETECTED" ]; } || ok=1
assert "the only launch condition is the downgrade rule" "$ok" \
    "$launch_condition_count rows, first '$launch_condition'"

policy_feature="$(JAZZ_CMP="$policy_component" \
    awk -F'\t' '$2==ENVIRON["JAZZ_CMP"] {print $1; exit}' "$work/FeatureComponents")"
ok=0; [ -n "$policy_feature" ] || ok=1
assert "the policy component belongs to an installed feature" "$ok" \
    "no FeatureComponents row, so the value would never be written"

# --- Start Menu discoverability --------------------------------------------------------------------
shortcut_rows="$(awk -F'\t' '$2=="ShortcutFolder" {print}' "$work/Shortcut" || true)"
shortcut_row_count="$(printf '%s' "$shortcut_rows" | grep -c . || true)"
ok=0; [ "$shortcut_row_count" = "1" ] || ok=1
assert "exactly one Start Menu shortcut is installed" "$ok" "$shortcut_row_count rows"

shortcut_name="$(printf '%s' "$shortcut_rows" | awk -F'\t' '{ n = $3; sub(/^.*\|/, "", n); print n; exit}')"
ok=0; [ "$shortcut_name" = "$expected_shortcut_name" ] || ok=1
assert "the shortcut is named $expected_shortcut_name" "$ok" "named '$shortcut_name'"

shortcut_target="$(printf '%s' "$shortcut_rows" | awk -F'\t' '{print $5; exit}')"
shortcut_workdir="$(printf '%s' "$shortcut_rows" | awk -F'\t' '{print $12; exit}')"
ok=0
{ [ "$shortcut_target" = "[INSTALLFOLDER]$expected_executable" ] &&
  [ "$shortcut_workdir" = "INSTALLFOLDER" ]; } || ok=1
assert "the shortcut launches the configured executable" "$ok" \
    "target '$shortcut_target', workdir '$shortcut_workdir'"

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

echo "The package is per-user, installs into %LOCALAPPDATA%\\$expected_data_folder\\$expected_install_folder, starts at login through HKCU, remembers the installer preference as REG_SZ with zero custom actions, and leaves captured data alone on uninstall."
echo "It is unsigned: SmartScreen will warn on first run."
