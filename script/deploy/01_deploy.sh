#!/usr/bin/env bash
set -euo pipefail

# 前置：环境已由入口脚本载入（source 00_init.sh <network>）；本步骤不自行载入。
echo "=== Deploying Action Contracts to $network ==="

# 准备部署日志
DEPLOY_LOG=$(mktemp)
trap "rm -f $DEPLOY_LOG" EXIT

# GroupActionExecutor 的 splits 由 action.params 以逗号分隔提供，空值即空数组。
SPLITS_LITERAL="[${GROUP_ACTION_SPLITS:-}]"

# 构建 forge script 命令
FORGE_CMD=(forge script script/deploy/DeployAction.s.sol:DeployAction --sig "run(uint256[])" "$SPLITS_LITERAL" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --broadcast --slow -vvv)

# 公共网络使用 Keystore；仅本地链允许节点托管账户签名。
if [[ -n "${KEYSTORE_ACCOUNT:-}" ]]; then
    FORGE_CMD+=(--account "$KEYSTORE_ACCOUNT")
    if [[ -n "${ACCOUNT_ADDRESS:-}" ]]; then
        FORGE_CMD+=(--sender "$ACCOUNT_ADDRESS")
    fi
    # .account 可选配置 KEYSTORE_PASSWORD：非空则直接用于解锁 keystore，部署全程无交互；
    # 未配置或留空则不传该参数，由 forge 在终端询问密码。
    if [[ -n "${KEYSTORE_PASSWORD:-}" ]]; then
        FORGE_CMD+=(--password "$KEYSTORE_PASSWORD")
    fi
elif [[ "$CHAIN_ID" = "31337" && -n "${ACCOUNT_ADDRESS:-}" ]]; then
    FORGE_CMD+=(--sender "$ACCOUNT_ADDRESS" --unlocked)
else
    echo "Error: Set KEYSTORE_ACCOUNT in .account (public RPCs cannot sign with --unlocked)."
    exit 1
fi

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
ACTIONTARGET_ADDRESS=$(grep "ACTIONTARGET_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
LPEXECUTOR_ADDRESS=$(grep "LPEXECUTOR_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
GROUPACTIONEXECUTOR_ADDRESS=$(grep "GROUPACTIONEXECUTOR_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
GROUPSERVICEEXECUTOR_ADDRESS=$(grep "GROUPSERVICEEXECUTOR_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)

require_action_addresses

# 写入地址文件
cat > "$NETWORK_DIR/addresses.action.params" <<EOFADDR
ACTIONTARGET_ADDRESS=$ACTIONTARGET_ADDRESS
LPEXECUTOR_ADDRESS=$LPEXECUTOR_ADDRESS
GROUPACTIONEXECUTOR_ADDRESS=$GROUPACTIONEXECUTOR_ADDRESS
GROUPSERVICEEXECUTOR_ADDRESS=$GROUPSERVICEEXECUTOR_ADDRESS
EOFADDR

echo "✓ Deployment completed and addresses saved"
