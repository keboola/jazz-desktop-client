#!/bin/sh
# One TLC run per invariant/configuration; logs in out/ (gitignored). Each run is seconds.
set -e
cd "$(dirname "$0")"
R=./run_one.sh

tr() { # tr NAME INVARIANTS ReEnroll Disconnect Crash
  $R TokenRenewal "$1" "$2" "    EnableReEnroll = $3
    EnableDisconnect = $4
    EnableCrash = $5
    MaxSteps = 14"
}
echo "== TokenRenewal (DeviceTokenRenewer x Keychain x re-enrollment x disconnect) =="
tr TR_clean                       "VaultTokenWasIssued" TRUE TRUE TRUE
tr TR_renewal_only                "KeychainGenerationMonotone NoWriteAfterRevoke ProjectionsConsistentWithVault" FALSE FALSE FALSE
tr TR_KeychainGenerationMonotone  KeychainGenerationMonotone TRUE  FALSE FALSE
tr TR_NoWriteAfterRevoke          NoWriteAfterRevoke         FALSE TRUE  FALSE
tr TR_ProjectionsConsistentWithVault ProjectionsConsistentWithVault FALSE FALSE TRUE
