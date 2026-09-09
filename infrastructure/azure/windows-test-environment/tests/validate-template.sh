#!/usr/bin/env bash

set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
infra_dir="$(cd "$test_dir/.." && pwd)"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/jazz-azure-template.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT
bicep_cli="${BICEP_PATH:-bicep}"

"$bicep_cli" build "$infra_dir/bootstrap.bicep" --outfile "$scratch_dir/bootstrap.json"
"$bicep_cli" build "$infra_dir/main.bicep" --outfile "$scratch_dir/main.json"
"$bicep_cli" build "$infra_dir/vm.bicep" --outfile "$scratch_dir/vm.json"
"$bicep_cli" build-params "$infra_dir/bootstrap.bicepparam" --outfile "$scratch_dir/bootstrap.parameters.json"
"$bicep_cli" build-params "$infra_dir/main.bicepparam" --outfile "$scratch_dir/main.parameters.json"

jq -e '
  ([.resources[] | select(.type == "Microsoft.KeyVault/vaults")] | length == 1)
  and ([.resources[] | select(.type == "Microsoft.Authorization/roleAssignments")] | length == 1)
  and (([.resources[] | select(.type == "Microsoft.KeyVault/vaults")][0].properties)
    | .enableRbacAuthorization == true
      and .enabledForTemplateDeployment == true
      and .enablePurgeProtection == true)
' "$scratch_dir/bootstrap.json" >/dev/null

jq -e '
  ([.resources[] | select(.type == "Microsoft.Network/virtualNetworks")] | length == 1)
  and ([.resources[] | select(.type == "Microsoft.Network/natGateways")] | length == 1)
  and ([.resources[] | select(.type == "Microsoft.Network/bastionHosts")] | length == 1)
  and ([.resources[] | select(.type == "Microsoft.Network/networkInterfaces")] | length == 2)
  and ([.resources[] | select(.type == "Microsoft.Resources/deployments")] | length == 2)
  and ([.resources[] | select(.type == "Microsoft.Network/publicIPAddresses")] | length == 2)
  and all(
    .resources[] | select(.type == "Microsoft.Network/networkInterfaces");
    all(.properties.ipConfigurations[]; (.properties | has("publicIPAddress") | not))
  )
' "$scratch_dir/main.json" >/dev/null

jq -e '
  (.parameters.breakGlassAdminPassword.type == "securestring")
  and ([.resources[] | select(.type == "Microsoft.Compute/virtualMachines")] | length == 1)
  and ([.resources[] | select(.type == "Microsoft.Compute/virtualMachines/extensions")] | length == 1)
  and ([.resources[] | select(.type == "Microsoft.Authorization/roleAssignments")] | length == 1)
  and (([.resources[] | select(.type == "Microsoft.Compute/virtualMachines/extensions")][0].properties)
    | has("enableAutomaticUpgrade") | not)
  and (([.resources[] | select(.type == "Microsoft.Compute/virtualMachines")][0])
    | .identity.type == "SystemAssigned"
      and .properties.licenseType == "Windows_Client"
      and .properties.securityProfile.securityType == "TrustedLaunch"
      and .properties.securityProfile.uefiSettings.secureBootEnabled == true
      and .properties.securityProfile.uefiSettings.vTpmEnabled == true
      and .properties.diagnosticsProfile.bootDiagnostics.enabled == true
      and (.properties.osProfile.windowsConfiguration.patchSettings | has("assessmentMode") | not))
' "$scratch_dir/vm.json" >/dev/null

jq -e '
  .parameters.location.value == "westeurope"
  and (.parameters.developmentBreakGlassCredentialName.value != .parameters.qualificationBreakGlassCredentialName.value)
  and .parameters.developmentVmSize.value == "Standard_D4as_v5"
  and .parameters.qualificationVmSize.value == "Standard_D2as_v5"
  and .parameters.imagePublisher.value == "MicrosoftWindowsDesktop"
  and .parameters.imageOffer.value == "windows-11"
  and .parameters.imageSku.value == "win11-25h2-ent"
  and .parameters.imageVersion.value == "26200.9168.260809"
  and .parameters.osDiskSizeGiB.value == 128
  and .parameters.bastionSku.value == "Basic"
' "$scratch_dir/main.parameters.json" >/dev/null

echo "Azure Windows test environment templates are valid."
