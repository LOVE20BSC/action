#!/usr/bin/env bash
set -euo pipefail

# 部署与初始化正确性校验：只读配置与链上状态，可重复运行（forge inspect 会在本地编译并
# 刷新 out/cache，不写地址文件）。自行独立载入校验所需文件，
# 不依赖调用方预载环境：network.params 提供 RPC 与链 ID，addresses.core.params 提供期望的
# core 绑定，action.params 提供期望的 splits，addresses.action.params 提供待校验的已部署地址。
# 用法：script/deploy/21_check.sh <network>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# forge inspect 靠当前目录定位 foundry.toml，与 cast 不同：不切到项目根时
# 运行时代码比对会拿到空产物并误报「runtime unavailable」。
cd "$PROJECT_ROOT"

network="${1:?usage: script/deploy/21_check.sh <network>}"
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

# 地址文件的键集合必须与期望合约/库集合一致：键名漏改会让后续变量静默为空，
# 逐项 cast 调用要到很后面才以难以定位的形式失败，故在此显式断言。
address_file="$NETWORK_DIR/addresses.action.params"
CONTRACT_ADDRESS_FIELDS="ACTION_TARGET_ADDRESS GROUP_ACTION_EXECUTOR_ADDRESS GROUP_SERVICE_EXECUTOR_ADDRESS LP_EXECUTOR_ADDRESS"
GROUP_ACTION_LIBRARY_SPECS=(
    "GroupActionJoin src/GroupActionJoin.sol GROUP_ACTION_JOIN_LIBRARY_ADDRESS"
    "GroupActionManager src/GroupActionManager.sol GROUP_ACTION_MANAGER_LIBRARY_ADDRESS"
    "GroupActionVerify src/GroupActionVerify.sol GROUP_ACTION_VERIFY_LIBRARY_ADDRESS"
)
GROUP_SERVICE_LIBRARY_SPECS=(
    "GroupRecipients src/GroupRecipients.sol GROUP_RECIPIENTS_LIBRARY_ADDRESS"
)

GROUP_ACTION_LIBRARY_FIELDS=""
GROUP_ACTION_LIBRARY_ARGS=()
GROUP_SERVICE_LIBRARY_FIELDS=""
GROUP_SERVICE_LIBRARY_ARGS=()
ALL_LIBRARY_NAMES=()
ALL_LIBRARY_FIELDS=()
for spec in "${GROUP_ACTION_LIBRARY_SPECS[@]}"; do
    read -r lib_name lib_path lib_field <<< "$spec"
    GROUP_ACTION_LIBRARY_FIELDS+=" $lib_field"
    GROUP_ACTION_LIBRARY_ARGS+=(--libraries "$lib_path:$lib_name:${!lib_field:-}")
    ALL_LIBRARY_NAMES+=("$lib_name")
    ALL_LIBRARY_FIELDS+=("$lib_field")
done
for spec in "${GROUP_SERVICE_LIBRARY_SPECS[@]}"; do
    read -r lib_name lib_path lib_field <<< "$spec"
    GROUP_SERVICE_LIBRARY_FIELDS+=" $lib_field"
    GROUP_SERVICE_LIBRARY_ARGS+=(--libraries "$lib_path:$lib_name:${!lib_field:-}")
    ALL_LIBRARY_NAMES+=("$lib_name")
    ALL_LIBRARY_FIELDS+=("$lib_field")
done
GROUP_ACTION_LIBRARY_FIELDS=${GROUP_ACTION_LIBRARY_FIELDS# }
GROUP_SERVICE_LIBRARY_FIELDS=${GROUP_SERVICE_LIBRARY_FIELDS# }
expected_keys="$CONTRACT_ADDRESS_FIELDS $GROUP_ACTION_LIBRARY_FIELDS $GROUP_SERVICE_LIBRARY_FIELDS"
actual_keys=$(grep -oE '^[A-Z0-9_]+=' "$address_file" | sed 's/=$//' | sort | tr '\n' ' ' || true)
if [ "$actual_keys" != "$(printf '%s\n' $expected_keys | sort | tr '\n' ' ')" ]; then
    echo "Error: $address_file key set mismatch"
    echo "  expected: $(printf '%s\n' $expected_keys | sort | tr '\n' ' ')"
    echo "  actual:   $actual_keys"
    exit 1
fi

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

# 检查所有合约与库地址已设置且形如非零地址：格式错误留到逐项 cast 会以「未部署」的形式
# 报错，掩盖真正原因。判据与 31_verify.sh 保持一致。
for field in $expected_keys; do
    if [[ ! ${!field:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field:-} = 0x0000000000000000000000000000000000000000 ]]; then
        echo -e "${RED}✗ Error: $field is missing or invalid in $address_file${NC}"
        exit 1
    fi
done

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

# 仅检查地址出现无法识别同一 Executor 内的库互换，故按链接后的完整运行时代码比对。
verify_runtime_matches_artifact() {
    local contract_name=$1
    local address=$2
    shift 2

    local expected actual
    expected=$(forge inspect "$contract_name" deployedBytecode "$@" 2>/dev/null || true)
    actual=$(cast code "$address" --rpc-url "$RPC_URL" 2>/dev/null || true)
    if [ -z "$expected" ] || [ -z "$actual" ]; then
        echo -e "${RED}✗ $contract_name runtime unavailable at $address${NC}"
        return 1
    fi

    expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
    actual=$(printf '%s' "$actual" | tr 'A-F' 'a-f')
    if [ "$expected" != "$actual" ]; then
        echo -e "${RED}✗ $contract_name runtime does not match its build artifact${NC}"
        echo -e "    ${GRAY}${address}${NC}"
        return 1
    fi

    echo -e "  ${GREEN}✓${NC} ${contract_name} runtime matches build artifact"
    echo -e "    ${GRAY}${address}${NC}"
}

# 库的 runtime code 开头内嵌自身地址（部署时由 constructor 写入），编译产物里该位置是
# 20 字节零。直接比对会把每座已部署的库都判成不匹配，故先按入账地址替换这一处。
verify_library_runtime_matches_artifact() {
    local contract_name=$1
    local address=$2

    local expected actual placeholder self
    expected=$(forge inspect "$contract_name" deployedBytecode 2>/dev/null || true)
    actual=$(cast code "$address" --rpc-url "$RPC_URL" 2>/dev/null || true)
    if [ -z "$expected" ] || [ -z "$actual" ]; then
        echo -e "${RED}✗ $contract_name runtime unavailable at $address${NC}"
        return 1
    fi

    expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
    actual=$(printf '%s' "$actual" | tr 'A-F' 'a-f')
    placeholder="73$(printf '%040d' 0)"
    # 只替换第一处：四个库当前都只有 1 处。数量变了说明编译器布局变了，
    # 此时静默按第一处替换会把链上正确代码判成不匹配，故显式失败。
    local occurrences
    occurrences=$(printf '%s' "$expected" | grep -o "$placeholder" | wc -l | tr -d ' ' || true)
    if [ "$occurrences" -ne 1 ]; then
        echo -e "${RED}✗ $contract_name self-address placeholder count is $occurrences, expected 1${NC}"
        echo -e "    ${GRAY}library bytecode layout changed; revisit the substitution rule${NC}"
        return 1
    fi
    self=$(printf '%s' "$address" | tr 'A-F' 'a-f')
    expected=${expected/$placeholder/73${self#0x}}

    if [ "$expected" != "$actual" ]; then
        echo -e "${RED}✗ $contract_name runtime does not match its build artifact${NC}"
        echo -e "    ${GRAY}${address}${NC}"
        return 1
    fi

    echo -e "  ${GREEN}✓${NC} ${contract_name} runtime matches build artifact"
    echo -e "    ${GRAY}${address}${NC}"
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

# 地址上没有代码时不再跑 runtime 比对：同一个失败只计一次，避免「1 个合约未部署」
# 被报成 2 项失败。库循环用同样的口径。
verify_deployed_and_runtime() {
    local contract_name=$1
    local address=$2
    shift 2
    if ! verify_deployed "$contract_name" "$address"; then
        FAILED=$((FAILED + 1))
        return
    fi
    verify_runtime_matches_artifact "$contract_name" "$address" "$@" || ((FAILED+=1))
}

ACTUAL_CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
verify_value "CHAIN_ID" "$CHAIN_ID" "$ACTUAL_CHAIN_ID" || exit 1

# 1. 验证 ActionTarget
print_contract_header "1" "ActionTarget" "$ACTION_TARGET_ADDRESS"
verify_deployed_and_runtime "ActionTarget" "$ACTION_TARGET_ADDRESS"

ACTUAL_INIT=$(cast call "$ACTION_TARGET_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_INIT" || ((FAILED+=1))

ACTUAL_MINT=$(cast call "$ACTION_TARGET_ADDRESS" "mintAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "mintAddress" "$MINT_ADDRESS" "$ACTUAL_MINT" || ((FAILED+=1))

ACTUAL_VOTE=$(cast call "$ACTION_TARGET_ADDRESS" "voteAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "voteAddress" "$VOTE_ADDRESS" "$ACTUAL_VOTE" || ((FAILED+=1))

ACTUAL_SUBMIT=$(cast call "$ACTION_TARGET_ADDRESS" "submitAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "submitAddress" "$SUBMIT_ADDRESS" "$ACTUAL_SUBMIT" || ((FAILED+=1))

ACTUAL_MEMBER=$(cast call "$ACTION_TARGET_ADDRESS" "memberNFTAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "memberNFTAddress" "$MEMBER_NFT_ADDRESS" "$ACTUAL_MEMBER" || ((FAILED+=1))

ACTUAL_PHASE=$(cast call "$ACTION_TARGET_ADDRESS" "phaseAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "phaseAddress" "$PHASE_ADDRESS" "$ACTUAL_PHASE" || ((FAILED+=1))

# 2. 验证 LpExecutor
print_contract_header "2" "LpExecutor" "$LP_EXECUTOR_ADDRESS"
verify_deployed_and_runtime "LpExecutor" "$LP_EXECUTOR_ADDRESS"

ACTUAL_INIT=$(cast call "$LP_EXECUTOR_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_INIT" || ((FAILED+=1))

ACTUAL_TARGET=$(cast call "$LP_EXECUTOR_ADDRESS" "actionTarget()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "actionTarget" "$ACTION_TARGET_ADDRESS" "$ACTUAL_TARGET" || ((FAILED+=1))

# 3. 验证 GroupActionExecutor
print_contract_header "3" "GroupActionExecutor" "$GROUP_ACTION_EXECUTOR_ADDRESS"
verify_deployed_and_runtime "GroupActionExecutor" "$GROUP_ACTION_EXECUTOR_ADDRESS" \
    "${GROUP_ACTION_LIBRARY_ARGS[@]}"

ACTUAL_INIT=$(cast call "$GROUP_ACTION_EXECUTOR_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_INIT" || ((FAILED+=1))

ACTUAL_TARGET=$(cast call "$GROUP_ACTION_EXECUTOR_ADDRESS" "actionTarget()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "actionTarget" "$ACTION_TARGET_ADDRESS" "$ACTUAL_TARGET" || ((FAILED+=1))

# splits 以逗号分隔配置，cast 返回 "[a [1e17], b [4e17]]"：逐个元素去掉科学计数法标注与空格后比对
# （标注形如 [1e17]，不会误伤数组外层括号）
strip_sci_notation() {
    echo "$1" | sed -E 's/\[[0-9]+e[0-9]+\]//g' | tr -d ' '
}
ACTUAL_SPLITS=$(cast call "$GROUP_ACTION_EXECUTOR_ADDRESS" "SPLITS()(uint256[])" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
EXPECTED_SPLITS="[${GROUP_ACTION_SPLITS:-}]"
verify_value "SPLITS" "$(strip_sci_notation "$EXPECTED_SPLITS")" "$(strip_sci_notation "$ACTUAL_SPLITS")" || ((FAILED+=1))

# 4. 验证 GroupServiceExecutor
print_contract_header "4" "GroupServiceExecutor" "$GROUP_SERVICE_EXECUTOR_ADDRESS"
verify_deployed_and_runtime "GroupServiceExecutor" "$GROUP_SERVICE_EXECUTOR_ADDRESS" \
    "${GROUP_SERVICE_LIBRARY_ARGS[@]}"

ACTUAL_INIT=$(cast call "$GROUP_SERVICE_EXECUTOR_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_INIT" || ((FAILED+=1))

ACTUAL_TARGET=$(cast call "$GROUP_SERVICE_EXECUTOR_ADDRESS" "actionTarget()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "actionTarget" "$ACTION_TARGET_ADDRESS" "$ACTUAL_TARGET" || ((FAILED+=1))

for i in "${!ALL_LIBRARY_NAMES[@]}"; do
    field=${ALL_LIBRARY_FIELDS[$i]}
    lib_name=${ALL_LIBRARY_NAMES[$i]}
    if ! verify_deployed "$lib_name" "${!field}"; then
        FAILED=$((FAILED + 1))
        continue
    fi
    echo -e "  ${GREEN}✓${NC} ${lib_name} deployed"
    verify_library_runtime_matches_artifact "$lib_name" "${!field}" || ((FAILED+=1))
done

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
