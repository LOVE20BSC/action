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

# 上一次异常退出可能留下地址临时文件；只清理本模块的隐藏临时模式，不碰正式地址文件。
rm -f "$NETWORK_DIR/.addresses.action.params."*

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

# 准备部署日志与密码文件。广播一旦发出，后续任何校验失败都意味着「合约已上链但地址未记录」：
# 此时必须留下日志与产物路径供人工恢复；广播前失败则只清理本次的临时文件，不误报已上链。
# 密码经临时文件传给 forge：--password 会把明文放进进程参数，同机其他用户可直接读到。
# trap 在写入密码之前安装，chmod/printf 失败也不会留下明文。
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

# GroupActionExecutor 的 splits 由 action.params 以逗号分隔提供，空值即空数组。
SPLITS_LITERAL="[${GROUP_ACTION_SPLITS:-}]"

# 构建 forge script 命令：keystore 签名（本地链同样如此，不用 --unlocked）。
FORGE_CMD=(forge script script/deploy/DeployAction.s.sol:DeployAction --sig "run(uint256[])" "$SPLITS_LITERAL" --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --account "$KEYSTORE_ACCOUNT" --sender "$ACCOUNT_ADDRESS" --password-file "$PASSWORD_FILE" --broadcast --slow -vvv)

# 执行部署
cd "$PROJECT_ROOT"
DEPLOY_START_EPOCH_SECONDS=$(date +%s)
DEPLOY_ATTEMPTED=1
if ! { "${FORGE_CMD[@]}" 2>&1 | tee "$DEPLOY_LOG"; }; then
    echo "Error: Deployment failed."
    exit 1
fi
# 密码只在本次 forge 调用期间需要，广播结束立即删除，缩短暴露窗口。
rm -f "$PASSWORD_FILE"

# 从部署输出中提取地址（DeployAction.s.sol 的 _logDeploymentSummary 输出）。
# grep 无匹配会让管道在 set -e 下静默中止，故逐个容错取值，缺项交由 require_contract_addresses 报错。
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

# 写入地址文件
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
