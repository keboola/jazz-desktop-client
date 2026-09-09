# Azure Windows test environment

This directory is the reviewable source of truth for the Windows 11 environment used to develop
and qualify the Jazz desktop client. It targets Azure subscription
`96fd974a-f038-4167-9966-0fd17d33e82d` and the existing `najlos-dev-jazz` resource group in West
Europe.

The VMs are intentionally private. Neither VM has a public IP address. Interactive access goes
through Azure Bastion, and outbound package downloads use an Azure NAT Gateway.

## Environment

| Resource | Purpose |
| --- | --- |
| `jazz-win-dev` | Windows 11 Enterprise 25H2 development VM, `Standard_D4as_v5`, 128 GiB OS disk |
| `jazz-win-qual` | Windows 11 Enterprise 25H2 clean qualification VM, `Standard_D2as_v5`, 128 GiB OS disk |
| `bas-jazz-windows-test-weu` | Browser-based RDP through Azure Bastion Basic |
| `ng-jazz-windows-test-weu` | Explicit outbound access for both VM subnets |
| `kvjazzwin96fd974a` | Separate break-glass administrator passwords for the two VMs |
| `vnet-jazz-windows-test-weu` | Dedicated Bastion, development, and qualification subnets |

Both VMs use the exact
`MicrosoftWindowsDesktop:windows-11:win11-25h2-ent:26200.9168.260809` image, Windows Client
licensing, Trusted Launch, Secure Boot, vTPM, boot diagnostics, and the `AADLoginForWindows`
extension. The development and qualification subnets have separate network security groups that
allow RDP only from the Bastion subnet and deny lateral virtual-network ingress.

The checked-in operator identity is deliberately explicit. Changing the operator requires a
reviewed update to `operatorObjectId` in both parameter files and to the UPN and Entra SID in
`development-packages.json` and `tests/Test-DevelopmentBootstrap.ps1`.

## Files

- `bootstrap.bicep` creates the Key Vault and grants the operator permission to manage secrets.
- `main.bicep` creates the network, Bastion, NAT, VM NICs, VMs, and access role assignments.
- `vm.bicep` owns the common Windows VM security and identity configuration.
- `bootstrap.bicepparam` and `main.bicepparam` contain the environment-specific, non-secret values.
- `development-packages.json` is the reviewed package and version policy for the development VM.
- `Stage-DevelopmentBootstrap.ps1` securely stages the initializer and registers its first-login
  scheduled task.
- `Initialize-DevelopmentTools.ps1` installs and verifies the approved development packages.
- `tests/validate-template.sh` validates the compiled Bicep resources and critical invariants.
- `tests/Test-DevelopmentBootstrap.ps1` validates the staged Windows bootstrap in the target VM.

## Prerequisites

- Azure CLI with Bicep support, `jq`, and OpenSSL.
- An authenticated Azure CLI session in the target tenant.
- Resource write permission in `najlos-dev-jazz`.
- `Microsoft.Authorization/roleAssignments/write` permission, such as Role Based Access Control
  Administrator or User Access Administrator, because both deployments create role assignments.

Set the target once in the shell used for the deployment:

```bash
subscription_id="96fd974a-f038-4167-9966-0fd17d33e82d"
resource_group="najlos-dev-jazz"
infra_dir="infrastructure/azure/windows-test-environment"

az account set --subscription "$subscription_id"
az account show --query '{subscriptionId:id, tenantId:tenantId}' --output table
az group show --name "$resource_group" --query id --output tsv
```

Do not continue unless the account output contains the intended subscription ID and the resource
ID ends with `/subscriptions/$subscription_id/resourceGroups/$resource_group`.

## Validate before deployment

Install Bicep if it is not already available, then run the template validator from the repository
root:

```bash
az bicep install
BICEP_PATH=/absolute/path/to/bicep "$infra_dir/tests/validate-template.sh"
```

`BICEP_PATH` must identify the Bicep executable itself, not `az`. The test compiles all templates
and parameter files into a temporary directory and asserts the private-network, VM security,
licensing, image, size, disk, Bastion, and Key Vault invariants.

Preview the bootstrap deployment before applying it:

```bash
az deployment group what-if \
  --resource-group "$resource_group" \
  --parameters "$infra_dir/bootstrap.bicepparam"
```

The main deployment preview cannot succeed until the Key Vault and both named secrets exist.

## Deploy

### 1. Create the Key Vault and operator role

```bash
az deployment group create \
  --name jazz-windows-bootstrap \
  --resource-group "$resource_group" \
  --parameters "$infra_dir/bootstrap.bicepparam" \
  --confirm-with-what-if \
  --proceed-if-no-change
```

Azure RBAC changes can take several minutes to propagate. Wait until the operator can create a Key
Vault secret before continuing.

### 2. Create independent break-glass passwords

The local administrator passwords are deployment-only recovery credentials. Entra ID is the normal
interactive login path. Generate each password independently and pipe it directly to Azure CLI;
never place a password in a parameter file, shell argument, shell history, repository file, or
command output.

```bash
set -o pipefail

{ openssl rand -base64 48 | tr -d '\n'; printf 'Aa1!'; } | \
  az keyvault secret set \
    --vault-name kvjazzwin96fd974a \
    --name windows-development-local-admin-password \
    --file /dev/stdin \
    --encoding utf-8 \
    --only-show-errors \
    --output none

{ openssl rand -base64 48 | tr -d '\n'; printf 'Aa1!'; } | \
  az keyvault secret set \
    --vault-name kvjazzwin96fd974a \
    --name windows-qualification-local-admin-password \
    --file /dev/stdin \
    --encoding utf-8 \
    --only-show-errors \
    --output none
```

Verify only the secret metadata, never the values:

```bash
az keyvault secret show \
  --vault-name kvjazzwin96fd974a \
  --name windows-development-local-admin-password \
  --query '{id:id, enabled:attributes.enabled}'

az keyvault secret show \
  --vault-name kvjazzwin96fd974a \
  --name windows-qualification-local-admin-password \
  --query '{id:id, enabled:attributes.enabled}'
```

### 3. Deploy the private Windows environment

```bash
az deployment group create \
  --name jazz-windows-main \
  --resource-group "$resource_group" \
  --parameters "$infra_dir/main.bicepparam" \
  --confirm-with-what-if \
  --proceed-if-no-change
```

The deployment uses incremental mode. Do not change it to complete mode: the resource group is
shared and complete mode can delete resources outside this environment.

### 4. Stage the development bootstrap

Run Command is single-flight for a VM. Confirm that no previous Run Command or extension operation
is still running before invoking another one.

```bash
initializer_base64="$(base64 < "$infra_dir/Initialize-DevelopmentTools.ps1" | tr -d '\n')"
initializer_sha256="$(shasum -a 256 "$infra_dir/Initialize-DevelopmentTools.ps1" | awk '{print $1}')"
configuration_base64="$(base64 < "$infra_dir/development-packages.json" | tr -d '\n')"
configuration_sha256="$(shasum -a 256 "$infra_dir/development-packages.json" | awk '{print $1}')"

az vm run-command invoke \
  --resource-group "$resource_group" \
  --name jazz-win-dev \
  --command-id RunPowerShellScript \
  --scripts @"$infra_dir/Stage-DevelopmentBootstrap.ps1" \
  --parameters \
    "InitializerBase64=$initializer_base64" \
    "InitializerSha256=$initializer_sha256" \
    "ConfigurationBase64=$configuration_base64" \
    "ConfigurationSha256=$configuration_sha256" \
  --only-show-errors

unset initializer_base64 initializer_sha256 configuration_base64 configuration_sha256
```

The stage script verifies both SHA-256 digests before writing, makes the staging directory writable
only by SYSTEM and local administrators while allowing Users read and execute access, and registers
an elevated first-login task.

Before the approved operator signs in, validate the staged files, ACL, task principal, retry policy,
target identity, and package plan through a second Run Command:

```bash
az vm run-command invoke \
  --resource-group "$resource_group" \
  --name jazz-win-dev \
  --command-id RunPowerShellScript \
  --scripts @"$infra_dir/tests/Test-DevelopmentBootstrap.ps1" \
  --only-show-errors
```

Wait for the command to report `Development bootstrap plan is valid.` before signing in. The test
must run before the first-login task succeeds because a successful initializer unregisters the task
that the staging test inspects.

Sign in to `jazz-win-dev` as the approved Entra operator. The task waits for WinGet, installs the
pinned catalog packages and Store-managed ChatGPT app, verifies the installed package versions,
installs the C# VS Code extension, and unregisters itself after success. GitHub and ChatGPT
authentication remain manual user actions; the bootstrap never handles their credentials.

Do not stage or run the development bootstrap on `jazz-win-qual`.

## Connect from macOS

The deployed Bastion SKU is Basic, so the supported macOS path is browser-based RDP:

1. Open the target VM in the Azure portal.
2. Select **Connect**, then **Bastion**.
3. Select RDP on port 3389.
4. Select Microsoft Entra ID authentication and connect.

The operator has the VM Administrator Login role on each VM and Reader access to the Bastion and
VM NICs. The `AADLoginForWindows` extension must have completed successfully before Entra login is
available.

Closing the Bastion browser tab disconnects the RDP client; it does not sign the Windows user out.
Windows normally keeps the disconnected session and its processes running. Reconnecting as the
same user returns to that session. Do not choose **Sign out** if the processes must remain alive,
and do not stop, deallocate, or reboot the VM. Software that requires an unlocked interactive
desktop, including screen capture and UI automation, can behave differently after RDP disconnects,
so keep the browser session connected for those tests.

Native RDP from macOS is not enabled by this template. It requires Bastion Standard with native
client tunneling, and native-client Entra RDP to an Entra-joined VM is limited to suitably joined
Windows clients. See the Microsoft documentation for
[browser RDP](https://learn.microsoft.com/en-us/azure/bastion/bastion-connect-vm-rdp-windows),
[Entra authentication](https://learn.microsoft.com/en-us/azure/bastion/bastion-entra-id-authentication),
and [native-client support](https://learn.microsoft.com/en-us/azure/bastion/native-client).

## Verify the deployed environment

Check the VM power and provisioning state without displaying credentials:

```bash
az vm get-instance-view \
  --resource-group "$resource_group" \
  --name jazz-win-dev \
  --query 'instanceView.statuses[].{code:code, displayStatus:displayStatus}' \
  --output table

az vm get-instance-view \
  --resource-group "$resource_group" \
  --name jazz-win-qual \
  --query 'instanceView.statuses[].{code:code, displayStatus:displayStatus}' \
  --output table
```

For each VM, verify in the Azure portal that:

- the OS is Windows 11 Enterprise 25H2 from the pinned image version;
- Trusted Launch, Secure Boot, and vTPM are enabled;
- no public IP is attached to the NIC;
- the `AADLoginForWindows` extension reports successful provisioning;
- browser RDP through Bastion works with the approved Entra identity.

On `jazz-win-dev`, the initializer verifies every installed catalog package version and VS Code
extension before removing its scheduled task. A remaining task means that installation has not
completed successfully; inspect its Task Scheduler history before retrying. Never copy a credential
into a test or its command line.

Treat `jazz-win-qual` as single-use for one qualification cycle. Before its first run, confirm that
Git, .NET, PowerShell 7, `uv`, GitHub CLI/Desktop, VS Code, and ChatGPT are absent. Install only the
Jazz candidate and evidence material required by that run. Before a later clean qualification,
recreate both the VM and its OS disk from the pinned image under a separately reviewed operation;
an incremental Bicep deployment does not erase state left by the previous run.

## Troubleshooting

- **Run Command reports another operation in progress:** do not submit repeated commands. Wait for
  the current VM extension operation to reach a terminal state and inspect its Azure Activity Log
  entry before retrying.
- **Entra ID is not offered in Bastion:** verify that `AADLoginForWindows` succeeded and that the
  operator still has the VM Administrator Login role on the target VM.
- **The first-login task is still present:** inspect Task Scheduler and the task history. It remains
  registered after a failed attempt so the configured retry policy can run. It removes itself only
  after all installations and version checks succeed.
- **WinGet is initially unavailable:** allow the bounded availability wait and scheduled retries to
  complete. Do not replace the pinned package policy with unreviewed download URLs.
- **A process disappears after disconnect:** confirm that the user was disconnected rather than
  signed out, that the VM remained running, and that no disconnected-session timeout policy is set.
  Interactive desktop software may still require a continuously connected session.

## Cost control and teardown

Deallocating the VMs stops their compute billing but does not remove disks, Bastion, NAT Gateway,
or public IP resources:

```bash
az vm deallocate --resource-group "$resource_group" --name jazz-win-dev
az vm deallocate --resource-group "$resource_group" --name jazz-win-qual
```

Start a VM explicitly before the next session:

```bash
az vm start --resource-group "$resource_group" --name jazz-win-dev
az vm start --resource-group "$resource_group" --name jazz-win-qual
```

There is intentionally no automated teardown command. `najlos-dev-jazz` is a shared resource group,
so never delete the resource group to remove this environment. Review retained test artifacts and
delete only the resources named by these parameter files, in dependency order, under a separately
approved teardown operation.

## References

- [Deploy Bicep files with Azure CLI](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-cli)
- [Azure Key Vault secret CLI](https://learn.microsoft.com/cli/azure/keyvault/secret)
- [Azure Bastion browser RDP](https://learn.microsoft.com/en-us/azure/bastion/bastion-connect-vm-rdp-windows)
- [Azure Bastion Entra authentication](https://learn.microsoft.com/en-us/azure/bastion/bastion-entra-id-authentication)
- [Azure RBAC role-assignment permissions](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-portal)
