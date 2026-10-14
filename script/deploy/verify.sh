#!/usr/bin/env bash
set -euo pipefail

# 前置：环境已由入口脚本载入（source 00_init.sh <network>）；本步骤不自行载入。
cd "$PROJECT_ROOT"

# 链不支持开源验证时跳过，不视为失败，使一键部署在本地/未接入浏览器的链上仍可跑通。
case "$CHAIN_ID" in
    56|97) ;;
    *) echo "Skip: source verification is not configured for chain $CHAIN_ID"; exit 0 ;;
esac
: "${ETHERSCAN_API_KEY:?Set an Etherscan API key; source verification has not run.}"

require_action_addresses

# 四个合约均无构造函数参数（依赖经 init 绑定），直接提交验证。
COMMON_ARGS=(--chain "$CHAIN_ID" --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api" --watch)
verify_contract() {
    local address=$1 name=$2
    shift 2
    echo "Verifying $name..."
    forge verify-contract "$address" "src/$name.sol:$name" "${COMMON_ARGS[@]}" "$@"
}

verify_contract "$ACTIONTARGET_ADDRESS" ActionTarget
verify_contract "$LPEXECUTOR_ADDRESS" LpExecutor
verify_contract "$GROUPACTIONEXECUTOR_ADDRESS" GroupActionExecutor
verify_contract "$GROUPSERVICEEXECUTOR_ADDRESS" GroupServiceExecutor
echo "✓ Source verification succeeded for all 4 contracts"
