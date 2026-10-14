#!/usr/bin/env bash
set -euo pipefail

# 部署与初始化正确性校验：只读配置与链上状态，可重复运行。自行独立载入校验所需文件，
# 不依赖调用方预载环境：network.params 提供 RPC 与链 ID，addresses.core.params 提供期望的
# core 绑定，action.params 提供期望的 splits，addresses.action.params 提供待校验的已部署地址。
# 用法：script/deploy/99_check.sh <network>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

network="${1:?usage: script/deploy/99_check.sh <network>}"
NETWORK_DIR="$PROJECT_ROOT/script/network/$network"
if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

if [ ! -f "$NETWORK_DIR/addresses.action.params" ]; then
    echo "Error: Missing $NETWORK_DIR/addresses.action.params; run one_click_deploy.sh first"
    exit 1
fi

set -a
source "$NETWORK_DIR/network.params"
source "$NETWORK_DIR/addresses.core.params"
source "$NETWORK_DIR/action.params"
source "$NETWORK_DIR/addresses.action.params"
set +a

# 颜色定义
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

# 检查所有合约地址是否已设置
if [ -z "${ACTIONTARGET_ADDRESS:-}" ] || [ -z "${LPEXECUTOR_ADDRESS:-}" ] || \
   [ -z "${GROUPACTIONEXECUTOR_ADDRESS:-}" ] || [ -z "${GROUPSERVICEEXECUTOR_ADDRESS:-}" ]; then
    echo -e "${RED}✗ Error: Not all contract addresses are set${NC}"
    exit 1
fi

# 辅助函数：标准化输出（去掉引号和科学计数法标记）
normalize_output() {
    local value="$1"
    # 去掉首尾引号
    value="${value%\"}"
    value="${value#\"}"
    # 去掉科学计数法标记 [1e18]
    value="${value% \[*\]}"
    echo "$value"
}

# 辅助函数：验证单个值
verify_value() {
    local field_name=$1
    local expected=$2
    local actual=$3

    # 标准化两个值
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

# 辅助函数：验证合约是否部署
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

# 辅助函数：打印合约头部
print_contract_header() {
    local num=$1
    local name=$2
    local address=$3
    echo ""
    echo -e "${BLUE}[$num/4]${NC} ${CYAN}${name}${NC}"
    echo -e "${GRAY}      ${address}${NC}"
}

FAILED=0
ACTUAL_CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
verify_value "CHAIN_ID" "$CHAIN_ID" "$ACTUAL_CHAIN_ID" || exit 1

# 1. 验证 ActionTarget
print_contract_header "1" "ActionTarget" "$ACTIONTARGET_ADDRESS"
verify_deployed "ActionTarget" "$ACTIONTARGET_ADDRESS" || ((FAILED+=1))

ACTUAL_INIT=$(cast call "$ACTIONTARGET_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_INIT" || ((FAILED+=1))

ACTUAL_MINT=$(cast call "$ACTIONTARGET_ADDRESS" "mintAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "mintAddress" "$MINT_ADDRESS" "$ACTUAL_MINT" || ((FAILED+=1))

ACTUAL_VOTE=$(cast call "$ACTIONTARGET_ADDRESS" "voteAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "voteAddress" "$VOTE_ADDRESS" "$ACTUAL_VOTE" || ((FAILED+=1))

ACTUAL_SUBMIT=$(cast call "$ACTIONTARGET_ADDRESS" "submitAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "submitAddress" "$SUBMIT_ADDRESS" "$ACTUAL_SUBMIT" || ((FAILED+=1))

ACTUAL_MEMBER=$(cast call "$ACTIONTARGET_ADDRESS" "memberNFTAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "memberNFTAddress" "$MEMBERNFT_ADDRESS" "$ACTUAL_MEMBER" || ((FAILED+=1))

ACTUAL_PHASE=$(cast call "$ACTIONTARGET_ADDRESS" "phaseAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "phaseAddress" "$PHASE_ADDRESS" "$ACTUAL_PHASE" || ((FAILED+=1))

# 2. 验证 LpExecutor
print_contract_header "2" "LpExecutor" "$LPEXECUTOR_ADDRESS"
verify_deployed "LpExecutor" "$LPEXECUTOR_ADDRESS" || ((FAILED+=1))

ACTUAL_INIT=$(cast call "$LPEXECUTOR_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_INIT" || ((FAILED+=1))

ACTUAL_TARGET=$(cast call "$LPEXECUTOR_ADDRESS" "actionTarget()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "actionTarget" "$ACTIONTARGET_ADDRESS" "$ACTUAL_TARGET" || ((FAILED+=1))

# 3. 验证 GroupActionExecutor
print_contract_header "3" "GroupActionExecutor" "$GROUPACTIONEXECUTOR_ADDRESS"
verify_deployed "GroupActionExecutor" "$GROUPACTIONEXECUTOR_ADDRESS" || ((FAILED+=1))

ACTUAL_INIT=$(cast call "$GROUPACTIONEXECUTOR_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_INIT" || ((FAILED+=1))

ACTUAL_TARGET=$(cast call "$GROUPACTIONEXECUTOR_ADDRESS" "actionTarget()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "actionTarget" "$ACTIONTARGET_ADDRESS" "$ACTUAL_TARGET" || ((FAILED+=1))

# splits 以逗号分隔配置，cast 返回 "[a [1e17], b [4e17]]"：逐个元素去掉科学计数法标注与空格后比对
# （标注形如 [1e17]，不会误伤数组外层括号）
strip_sci_notation() {
    echo "$1" | sed -E 's/\[[0-9]+e[0-9]+\]//g' | tr -d ' '
}
ACTUAL_SPLITS=$(cast call "$GROUPACTIONEXECUTOR_ADDRESS" "SPLITS()(uint256[])" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
EXPECTED_SPLITS="[${GROUP_ACTION_SPLITS:-}]"
verify_value "SPLITS" "$(strip_sci_notation "$EXPECTED_SPLITS")" "$(strip_sci_notation "$ACTUAL_SPLITS")" || ((FAILED+=1))

# 4. 验证 GroupServiceExecutor
print_contract_header "4" "GroupServiceExecutor" "$GROUPSERVICEEXECUTOR_ADDRESS"
verify_deployed "GroupServiceExecutor" "$GROUPSERVICEEXECUTOR_ADDRESS" || ((FAILED+=1))

ACTUAL_INIT=$(cast call "$GROUPSERVICEEXECUTOR_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_INIT" || ((FAILED+=1))

ACTUAL_TARGET=$(cast call "$GROUPSERVICEEXECUTOR_ADDRESS" "actionTarget()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "actionTarget" "$ACTIONTARGET_ADDRESS" "$ACTUAL_TARGET" || ((FAILED+=1))

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
