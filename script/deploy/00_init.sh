#!/usr/bin/env bash
set -euo pipefail

# 部署环境初始化。由入口脚本 source 载入（source 00_init.sh <network>）；步骤脚本不载入，直接用已载入的环境。
if [ -z "${1:-}" ]; then
    echo "Error: network name is required (e.g. anvil31337_dev)"
    exit 1
fi
network="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$PROJECT_ROOT/script/network/$network"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

# 必需配置。addresses.core.params 是被依赖方（core）已部署地址，由 core 部署后复制而来。
for config in network.params addresses.core.params action.params; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done

set -a
source "$NETWORK_DIR/network.params"
source "$NETWORK_DIR/addresses.core.params"
source "$NETWORK_DIR/action.params"
set +a

# 可选配置：账户信息（KEYSTORE_ACCOUNT / ACCOUNT_ADDRESS 之外的 KEYSTORE_PASSWORD 亦在此处）。
# 只载入部署所需文件：部署产物 addresses.action.params 由校验步骤自行载入，不进部署环境。
if [ -f "$NETWORK_DIR/.account" ]; then
    set -a
    source "$NETWORK_DIR/.account"
    set +a
fi

export network
export NETWORK_DIR
export PROJECT_ROOT

# Core 依赖地址必须先于广播校验存在：Mint 供 ActionTarget 派生，Stake 供三个 Executor 派生。
require_core_dependencies() {
    local field
    for field in MINT_ADDRESS STAKE_ADDRESS; do
        if [[ ! ${!field:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field:-} = 0x0000000000000000000000000000000000000000 ]]; then
            echo "Error: Missing or invalid $field in $NETWORK_DIR/addresses.core.params"
            exit 1
        fi
        local code
        if ! code=$(cast code "${!field}" --rpc-url "$RPC_URL" 2>/dev/null) || [[ ! "$code" =~ ^0x[0-9a-fA-F]+$ ]]; then
            echo "Error: $field ${!field} is not a deployed contract on chain $CHAIN_ID"
            exit 1
        fi
    done
}

# 确认实际链，不能只检查 RPC 是否可连接。
ACTUAL_CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL") || exit 1
if [ "$ACTUAL_CHAIN_ID" != "$CHAIN_ID" ]; then
    echo "Error: RPC chain ID $ACTUAL_CHAIN_ID does not match configured CHAIN_ID $CHAIN_ID"
    exit 1
fi

echo "✓ Initialized environment for network: $network"
echo "  RPC_URL: $RPC_URL"
echo "  CHAIN_ID: $CHAIN_ID"

# 4 个行动合约地址，供 01_deploy.sh 与 verify.sh 共用校验（99_check.sh 自行载入地址文件，不经过这里）。
# 字段必须写在函数体内：函数经 export -f 传给子进程后，未导出的数组会静默展开为空，校验会变成空转。
require_action_addresses() {
    local field
    for field in ACTIONTARGET_ADDRESS LPEXECUTOR_ADDRESS \
        GROUPACTIONEXECUTOR_ADDRESS GROUPSERVICEEXECUTOR_ADDRESS; do
        if [[ ! ${!field:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field:-} = 0x0000000000000000000000000000000000000000 ]]; then
            echo "Error: Missing or invalid $field"
            exit 1
        fi
    done
}
# 步骤脚本作为子进程启动时函数不随环境继承，故显式导出。
export -f require_action_addresses
export -f require_core_dependencies
