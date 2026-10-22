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

for field in ACTION_TARGET_ADDRESS LP_EXECUTOR_ADDRESS \
    GROUP_ACTION_EXECUTOR_ADDRESS GROUP_SERVICE_EXECUTOR_ADDRESS; do
    if [[ ! ${!field:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field:-} = 0x0000000000000000000000000000000000000000 ]]; then
        echo "Error: Missing or invalid $field in $NETWORK_DIR/addresses.action.params"
        exit 1
    fi
done

# 四个合约均无构造函数参数（依赖经 init 绑定），直接提交验证。
COMMON_ARGS=(--chain "$CHAIN_ID" --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api" --watch)
verify_contract() {
    local address=$1 name=$2
    shift 2
    echo "Verifying $name..."
    forge verify-contract "$address" "src/$name.sol:$name" "${COMMON_ARGS[@]}" "$@"
}

verify_contract "$ACTION_TARGET_ADDRESS" ActionTarget
verify_contract "$LP_EXECUTOR_ADDRESS" LpExecutor
verify_contract "$GROUP_ACTION_EXECUTOR_ADDRESS" GroupActionExecutor
verify_contract "$GROUP_SERVICE_EXECUTOR_ADDRESS" GroupServiceExecutor
echo "✓ Source verification succeeded for all 4 contracts"
