#!/usr/bin/env bash
set -euo pipefail

# Step 1: deploy and initialize the contracts. Self-contained: loads and validates every file
# it needs, without relying on a preloaded caller environment.
# Usage: script/deploy/11_deploy.sh <network>
# This step writes addresses.action.params, which 21_check.sh and 31_verify.sh load on their own.

network="${1:?usage: script/deploy/11_deploy.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$PROJECT_ROOT/script/network/$network"

# Parameter file loader: 1e17 / 1_000_000 style literals are expanded to decimal on load (params.sh).
source "$SCRIPT_DIR/params.sh"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

# An abnormal previous exit may leave a hidden address temp file behind; only this module's temp
# pattern is removed, never the real address file.
rm -f "$NETWORK_DIR/.addresses.action.params."*

# Required configuration. addresses.core.params holds the addresses already deployed by the
# dependency (core) and is copied over after that deployment; .account provides the keystore account
# and password and is mandatory (local chains also sign through the keystore, never --unlocked).
for config in network.params addresses.core.params action.params .account; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done

# Parameters come from files only: clear every key the files define, so a value exported by the
# caller cannot override a file value. GROUP_ACTION_SPLITS is the one key whose absence would change
# behaviour silently (an empty value is legal and means "no tiers"), so its presence is asserted
# against the file itself, never against the variable - an inherited value could satisfy that.
params_require_keys "$NETWORK_DIR/action.params" GROUP_ACTION_SPLITS || exit 1

params_unset_all "$NETWORK_DIR/network.params" "$NETWORK_DIR/addresses.core.params" \
    "$NETWORK_DIR/action.params"

env_password="${KEYSTORE_PASSWORD:-}"
params_load "$NETWORK_DIR/network.params"
params_load "$NETWORK_DIR/addresses.core.params"
params_load "$NETWORK_DIR/action.params"
# .account is plain-sourced: the password may contain "#" and must not go through parameter expansion.
set -a
source "$NETWORK_DIR/.account"
set +a

# An empty KEYSTORE_PASSWORD line in .account must not clear a password exported by the entrypoint
# (that would prompt a second time).
[ -n "${KEYSTORE_PASSWORD:-}" ] || KEYSTORE_PASSWORD="$env_password"

[ -n "${KEYSTORE_ACCOUNT:-}" ] && [ -n "${ACCOUNT_ADDRESS:-}" ] \
    || { echo "Error: KEYSTORE_ACCOUNT / ACCOUNT_ADDRESS is not set in $NETWORK_DIR/.account" >&2; exit 1; }

# Verify the actual chain; being able to reach the RPC is not enough.
ACTUAL_CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL") || exit 1
if [ "$ACTUAL_CHAIN_ID" != "$CHAIN_ID" ]; then
    echo "Error: RPC chain ID $ACTUAL_CHAIN_ID does not match configured CHAIN_ID $CHAIN_ID"
    exit 1
fi

# Keystore password: no prompt when already set (non-interactive use), otherwise read via the macOS
# dialog.
if [ -z "${KEYSTORE_PASSWORD:-}" ]; then
    if ! command -v osascript >/dev/null 2>&1; then
        echo "Error: KEYSTORE_PASSWORD is empty and osascript is unavailable; set it in $NETWORK_DIR/.account for non-interactive use." >&2
        exit 1
    fi
    KEYSTORE_PASSWORD="$(osascript <<APPLESCRIPT
text returned of (display dialog "Enter keystore password for $KEYSTORE_ACCOUNT:" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK")
APPLESCRIPT
)"
fi

echo "=== Deploying Action Contracts to $network ==="
echo "  RPC_URL: $RPC_URL"
echo "  CHAIN_ID: $CHAIN_ID"

LIBRARY_NAMES="GroupActionJoin GroupActionManager GroupActionVerify GroupRecipients"

library_address_field() {
    printf '%s_LIBRARY_ADDRESS' \
        "$(printf '%s' "$1" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' | tr '[:lower:]' '[:upper:]')"
}

require_address() {
    local field=$1
    local source=$2
    if [[ ! ${!field:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field:-} = 0x0000000000000000000000000000000000000000 ]]; then
        echo "Error: Missing or invalid $field in $source"
        exit 1
    fi
}

require_contract_addresses() {
    local field
    for field in ACTION_TARGET_ADDRESS LP_EXECUTOR_ADDRESS \
        GROUP_ACTION_EXECUTOR_ADDRESS GROUP_SERVICE_EXECUTOR_ADDRESS; do
        require_address "$field" "deployment log"
    done
}

require_library_addresses() {
    local name
    for name in $LIBRARY_NAMES; do
        require_address "$(library_address_field "$name")" "broadcast artifact"
    done
}

# Prepare the deployment log and the password file. Once broadcast, any later validation failure
# means "the contracts are on chain but the addresses were not recorded": the log and the artifact
# path must survive for manual recovery; a pre-broadcast failure only removes this run's temp files
# and never claims anything reached the chain. The password goes to forge through a temp file
# because --password would put the plaintext into the process arguments, readable by every local
# user. The trap is installed before the password is written, so a failing chmod/printf leaks
# nothing.
DEPLOY_LOG=$(mktemp)
PASSWORD_FILE=$(mktemp)
ADDRESS_TMP="$NETWORK_DIR/.addresses.action.params.$$"
DEPLOY_SAVED=0
DEPLOY_ATTEMPTED=0
trap 'rm -f "$ADDRESS_TMP" "$PASSWORD_FILE"
if [ "$DEPLOY_SAVED" = 1 ] || [ "$DEPLOY_ATTEMPTED" = 0 ]; then
    rm -f "$DEPLOY_LOG"
else
    echo "  Addresses were not saved; contracts may already be on chain." >&2
    echo "  Deployment log: $DEPLOY_LOG" >&2
    echo "  Broadcast artifact: $PROJECT_ROOT/broadcast/DeployAction.s.sol/${CHAIN_ID:-unknown}/run-latest.json" >&2
fi' EXIT
chmod 600 "$PASSWORD_FILE"
printf '%s' "$KEYSTORE_PASSWORD" > "$PASSWORD_FILE"

# GroupActionExecutor splits come from action.params as a comma-separated list; empty means an empty
# array.
SPLITS_LITERAL="[${GROUP_ACTION_SPLITS:-}]"

# Build the forge script command: keystore signing (same on local chains, never --unlocked).
FORGE_CMD=(forge script script/deploy/DeployAction.s.sol:DeployAction --sig "run(uint256[])" "$SPLITS_LITERAL" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --account "$KEYSTORE_ACCOUNT" --sender "$ACCOUNT_ADDRESS" --password-file "$PASSWORD_FILE" --broadcast --slow -vvv)

# Run the deployment.
cd "$PROJECT_ROOT"
DEPLOY_START_EPOCH_SECONDS=$(date +%s)
DEPLOY_ATTEMPTED=1
if ! { "${FORGE_CMD[@]}" 2>&1 | tee "$DEPLOY_LOG"; }; then
    echo "Error: Deployment failed."
    exit 1
fi
# The password is only needed for this forge call; delete it right after broadcast to shorten the
# exposure window.
rm -f "$PASSWORD_FILE"

# Extract the addresses from the deployment output (_logDeploymentSummary in DeployAction.s.sol). A
# non-matching grep would silently abort the pipeline under set -e, so every lookup tolerates
# failure and missing entries are reported by require_contract_addresses.
ACTION_TARGET_ADDRESS=$(grep "ACTION_TARGET_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
LP_EXECUTOR_ADDRESS=$(grep "LP_EXECUTOR_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
GROUP_ACTION_EXECUTOR_ADDRESS=$(grep "GROUP_ACTION_EXECUTOR_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
GROUP_SERVICE_EXECUTOR_ADDRESS=$(grep "GROUP_SERVICE_EXECUTOR_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
require_contract_addresses

BROADCAST_FILE="$PROJECT_ROOT/broadcast/DeployAction.s.sol/$CHAIN_ID/run-latest.json"
if [ ! -f "$BROADCAST_FILE" ]; then
    echo "Error: Missing broadcast artifact: $BROADCAST_FILE"
    exit 1
fi
BROADCAST_TIMESTAMP_MS=$(sed -nE 's/.*"timestamp":[[:space:]]*([0-9]+).*/\1/p' "$BROADCAST_FILE" | tail -1)
if [ -z "$BROADCAST_TIMESTAMP_MS" ] || [ "$BROADCAST_TIMESTAMP_MS" -lt "$((DEPLOY_START_EPOCH_SECONDS * 1000))" ]; then
    echo "Error: Broadcast artifact was not updated by this deployment: $BROADCAST_FILE"
    exit 1
fi

require_broadcast_matches_executors() {
    local expected actual matches count
    expected=$(printf '%s %s %s %s' \
        "$ACTION_TARGET_ADDRESS" "$LP_EXECUTOR_ADDRESS" \
        "$GROUP_ACTION_EXECUTOR_ADDRESS" "$GROUP_SERVICE_EXECUTOR_ADDRESS" | tr 'A-F' 'a-f')
    matches=$(grep -o '"value": "(0x[0-9a-fA-F]\{40\}[^)]*)"' "$BROADCAST_FILE" || true)
    if [ -z "$matches" ]; then
        echo "Error: Missing executor return value in broadcast artifact"
        exit 1
    fi
    count=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')
    if [ "$count" -ne 1 ]; then
        echo "Error: Expected exactly one executor return value in broadcast artifact, found $count"
        exit 1
    fi
    actual=$(printf '%s\n' "$matches" | grep -oE '0x[0-9a-fA-F]{40}' | tr '\n' ' ' | tr 'A-F' 'a-f')
    actual=${actual% }
    if [ "$actual" != "$expected" ]; then
        echo "Error: Broadcast artifact does not match deployed executors"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        exit 1
    fi
}
require_broadcast_matches_executors

LIBRARIES_SECTION=$(awk '/"libraries": \[/{found=1} found{print} found && /\]/{exit}' "$BROADCAST_FILE")
if [ -z "$LIBRARIES_SECTION" ]; then
    echo "Error: Missing libraries in broadcast artifact: $BROADCAST_FILE"
    exit 1
fi

extract_library_address() {
    local name=$1
    printf '%s\n' "$LIBRARIES_SECTION" \
        | grep -o "\"src/[^\"]*:$name:0x[0-9a-fA-F]\{40\}\"" \
        | tail -1 | sed -E 's/.*:(0x[0-9a-fA-F]{40})"$/\1/' || true
}

for name in $LIBRARY_NAMES; do
    field=$(library_address_field "$name")
    value=$(extract_library_address "$name")
    printf -v "$field" '%s' "$value"
done

require_library_addresses

EXPECTED_LIBRARY_COUNT=$(printf '%s\n' $LIBRARY_NAMES | wc -l | tr -d ' ')
ACTUAL_LIBRARY_COUNT=$(printf '%s\n' "$LIBRARIES_SECTION" | grep -c '"src/[^"]*:0x[0-9a-fA-F]\{40\}"' || true)
if [ "$ACTUAL_LIBRARY_COUNT" -ne "$EXPECTED_LIBRARY_COUNT" ]; then
    echo "Error: Expected $EXPECTED_LIBRARY_COUNT linked libraries, found $ACTUAL_LIBRARY_COUNT"
    exit 1
fi

# Write the address file.
{
    printf 'ACTION_TARGET_ADDRESS=%s\n' "$ACTION_TARGET_ADDRESS"
    printf 'LP_EXECUTOR_ADDRESS=%s\n' "$LP_EXECUTOR_ADDRESS"
    printf 'GROUP_ACTION_EXECUTOR_ADDRESS=%s\n' "$GROUP_ACTION_EXECUTOR_ADDRESS"
    printf 'GROUP_SERVICE_EXECUTOR_ADDRESS=%s\n' "$GROUP_SERVICE_EXECUTOR_ADDRESS"
    for name in $LIBRARY_NAMES; do
        field=$(library_address_field "$name")
        printf '%s=%s\n' "$field" "${!field}"
    done
} > "$ADDRESS_TMP"
mv "$ADDRESS_TMP" "$NETWORK_DIR/addresses.action.params"

DEPLOY_SAVED=1
echo "✓ Deployment completed and addresses saved"
