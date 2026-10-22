#!/usr/bin/env bash
set -euo pipefail

# 步骤一：合约部署与初始化。自包含——自行加载并校验部署所需文件，不依赖调用方预载环境。
# 用法：script/deploy/11_deploy.sh <network>
# 部署产物 addresses.action.params 由本步骤写入，供 21_check.sh 与 31_verify.sh 自行载入。

network="${1:?usage: script/deploy/11_deploy.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$PROJECT_ROOT/script/network/$network"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

# 必需配置。addresses.core.params 是被依赖方（core）已部署地址，由 core 部署后复制而来；
# .account 提供 keystore 账户与密码，缺失即失败（本地链同样走 keystore 签名，不用 --unlocked）。
for config in network.params addresses.core.params action.params .account; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done

env_password="${KEYSTORE_PASSWORD:-}"
set -a
source "$NETWORK_DIR/network.params"
source "$NETWORK_DIR/addresses.core.params"
source "$NETWORK_DIR/action.params"
source "$NETWORK_DIR/.account"
set +a

# .account 里的空 KEYSTORE_PASSWORD 行不应清掉入口已导出的密码（避免重复弹窗）。
[ -n "${KEYSTORE_PASSWORD:-}" ] || KEYSTORE_PASSWORD="$env_password"

[ -n "${KEYSTORE_ACCOUNT:-}" ] && [ -n "${ACCOUNT_ADDRESS:-}" ] \
    || { echo "Error: KEYSTORE_ACCOUNT / ACCOUNT_ADDRESS is not set in $NETWORK_DIR/.account" >&2; exit 1; }

# 确认实际链，不能只检查 RPC 是否可连接。
ACTUAL_CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL") || exit 1
if [ "$ACTUAL_CHAIN_ID" != "$CHAIN_ID" ]; then
    echo "Error: RPC chain ID $ACTUAL_CHAIN_ID does not match configured CHAIN_ID $CHAIN_ID"
    exit 1
fi

# keystore 密码：已设则不弹窗（非交互调用用）；留空则 macOS 弹窗读取。
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

# 4 个行动合约地址：从部署日志提取后逐项校验，缺项即失败，不写半截地址文件。
require_action_addresses() {
    local field
    for field in ACTION_TARGET_ADDRESS LP_EXECUTOR_ADDRESS \
        GROUP_ACTION_EXECUTOR_ADDRESS GROUP_SERVICE_EXECUTOR_ADDRESS; do
        if [[ ! ${!field:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field:-} = 0x0000000000000000000000000000000000000000 ]]; then
            echo "Error: Missing or invalid $field extracted from deployment log"
            exit 1
        fi
    done
}

# 准备部署日志
DEPLOY_LOG=$(mktemp)
trap "rm -f $DEPLOY_LOG" EXIT

# GroupActionExecutor 的 splits 由 action.params 以逗号分隔提供，空值即空数组。
SPLITS_LITERAL="[${GROUP_ACTION_SPLITS:-}]"

# 构建 forge script 命令：keystore 签名（本地链同样如此，不用 --unlocked）。
FORGE_CMD=(forge script script/deploy/DeployAction.s.sol:DeployAction --sig "run(uint256[])" "$SPLITS_LITERAL" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --account "$KEYSTORE_ACCOUNT" --sender "$ACCOUNT_ADDRESS" --password "$KEYSTORE_PASSWORD" --broadcast --slow -vvv)

# Core 依赖必须在广播前校验为已部署合约，避免白广播 4 个行动合约。
require_core_dependencies

# 执行部署
cd "$PROJECT_ROOT"
if ! { "${FORGE_CMD[@]}" 2>&1 | tee "$DEPLOY_LOG"; }; then
    echo "Error: Deployment failed; saved addresses were not changed."
    exit 1
fi

# 从部署输出中提取地址（DeployAction.s.sol 的 _logDeploymentSummary 输出）。
# grep 无匹配会让管道在 set -e 下静默中止，故逐个容错取值，缺项交由 require_action_addresses 报错。
ACTION_TARGET_ADDRESS=$(grep "ACTION_TARGET_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
LP_EXECUTOR_ADDRESS=$(grep "LP_EXECUTOR_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
GROUP_ACTION_EXECUTOR_ADDRESS=$(grep "GROUP_ACTION_EXECUTOR_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
GROUP_SERVICE_EXECUTOR_ADDRESS=$(grep "GROUP_SERVICE_EXECUTOR_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)

require_action_addresses

# 写入地址文件
cat > "$NETWORK_DIR/addresses.action.params" <<EOFADDR
ACTION_TARGET_ADDRESS=$ACTION_TARGET_ADDRESS
LP_EXECUTOR_ADDRESS=$LP_EXECUTOR_ADDRESS
GROUP_ACTION_EXECUTOR_ADDRESS=$GROUP_ACTION_EXECUTOR_ADDRESS
GROUP_SERVICE_EXECUTOR_ADDRESS=$GROUP_SERVICE_EXECUTOR_ADDRESS
EOFADDR

echo "✓ Deployment completed and addresses saved"
