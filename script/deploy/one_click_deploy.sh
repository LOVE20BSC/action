#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# 切换到项目根目录执行
cd "$PROJECT_ROOT"

network="${1:-}"
if [ -z "$network" ]; then
    echo "Error: network name is required (e.g. anvil31337_dev)"
    exit 1
fi

# 入口是唯一编排者：载入环境一次，再依次调用各单步骤脚本；步骤之间互不调用，且以子进程方式运行
# （步骤内的 exit 不会影响本脚本）。单独执行某一步时，由调用方先 source 00_init.sh <network>。
source "$SCRIPT_DIR/00_init.sh" "$network"

# 部署与校验是分开的步骤，校验失败不应覆盖上次已保存的地址：先备份，校验通过后丢弃，失败则回滚。
ADDRESS_FILE="$NETWORK_DIR/addresses.action.params"
BACKUP_FILE="$(mktemp)"
had_address_file=0
if [ -f "$ADDRESS_FILE" ]; then
    cp "$ADDRESS_FILE" "$BACKUP_FILE"
    had_address_file=1
fi

# 步骤一：合约部署与初始化。失败时地址文件尚未写入，无需回滚。
bash "$SCRIPT_DIR/01_deploy.sh"

# 刷新部署产物：环境是部署前载入的，01_deploy.sh 刚写入的地址需要重新载入后供 verify.sh 使用。
# 99_check.sh 自行载入校验文件，入口只传网络名。
set -a
source "$ADDRESS_FILE"
set +a

# 步骤二：校验部署与初始化是否正确（自载入，失败回滚已保存地址）。
if ! bash "$SCRIPT_DIR/99_check.sh" "$network"; then
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

# 步骤三：合约开源验证。链不支持开源验证时 verify.sh 自行跳过。
bash "$SCRIPT_DIR/verify.sh"

echo "✓ Deployment completed: $network"
