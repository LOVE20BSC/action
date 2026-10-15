#!/usr/bin/env bash
set -euo pipefail

# 入口：纯编排。自身不 source 任何环境文件——三个步骤各自加载自己的输入，
# 统一 <step>.sh <network> 一种调用形态，步骤之间互不调用、互不依赖预载环境。
# 新增合约/模块时新建 one_click_deploy_<x>.sh 与自己的步骤脚本，对现有文件零改动。
# 用法：script/deploy/one_click_deploy.sh <network>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# 切换到项目根目录执行
cd "$PROJECT_ROOT"

network="${1:?usage: script/deploy/one_click_deploy.sh <network>}"

NETWORK_DIR="$PROJECT_ROOT/script/network/$network"
if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

# keystore 密码整次运行只解析一次：先重置（不继承调用方环境里的旧值，避免上次运行的
# 残留密码静默复用），再读 .account 的密码行；两者都没有则交互输入一次并导出，部署
# 步骤沿用（多模块仓库的多个部署步骤不会各弹一次窗）。步骤单独运行时仍自行按
# 环境变量 → .account → 交互 解析。入口只读取密码行，不 source 配置文件。
export KEYSTORE_PASSWORD=""
if [ ! -f "$NETWORK_DIR/.account" ]; then
    echo "Error: Missing required configuration: $NETWORK_DIR/.account"
    exit 1
fi
configured_password=$(grep -E '^KEYSTORE_PASSWORD=' "$NETWORK_DIR/.account" | tail -1 | cut -d= -f2- || true)
if [ -n "$configured_password" ]; then
    export KEYSTORE_PASSWORD="$configured_password"
fi
if [ -z "${KEYSTORE_PASSWORD:-}" ]; then
    if ! command -v osascript >/dev/null 2>&1; then
        echo "Error: KEYSTORE_PASSWORD is empty and osascript is unavailable; set it in $NETWORK_DIR/.account for non-interactive use." >&2
        exit 1
    fi
    KEYSTORE_PASSWORD="$(osascript <<APPLESCRIPT
text returned of (display dialog "Enter keystore password for deployment:" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK")
APPLESCRIPT
)"
    export KEYSTORE_PASSWORD
fi

# 部署与校验是分开的步骤，校验失败不应覆盖上次已保存的地址：先备份，校验通过后丢弃，失败则回滚。
ADDRESS_FILE="$NETWORK_DIR/addresses.action.params"
BACKUP_FILE="$(mktemp)"
had_address_file=0
if [ -f "$ADDRESS_FILE" ]; then
    cp "$ADDRESS_FILE" "$BACKUP_FILE"
    had_address_file=1
fi

# 步骤一：合约部署与初始化（自载入部署输入）。失败时地址文件尚未写入，无需回滚。
bash "$SCRIPT_DIR/11_deploy.sh" "$network"

# 步骤二：校验部署与初始化是否正确（自载入校验文件，失败回滚已保存地址）。
if ! bash "$SCRIPT_DIR/21_check.sh" "$network"; then
    if [ "$had_address_file" = 1 ]; then
        cp "$BACKUP_FILE" "$ADDRESS_FILE"
    else
        rm -f "$ADDRESS_FILE"
    fi
    rm -f "$BACKUP_FILE"
    echo "Error: post-deployment check failed; the previously saved addresses were restored."
    exit 1
fi
rm -f "$BACKUP_FILE"

# 步骤三：合约开源验证（自载入地址文件）。链不支持开源验证时自行跳过。
bash "$SCRIPT_DIR/31_verify.sh" "$network"

echo "✓ Deployment completed: $network"
