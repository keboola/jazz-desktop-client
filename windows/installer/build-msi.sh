#!/usr/bin/env bash
#
# Builds the per-user Jazz Capture MSI on macOS or Linux, without a Windows machine.
#
#     windows/installer/build-msi.sh
#
# This is the optional path. The package that ships is the one build-msi.ps1 produces on Windows
# with the WiX v6 toolchain; this one exists because the client is developed on macOS, and being
# able to produce and inspect the installer where the code is written is worth a second authoring.
# Both are driven by Jazz.Version.props and both are checked by the same assertions, so the two
# packages cannot quietly describe different products - see wixl/product.wxs for the details and
# the two remaining differences.
#
# Requires the .NET 8 SDK and GNU msitools' wixl and wixl-heat:
#
#     macOS:  brew install msitools
#     Linux:  build msitools from source - Debian and Ubuntu ship the package without wixl.
#
# The MSI is NOT code signed. There is no certificate for this client, so Windows SmartScreen and
# Defender will warn the first time it is run.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
windows_dir="$(cd "$here/.." && pwd)"
artifacts_dir="$here/artifacts"
publish_dir="$artifacts_dir/publish/win-x64"
msi_path="$artifacts_dir/Jazz.msi"
tray_project="$windows_dir/Sources/JazzCapture/JazzCapture.csproj"
icon_source="$windows_dir/Sources/JazzCapture/Assets/tray-idle.ico"

for tool in dotnet wixl wixl-heat; do
    command -v "$tool" >/dev/null || {
        echo "ERROR: $tool is not on PATH. See the header of this script." >&2
        exit 1
    }
done

# The single source of truth for what is being built, read out of the same file the Windows build
# imports. Reading it here rather than repeating it keeps the two authorings from drifting apart.
read_property() {
    dotnet msbuild "$here/Jazz.Version.props" -getProperty:"$1" -nologo | tr -d '\r'
}

product_name="$(read_property JazzProductName)"
manufacturer="$(read_property JazzManufacturer)"
product_version="$(read_property JazzProductVersion)"
product_code="$(read_property JazzProductCode)"
upgrade_code="$(read_property JazzUpgradeCode)"
data_folder_name="$(read_property JazzDataFolderName)"
install_folder_name="$(read_property JazzInstallFolderName)"
run_key="$(read_property JazzRunKey)"
run_value_name="$(read_property JazzRunValueName)"
executable_name="$(read_property JazzExecutableName)"

echo "==> Publishing the self-contained win-x64 tray host"
# A publish into a dirty directory keeps files a previous build produced and this one does not,
# and the MSI would ship them. SatelliteResourceLanguages drops the WPF framework's translated
# resource assemblies; the client's own UI is English only.
rm -rf "$publish_dir"
dotnet publish "$tray_project" \
    --configuration Release \
    --runtime win-x64 \
    --self-contained true \
    -p:EnableWindowsTargeting=true \
    -p:SatelliteResourceLanguages=en \
    --output "$publish_dir" \
    --nologo

test -f "$publish_dir/$executable_name" || {
    echo "ERROR: the publish produced no $executable_name in $publish_dir." >&2
    exit 1
}

echo "==> Harvesting the payload"
files_wxs="$artifacts_dir/files.wxs"
# wixl-heat reads absolute paths on stdin and strips --prefix off them. The list is sorted so the
# component ids it derives come out in the same order on every machine; symbols are left out for
# the same reason the Windows build excludes them.
(
    cd "$publish_dir"
    find . -type f ! -name '*.pdb' | sed "s|^\./|$publish_dir/|"
) | LC_ALL=C sort | wixl-heat \
    --prefix "$publish_dir/" \
    --var var.PublishDir \
    --directory-ref INSTALLFOLDER \
    --component-group AppFiles \
    > "$files_wxs"

echo "==> Building the per-user MSI with wixl"
rm -f "$msi_path"
wixl -a x64 \
    -D "PublishDir=$publish_dir" \
    -D "IconSource=$icon_source" \
    -D "ProductName=$product_name" \
    -D "Manufacturer=$manufacturer" \
    -D "ProductVersion=$product_version" \
    -D "ProductCode=$product_code" \
    -D "UpgradeCode=$upgrade_code" \
    -D "DataFolderName=$data_folder_name" \
    -D "InstallFolderName=$install_folder_name" \
    -D "RunKey=$run_key" \
    -D "RunValueName=$run_value_name" \
    -D "ExecutableName=$executable_name" \
    -o "$msi_path" \
    "$here/wixl/product.wxs" "$files_wxs"

test -f "$msi_path" || {
    echo "ERROR: wixl reported success but produced no package at $msi_path." >&2
    exit 1
}

echo "==> $msi_path ($(du -h "$msi_path" | cut -f1), unsigned)"
