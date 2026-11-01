#!/usr/bin/env bash
set -euo pipefail

# Step 3: source verification. Self-contained: loads network.params, verifier.params, action.params
# and the addresses.action.params written by the last deployment, without relying on the entrypoint
# to refresh addresses afterwards.
# Usage: script/deploy/31_verify.sh <network>

network="${1:?usage: script/deploy/31_verify.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$PROJECT_ROOT/script/network/$network"
VERIFIER_PARAMS="$PROJECT_ROOT/script/network/verifier.params"

# Parameter file loader: 1e17 / 1_000_000 style literals are expanded to decimal on load (params.sh).
source "$SCRIPT_DIR/params.sh"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

# Constructor arguments for the three Executors come from addresses.action.params (ActionTarget,
# GroupActionExecutor) and action.params (splits).
for config in network.params action.params addresses.action.params; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done
if [ ! -f "$VERIFIER_PARAMS" ]; then
    echo "Error: Missing required configuration: $VERIFIER_PARAMS"
    exit 1
fi

# Parameters come from files only: clear every key the files define, so a value exported by the
# caller cannot override a file value. GROUP_ACTION_SPLITS is the one key whose absence would change
# behaviour silently (an empty value is legal and means "no tiers"), so its presence is asserted
# against the file itself, never against the variable - an inherited value could satisfy that.
params_require_keys "$NETWORK_DIR/action.params" GROUP_ACTION_SPLITS || exit 1

params_unset_all "$NETWORK_DIR/network.params" "$VERIFIER_PARAMS" \
    "$NETWORK_DIR/action.params" "$NETWORK_DIR/addresses.action.params"

params_load "$NETWORK_DIR/network.params"
params_load "$VERIFIER_PARAMS"
params_load "$NETWORK_DIR/action.params"
params_load "$NETWORK_DIR/addresses.action.params"

cd "$PROJECT_ROOT"

# The opt-out list is mandatory as a key but may be empty: "verify every chain" is a legal answer.
params_require_keys "$VERIFIER_PARAMS" VERIFY_SKIP_CHAIN_IDS || exit 1

# Verification is attempted by default: only the chains listed here skip it, so a new production
# chain fails loudly instead of passing unverified.
skip_chains=",${VERIFY_SKIP_CHAIN_IDS:-},"
if [ -n "${CHAIN_ID:-}" ] && [[ "$skip_chains" == *",$CHAIN_ID,"* ]]; then
    echo "Skip: source verification is disabled for chain $CHAIN_ID in $VERIFIER_PARAMS"
    exit 0
fi

# The endpoint is a mandatory key: an empty URL would be passed straight to forge.
params_require_values "$VERIFIER_PARAMS" ETHERSCAN_VERIFIER_URL || exit 1
: "${ETHERSCAN_API_KEY:?Set an Etherscan API key; source verification has not run.}"

CONTRACT_ADDRESS_FIELDS="ACTION_TARGET_ADDRESS LP_EXECUTOR_ADDRESS GROUP_ACTION_EXECUTOR_ADDRESS GROUP_SERVICE_EXECUTOR_ADDRESS"
GROUP_ACTION_LIBRARY_SPECS=(
    "GroupActionJoin src/GroupActionJoin.sol GROUP_ACTION_JOIN_LIBRARY_ADDRESS"
    "GroupActionManager src/GroupActionManager.sol GROUP_ACTION_MANAGER_LIBRARY_ADDRESS"
    "GroupActionVerify src/GroupActionVerify.sol GROUP_ACTION_VERIFY_LIBRARY_ADDRESS"
)
GROUP_SERVICE_LIBRARY_SPECS=(
    "GroupRecipients src/GroupRecipients.sol GROUP_RECIPIENTS_LIBRARY_ADDRESS"
)

# Library addresses are embedded in the Executor runtime bytecode: without --libraries the
# standard-json settings.libraries is empty and the bytecode cannot match. Pass the flag once per
# library: this Foundry version does not accept one comma-joined value (it reports too many
# arguments passed).
GROUP_ACTION_LIBRARY_FIELDS=""
GROUP_ACTION_LIBRARY_ARGS=()
GROUP_SERVICE_LIBRARY_FIELDS=""
GROUP_SERVICE_LIBRARY_ARGS=()
ALL_LIBRARY_FQNS=()
ALL_LIBRARY_FIELDS=()
for spec in "${GROUP_ACTION_LIBRARY_SPECS[@]}"; do
    read -r lib_name lib_path lib_field <<< "$spec"
    GROUP_ACTION_LIBRARY_FIELDS+=" $lib_field"
    GROUP_ACTION_LIBRARY_ARGS+=(--libraries "$lib_path:$lib_name:${!lib_field:-}")
    ALL_LIBRARY_FQNS+=("$lib_path:$lib_name")
    ALL_LIBRARY_FIELDS+=("$lib_field")
done
for spec in "${GROUP_SERVICE_LIBRARY_SPECS[@]}"; do
    read -r lib_name lib_path lib_field <<< "$spec"
    GROUP_SERVICE_LIBRARY_FIELDS+=" $lib_field"
    GROUP_SERVICE_LIBRARY_ARGS+=(--libraries "$lib_path:$lib_name:${!lib_field:-}")
    ALL_LIBRARY_FQNS+=("$lib_path:$lib_name")
    ALL_LIBRARY_FIELDS+=("$lib_field")
done
GROUP_ACTION_LIBRARY_FIELDS=${GROUP_ACTION_LIBRARY_FIELDS# }
GROUP_SERVICE_LIBRARY_FIELDS=${GROUP_SERVICE_LIBRARY_FIELDS# }

for field in $CONTRACT_ADDRESS_FIELDS $GROUP_ACTION_LIBRARY_FIELDS $GROUP_SERVICE_LIBRARY_FIELDS; do
    if [[ ! ${!field:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field:-} = 0x0000000000000000000000000000000000000000 ]]; then
        echo "Error: Missing or invalid $field in $NETWORK_DIR/addresses.action.params"
        exit 1
    fi
done

# The three Executors fix their protocol addresses as immutables in the constructor, so the
# constructor arguments must be supplied when verifying. A failing command substitution would
# silently abort under set -e, so each call is checked explicitly for a clear message, and every
# encoding finishes before any verification request is sent.
if ! LP_EXECUTOR_ARGS=$(cast abi-encode "constructor(address)" \
    "$ACTION_TARGET_ADDRESS"); then
    echo "Error: Failed to encode LpExecutor constructor arguments"
    exit 1
fi
if ! GROUP_ACTION_EXECUTOR_ARGS=$(cast abi-encode "constructor(address,uint256[])" \
    "$ACTION_TARGET_ADDRESS" "[${GROUP_ACTION_SPLITS:-}]"); then
    echo "Error: Failed to encode GroupActionExecutor constructor arguments"
    exit 1
fi
if ! GROUP_SERVICE_EXECUTOR_ARGS=$(cast abi-encode "constructor(address)" \
    "$GROUP_ACTION_EXECUTOR_ADDRESS"); then
    echo "Error: Failed to encode GroupServiceExecutor constructor arguments"
    exit 1
fi

COMMON_ARGS=(--chain "$CHAIN_ID" --verifier etherscan --verifier-url "$ETHERSCAN_VERIFIER_URL" --watch)
verify_contract() {
    local address=$1 fqn=$2
    shift 2
    echo "Verifying $fqn..."
    forge verify-contract "$address" "$fqn" "${COMMON_ARGS[@]}" "$@"
}

verify_contract "$ACTION_TARGET_ADDRESS" "src/ActionTarget.sol:ActionTarget"
verify_contract "$LP_EXECUTOR_ADDRESS" "src/LpExecutor.sol:LpExecutor" \
    --constructor-args "$LP_EXECUTOR_ARGS"
verify_contract "$GROUP_ACTION_EXECUTOR_ADDRESS" "src/GroupActionExecutor.sol:GroupActionExecutor" \
    --constructor-args "$GROUP_ACTION_EXECUTOR_ARGS" "${GROUP_ACTION_LIBRARY_ARGS[@]}"
verify_contract "$GROUP_SERVICE_EXECUTOR_ADDRESS" "src/GroupServiceExecutor.sol:GroupServiceExecutor" \
    --constructor-args "$GROUP_SERVICE_EXECUTOR_ARGS" "${GROUP_SERVICE_LIBRARY_ARGS[@]}"
for i in "${!ALL_LIBRARY_FQNS[@]}"; do
    field=${ALL_LIBRARY_FIELDS[$i]}
    verify_contract "${!field}" "${ALL_LIBRARY_FQNS[$i]}"
done
echo "✓ Source verification succeeded for all contracts and linked libraries"
