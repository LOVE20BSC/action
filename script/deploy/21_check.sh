#!/usr/bin/env bash
set -euo pipefail

# Deployment and initialization check: read-only over config and chain state (forge inspect
# compiles locally and refreshes out/cache, never writes an address file). Loads its own
# check inputs instead of relying on a preloaded environment: network.params provides RPC and
# chain ID, addresses.core.params the expected core bindings, action.params the expected splits
# and addresses.action.params the deployed addresses to verify.
# Usage: script/deploy/21_check.sh <network>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# forge inspect locates foundry.toml through the current directory, unlike cast: without switching
# to the project root the runtime comparison gets an empty artifact and falsely reports "runtime
# unavailable".
cd "$PROJECT_ROOT"

network="${1:?usage: script/deploy/21_check.sh <network>}"
NETWORK_DIR="$PROJECT_ROOT/script/network/$network"

# Parameter file loader: 1e17 / 1_000_000 style literals are expanded to decimal on load (params.sh).
source "$SCRIPT_DIR/params.sh"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

if [ ! -f "$NETWORK_DIR/addresses.action.params" ]; then
    echo "Error: Missing $NETWORK_DIR/addresses.action.params; run one_click_deploy.sh first"
    exit 1
fi

# Parameters come from files only: clear every key the files define, so a value exported by the
# caller cannot override a file value. GROUP_ACTION_SPLITS is the one key whose absence would change
# behaviour silently (an empty value is legal and means "no tiers"), so its presence is asserted
# against the file itself, never against the variable - an inherited value could satisfy that.
params_require_keys "$NETWORK_DIR/action.params" GROUP_ACTION_SPLITS || exit 1

params_unset_all "$NETWORK_DIR/network.params" "$NETWORK_DIR/addresses.core.params" \
    "$NETWORK_DIR/action.params" "$NETWORK_DIR/addresses.action.params"

params_load "$NETWORK_DIR/network.params"
params_load "$NETWORK_DIR/addresses.core.params"
params_load "$NETWORK_DIR/action.params"
params_load "$NETWORK_DIR/addresses.action.params"

# The address file's key set must equal the expected contract/library set: a renamed key would leave
# later variables silently empty and fail much later with an unhelpful message, so assert it here.
address_file="$NETWORK_DIR/addresses.action.params"
CONTRACT_ADDRESS_FIELDS="ACTION_TARGET_ADDRESS GROUP_ACTION_EXECUTOR_ADDRESS GROUP_SERVICE_EXECUTOR_ADDRESS LP_EXECUTOR_ADDRESS"
GROUP_ACTION_LIBRARY_SPECS=(
    "GroupActionJoin src/GroupActionJoin.sol GROUP_ACTION_JOIN_LIBRARY_ADDRESS"
    "GroupActionManager src/GroupActionManager.sol GROUP_ACTION_MANAGER_LIBRARY_ADDRESS"
    "GroupActionVerify src/GroupActionVerify.sol GROUP_ACTION_VERIFY_LIBRARY_ADDRESS"
)
GROUP_SERVICE_LIBRARY_SPECS=(
    "GroupRecipients src/GroupRecipients.sol GROUP_RECIPIENTS_LIBRARY_ADDRESS"
)

GROUP_ACTION_LIBRARY_FIELDS=""
GROUP_ACTION_LIBRARY_ARGS=()
GROUP_SERVICE_LIBRARY_FIELDS=""
GROUP_SERVICE_LIBRARY_ARGS=()
ALL_LIBRARY_NAMES=()
ALL_LIBRARY_FIELDS=()
for spec in "${GROUP_ACTION_LIBRARY_SPECS[@]}"; do
    read -r lib_name lib_path lib_field <<< "$spec"
    GROUP_ACTION_LIBRARY_FIELDS+=" $lib_field"
    GROUP_ACTION_LIBRARY_ARGS+=(--libraries "$lib_path:$lib_name:${!lib_field:-}")
    ALL_LIBRARY_NAMES+=("$lib_name")
    ALL_LIBRARY_FIELDS+=("$lib_field")
done
for spec in "${GROUP_SERVICE_LIBRARY_SPECS[@]}"; do
    read -r lib_name lib_path lib_field <<< "$spec"
    GROUP_SERVICE_LIBRARY_FIELDS+=" $lib_field"
    GROUP_SERVICE_LIBRARY_ARGS+=(--libraries "$lib_path:$lib_name:${!lib_field:-}")
    ALL_LIBRARY_NAMES+=("$lib_name")
    ALL_LIBRARY_FIELDS+=("$lib_field")
done
GROUP_ACTION_LIBRARY_FIELDS=${GROUP_ACTION_LIBRARY_FIELDS# }
GROUP_SERVICE_LIBRARY_FIELDS=${GROUP_SERVICE_LIBRARY_FIELDS# }
expected_keys="$CONTRACT_ADDRESS_FIELDS $GROUP_ACTION_LIBRARY_FIELDS $GROUP_SERVICE_LIBRARY_FIELDS"
actual_keys=$(grep -oE '^[A-Z0-9_]+=' "$address_file" | sed 's/=$//' | sort | tr '\n' ' ' || true)
if [ "$actual_keys" != "$(printf '%s\n' $expected_keys | sort | tr '\n' ' ')" ]; then
    echo "Error: $address_file key set mismatch"
    echo "  expected: $(printf '%s\n' $expected_keys | sort | tr '\n' ' ')"
    echo "  actual:   $actual_keys"
    exit 1
fi

# Colors.
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Verifying Action Deployment      ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

# Every contract and library address must be set and look like a nonzero address: a malformed one
# would surface as "not deployed" and hide the real cause. The predicate matches 31_verify.sh.
for field in $expected_keys; do
    if [[ ! ${!field:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field:-} = 0x0000000000000000000000000000000000000000 ]]; then
        echo -e "${RED}✗ Error: $field is missing or invalid in $address_file${NC}"
        exit 1
    fi
done

# Helper: normalize output (strip quotes and the scientific-notation marker).
normalize_output() {
    local value="$1"
    # strip surrounding quotes
    value="${value%\"}"
    value="${value#\"}"
    # strip the scientific-notation marker [1e18]
    value="${value% \[*\]}"
    echo "$value"
}

# Helper: verify a single value.
verify_value() {
    local field_name=$1
    local expected=$2
    local actual=$3

    # normalize both values
    expected=$(normalize_output "$expected")
    actual=$(normalize_output "$actual")

    if [[ "$expected" =~ ^0x[0-9a-fA-F]{40}$ && "$actual" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        expected=$(echo "$expected" | tr '[:upper:]' '[:lower:]')
        actual=$(echo "$actual" | tr '[:upper:]' '[:lower:]')
    fi

    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} ${field_name}"
        echo -e "    ${GRAY}Expected: ${expected}${NC}"
        echo -e "    ${GRAY}Actual:   ${actual}${NC}"
        return 0
    else
        echo -e "  ${RED}✗${NC} ${field_name}"
        echo -e "    ${GRAY}Expected: ${expected}${NC}"
        echo -e "    ${YELLOW}Actual:   ${actual}${NC}"
        return 1
    fi
}

# Helper: verify that a contract is deployed.
verify_deployed() {
    local name=$1
    local address=$2

    local code
    code=$(cast code "$address" --rpc-url "$RPC_URL" 2>/dev/null) || return 1
    if [[ ! "$code" =~ ^0x[0-9a-fA-F]+$ ]]; then
        echo -e "${RED}✗ $name not deployed at $address${NC}"
        return 1
    fi
    return 0
}

# Checking addresses alone cannot detect a library swap inside one Executor, so compare the fully
# linked runtime code. Executor protocol addresses are fixed as immutables in the constructor: the
# build artifact has zeros in those slots and the chain fills them from the constructor arguments.
# Only deployedBytecode.immutableReferences are backfilled; the artifact's linkReferences also carry
# a start field whose creation-link offset may fall inside the runtime range, so they must not be
# allowed to mask a real difference.
apply_chain_immutables() {
    local contract_name=$1
    local expected=$2
    local actual=$3

    local artifact starts
    artifact=$(forge inspect "$contract_name" artifact 2>/dev/null) || return 1
    starts=$(printf '%s' "$artifact" | python3 -c '
import json
import sys

artifact = json.load(sys.stdin)
references = (artifact.get("deployedBytecode") or {}).get("immutableReferences") or {}
for entries in references.values():
    for entry in entries:
        if entry.get("length") != 32:
            raise SystemExit("immutable slot length is not 32")
        print(entry["start"])
' 2>/dev/null) || return 1

    local offset begin
    while IFS= read -r offset; do
        [ -z "$offset" ] && continue
        begin=$((offset * 2 + 2))
        expected="${expected:0:$begin}${actual:$begin:64}${expected:$((begin + 64))}"
    done <<< "$starts"

    printf '%s' "$expected"
}

verify_runtime_matches_artifact() {
    local contract_name=$1
    local address=$2
    shift 2

    local expected actual
    expected=$(forge inspect "$contract_name" deployedBytecode "$@" 2>/dev/null || true)
    actual=$(cast code "$address" --rpc-url "$RPC_URL" 2>/dev/null || true)
    if [ -z "$expected" ] || [ -z "$actual" ]; then
        echo -e "${RED}✗ $contract_name runtime unavailable at $address${NC}"
        return 1
    fi

    expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
    actual=$(printf '%s' "$actual" | tr 'A-F' 'a-f')
    if ! expected=$(apply_chain_immutables "$contract_name" "$expected" "$actual"); then
        echo -e "${RED}✗ $contract_name artifact unavailable${NC}"
        return 1
    fi
    if [ "$expected" != "$actual" ]; then
        echo -e "${RED}✗ $contract_name runtime does not match its build artifact${NC}"
        echo -e "    ${GRAY}${address}${NC}"
        return 1
    fi

    echo -e "  ${GREEN}✓${NC} ${contract_name} runtime matches build artifact"
    echo -e "    ${GRAY}${address}${NC}"
}

# The immutable backfill masks these slots' values, so read every constructor-derived address back:
# STAKE/MEMBER_NFT/PHASE shared by all three Executors plus each one's own protocol addresses
# (appended by the caller).
verify_executor_bindings() {
    local name=$1
    local address=$2
    shift 2

    local pair getter expected actual
    for pair in "STAKE_ADDRESS:$STAKE_ADDRESS" "MEMBER_NFT_ADDRESS:$MEMBER_NFT_ADDRESS" "PHASE_ADDRESS:$PHASE_ADDRESS" "$@"; do
        getter=${pair%%:*}
        expected=${pair#*:}
        actual=$(cast call "$address" "$getter()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
        verify_value "$name.$getter" "$expected" "$actual" || ((FAILED+=1))
    done
}

# A library's runtime code embeds its own address at the start (written by the constructor at
# deployment) and the build artifact has twenty zero bytes there. Comparing directly would flag
# every deployed library as mismatched, so substitute that single spot with the recorded address
# first.
verify_library_runtime_matches_artifact() {
    local contract_name=$1
    local address=$2

    local expected actual placeholder self
    expected=$(forge inspect "$contract_name" deployedBytecode 2>/dev/null || true)
    actual=$(cast code "$address" --rpc-url "$RPC_URL" 2>/dev/null || true)
    if [ -z "$expected" ] || [ -z "$actual" ]; then
        echo -e "${RED}✗ $contract_name runtime unavailable at $address${NC}"
        return 1
    fi

    expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
    actual=$(printf '%s' "$actual" | tr 'A-F' 'a-f')
    placeholder="73$(printf '%040d' 0)"
    # Replace the first occurrence only: every one of the four libraries has exactly one today. A
    # different count means the compiler layout changed, and silently substituting the first would
    # flag correct on-chain code as mismatched, so fail loudly.
    local occurrences
    occurrences=$(printf '%s' "$expected" | grep -o "$placeholder" | wc -l | tr -d ' ' || true)
    if [ "$occurrences" -ne 1 ]; then
        echo -e "${RED}✗ $contract_name self-address placeholder count is $occurrences, expected 1${NC}"
        echo -e "    ${GRAY}library bytecode layout changed; revisit the substitution rule${NC}"
        return 1
    fi
    self=$(printf '%s' "$address" | tr 'A-F' 'a-f')
    expected=${expected/$placeholder/73${self#0x}}

    if [ "$expected" != "$actual" ]; then
        echo -e "${RED}✗ $contract_name runtime does not match its build artifact${NC}"
        echo -e "    ${GRAY}${address}${NC}"
        return 1
    fi

    echo -e "  ${GREEN}✓${NC} ${contract_name} runtime matches build artifact"
    echo -e "    ${GRAY}${address}${NC}"
}

# Helper: print a contract header.
print_contract_header() {
    local num=$1
    local name=$2
    local address=$3
    echo ""
    echo -e "${BLUE}[$num/5]${NC} ${CYAN}${name}${NC}"
    echo -e "${GRAY}      ${address}${NC}"
}

FAILED=0

# Skip the runtime comparison when an address has no code: one failure is counted once, so "1
# contract not deployed" does not become two failed checks. The library loop uses the same rule.
verify_deployed_and_runtime() {
    local contract_name=$1
    local address=$2
    shift 2
    if ! verify_deployed "$contract_name" "$address"; then
        FAILED=$((FAILED + 1))
        return
    fi
    verify_runtime_matches_artifact "$contract_name" "$address" "$@" || ((FAILED+=1))
}

ACTUAL_CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
verify_value "CHAIN_ID" "$CHAIN_ID" "$ACTUAL_CHAIN_ID" || exit 1

# 1. ActionTarget.
# Its five post-init bindings — SUBMIT, VOTE, MEMBER_NFT, PHASE, MINT — are every write entry's
# auth root. Checking all five plus initialized() is the deployment-side proof that init was the
# first transaction to the address and derived from the expected Mint; the contract deliberately
# does not restrict init's caller (see specs/action/01-action-target.md).
print_contract_header "1" "ActionTarget" "$ACTION_TARGET_ADDRESS"
verify_deployed_and_runtime "ActionTarget" "$ACTION_TARGET_ADDRESS"

ACTUAL_INIT=$(cast call "$ACTION_TARGET_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_INIT" || ((FAILED+=1))

ACTUAL_MINT=$(cast call "$ACTION_TARGET_ADDRESS" "MINT_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "mintAddress" "$MINT_ADDRESS" "$ACTUAL_MINT" || ((FAILED+=1))

ACTUAL_VOTE=$(cast call "$ACTION_TARGET_ADDRESS" "VOTE_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "voteAddress" "$VOTE_ADDRESS" "$ACTUAL_VOTE" || ((FAILED+=1))

ACTUAL_SUBMIT=$(cast call "$ACTION_TARGET_ADDRESS" "SUBMIT_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "submitAddress" "$SUBMIT_ADDRESS" "$ACTUAL_SUBMIT" || ((FAILED+=1))

ACTUAL_MEMBER=$(cast call "$ACTION_TARGET_ADDRESS" "MEMBER_NFT_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "memberNFTAddress" "$MEMBER_NFT_ADDRESS" "$ACTUAL_MEMBER" || ((FAILED+=1))

ACTUAL_PHASE=$(cast call "$ACTION_TARGET_ADDRESS" "PHASE_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "phaseAddress" "$PHASE_ADDRESS" "$ACTUAL_PHASE" || ((FAILED+=1))

# The Executor immutables were verified through the getters above; also confirm Stake itself matches
# the core address file, which proves the memberNFT/phase/vote/launch derivation source of all three
# Executors is right.
print_contract_header "2" "Stake (derived bindings)" "$STAKE_ADDRESS"
verify_deployed "Stake" "$STAKE_ADDRESS" || ((FAILED+=1))
ACTUAL_STAKE_MEMBER=$(cast call "$STAKE_ADDRESS" "MEMBER_NFT_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MEMBER_NFT_ADDRESS" "$MEMBER_NFT_ADDRESS" "$ACTUAL_STAKE_MEMBER" || ((FAILED+=1))
ACTUAL_STAKE_PHASE=$(cast call "$STAKE_ADDRESS" "PHASE_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "PHASE_ADDRESS" "$PHASE_ADDRESS" "$ACTUAL_STAKE_PHASE" || ((FAILED+=1))
ACTUAL_STAKE_VOTE=$(cast call "$STAKE_ADDRESS" "VOTE_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "VOTE_ADDRESS" "$VOTE_ADDRESS" "$ACTUAL_STAKE_VOTE" || ((FAILED+=1))
ACTUAL_STAKE_LAUNCH=$(cast call "$STAKE_ADDRESS" "LAUNCH_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "LAUNCH_ADDRESS" "$LAUNCH_ADDRESS" "$ACTUAL_STAKE_LAUNCH" || ((FAILED+=1))
ACTUAL_STAKE_FACTORY=$(cast call "$STAKE_ADDRESS" "PAIR_FACTORY_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_deployed "Stake PAIR_FACTORY_ADDRESS" "$ACTUAL_STAKE_FACTORY" || ((FAILED+=1))
ACTUAL_LAUNCH_FACTORY=$(cast call "$LAUNCH_ADDRESS" "PAIR_FACTORY_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "Stake/Launch PAIR_FACTORY_ADDRESS" "$ACTUAL_LAUNCH_FACTORY" "$ACTUAL_STAKE_FACTORY" || ((FAILED+=1))
ACTUAL_STAKE_ROUTER=$(cast call "$STAKE_ADDRESS" "ROUTER_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_deployed "Stake ROUTER_ADDRESS" "$ACTUAL_STAKE_ROUTER" || ((FAILED+=1))

# 3. LpExecutor.
print_contract_header "3" "LpExecutor" "$LP_EXECUTOR_ADDRESS"
verify_deployed_and_runtime "LpExecutor" "$LP_EXECUTOR_ADDRESS"

ACTUAL_TARGET=$(cast call "$LP_EXECUTOR_ADDRESS" "ACTION_TARGET_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "actionTarget" "$ACTION_TARGET_ADDRESS" "$ACTUAL_TARGET" || ((FAILED+=1))
verify_executor_bindings "LpExecutor" "$LP_EXECUTOR_ADDRESS" "PAIR_FACTORY_ADDRESS:$ACTUAL_STAKE_FACTORY"

# 4. GroupActionExecutor.
print_contract_header "4" "GroupActionExecutor" "$GROUP_ACTION_EXECUTOR_ADDRESS"
verify_deployed_and_runtime "GroupActionExecutor" "$GROUP_ACTION_EXECUTOR_ADDRESS" \
    "${GROUP_ACTION_LIBRARY_ARGS[@]}"

ACTUAL_TARGET=$(cast call "$GROUP_ACTION_EXECUTOR_ADDRESS" "ACTION_TARGET_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "actionTarget" "$ACTION_TARGET_ADDRESS" "$ACTUAL_TARGET" || ((FAILED+=1))
verify_executor_bindings "GroupActionExecutor" "$GROUP_ACTION_EXECUTOR_ADDRESS" "VOTE_ADDRESS:$VOTE_ADDRESS"

# splits are configured comma-separated and cast returns "[a [1e17], b [4e17]]": strip the
# scientific-notation markers and spaces element by element before comparing (a marker looks like
# [1e17] and never touches the array's outer brackets).
strip_sci_notation() {
    echo "$1" | sed -E 's/\[[0-9.]+e[0-9]+\]//g' | tr -d ' '
}
ACTUAL_SPLITS=$(cast call "$GROUP_ACTION_EXECUTOR_ADDRESS" "SPLITS()(uint256[])" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
EXPECTED_SPLITS="[${GROUP_ACTION_SPLITS:-}]"
verify_value "SPLITS" "$(strip_sci_notation "$EXPECTED_SPLITS")" "$(strip_sci_notation "$ACTUAL_SPLITS")" || ((FAILED+=1))

if [ -n "${GROUP_ACTION_SPLITS:-}" ]; then
    previous=0
    IFS=',' read -ra split_items <<< "$GROUP_ACTION_SPLITS"
    for item in "${split_items[@]}"; do
        item=$(echo "$item" | tr -d ' ')
        if [[ ! "$item" =~ ^[0-9]+$ ]] || [ "$item" -eq 0 ] \
            || [ "$item" -ge 1000000000000000000 ] || [ "$item" -le "$previous" ]; then
            echo -e "  ${RED}✗${NC} GROUP_ACTION_SPLITS must be strictly increasing in (0, 1e18)"
            ((FAILED+=1))
            break
        fi
        previous=$item
    done
fi

# 5. GroupServiceExecutor.
print_contract_header "5" "GroupServiceExecutor" "$GROUP_SERVICE_EXECUTOR_ADDRESS"
verify_deployed_and_runtime "GroupServiceExecutor" "$GROUP_SERVICE_EXECUTOR_ADDRESS" \
    "${GROUP_SERVICE_LIBRARY_ARGS[@]}"

ACTUAL_TARGET=$(cast call "$GROUP_SERVICE_EXECUTOR_ADDRESS" "ACTION_TARGET_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "actionTarget" "$ACTION_TARGET_ADDRESS" "$ACTUAL_TARGET" || ((FAILED+=1))
verify_executor_bindings "GroupServiceExecutor" "$GROUP_SERVICE_EXECUTOR_ADDRESS" \
    "LAUNCH_ADDRESS:$LAUNCH_ADDRESS" "MINT_ADDRESS:$MINT_ADDRESS"

ACTUAL_GAE=$(cast call "$GROUP_SERVICE_EXECUTOR_ADDRESS" "GROUP_ACTION_EXECUTOR_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "groupActionExecutorAddress" "$GROUP_ACTION_EXECUTOR_ADDRESS" "$ACTUAL_GAE" || ((FAILED+=1))

for i in "${!ALL_LIBRARY_NAMES[@]}"; do
    field=${ALL_LIBRARY_FIELDS[$i]}
    lib_name=${ALL_LIBRARY_NAMES[$i]}
    if ! verify_deployed "$lib_name" "${!field}"; then
        FAILED=$((FAILED + 1))
        continue
    fi
    echo -e "  ${GREEN}✓${NC} ${lib_name} deployed"
    verify_library_runtime_matches_artifact "$lib_name" "${!field}" || ((FAILED+=1))
done

echo ""
echo -e "${CYAN}════════════════════════════════════════${NC}"
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All verifications passed${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo ""
else
    echo -e "${RED}✗ $FAILED verification(s) failed${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo ""
    exit 1
fi
