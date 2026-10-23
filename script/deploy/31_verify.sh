#!/usr/bin/env bash
set -euo pipefail

# 步骤三：合约开源验证。自包含——自行载入 network.params 与上次部署写入的 addresses.action.params，
# 不依赖入口脚本在部署后刷新地址。用法：script/deploy/31_verify.sh <network>

network="${1:?usage: script/deploy/31_verify.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$PROJECT_ROOT/script/network/$network"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

for config in network.params addresses.action.params; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done

set -a
source "$NETWORK_DIR/network.params"
source "$NETWORK_DIR/addresses.action.params"
set +a

cd "$PROJECT_ROOT"

# 链不支持开源验证时跳过，不视为失败，使一键部署在本地/未接入浏览器的链上仍可跑通。
case "$CHAIN_ID" in
    56|97) ;;
    *) echo "Skip: source verification is not configured for chain $CHAIN_ID"; exit 0 ;;
esac
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

# 库地址内嵌在 Executor 运行时字节码中：不传 --libraries 时 standard-json 的
# settings.libraries 为空，字节码无法匹配。多个库必须重复传该参数：本版 Foundry
# 不接受逗号拼接的单个值（会报 too many arguments passed）。
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

# 均无构造函数参数（依赖经 init 绑定），直接提交验证。
COMMON_ARGS=(--chain "$CHAIN_ID" --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api" --watch)
verify_contract() {
    local address=$1 fqn=$2
    shift 2
    echo "Verifying $fqn..."
    forge verify-contract "$address" "$fqn" "${COMMON_ARGS[@]}" "$@"
}

verify_contract "$ACTION_TARGET_ADDRESS" "src/ActionTarget.sol:ActionTarget"
verify_contract "$LP_EXECUTOR_ADDRESS" "src/LpExecutor.sol:LpExecutor"
verify_contract "$GROUP_ACTION_EXECUTOR_ADDRESS" "src/GroupActionExecutor.sol:GroupActionExecutor" "${GROUP_ACTION_LIBRARY_ARGS[@]}"
verify_contract "$GROUP_SERVICE_EXECUTOR_ADDRESS" "src/GroupServiceExecutor.sol:GroupServiceExecutor" "${GROUP_SERVICE_LIBRARY_ARGS[@]}"
for i in "${!ALL_LIBRARY_FQNS[@]}"; do
    field=${ALL_LIBRARY_FIELDS[$i]}
    verify_contract "${!field}" "${ALL_LIBRARY_FQNS[$i]}"
done
echo "✓ Source verification succeeded for all contracts and linked libraries"
