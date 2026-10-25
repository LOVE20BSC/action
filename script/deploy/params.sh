#!/usr/bin/env bash
# 参数文件载入器：允许在 *.params 里把长整数写成 <尾数>e<指数>（1e17、3e15）或带下划线
# 的分组写法（1_000_000），载入时展开为十进制再导出。
#
# 纯词法、无键表：新增或删除参数都不需要改这里，因此不存在「映射漏项」这种失效模式。
# 只有整体形如 <整数>e<整数> 的逗号分隔元素会被展开，其余原样保留；写错的写法留在环境
# 变量里，由 vm.envUint 在广播前报错——失败方向是响的，不会静默变成错值。
# 行尾注释（空白 + #）在展开前丢弃，整体带引号的值不参与注释剥离。本函数不用于 .account：
# 密码可能含 "#"。
# 四个仓（core/action/group-chat/dex）各持一份相同副本：各仓独立可部署，无法共享，改动需同步四处。

# 展开单个值（支持逗号分隔的多值，如 GROUP_ACTION_SPLITS）。
params_expand_value() {
    local value="$1" item out="" sep=""
    local -a items
    [ -n "$value" ] || return 0
    IFS=',' read -ra items <<<"$value" || true
    for item in "${items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        if [[ "$item" =~ ^([0-9][0-9_]*)[eE]([0-9]+)$ ]]; then
            # 尾数后补指数个 0：纯字符串操作，不受 64 位整数限制（1e28 亦然）。
            printf -v item '%s%*s' "${BASH_REMATCH[1]//_/}" "${BASH_REMATCH[2]}" ''
            item="${item// /0}"
        elif [[ "$item" =~ ^[0-9][0-9_]*$ ]]; then
            item="${item//_/}"
        fi
        # 逐项拼接，保持原文顺序与分隔。
        out="$out$sep$item"
        sep=","
    done
    printf '%s' "$out"
}

# 载入参数文件并导出。只认字面量：值可整体带引号，但不做变量展开或命令替换——
# 这样参数文件里出现 $ 或反引号时是字面内容，不会被静默展开成别的东西。
params_load() {
    local file="$1" line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
            '' | '#'*) continue ;;
        esac
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "Error: invalid key in $file: $key" >&2
            return 1
        fi
        if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
            value="${value#?}"
            value="${value%?}"
        else
            value="${value%%[[:space:]]#*}"
            value="${value%"${value##*[![:space:]]}"}"
        fi
        printf -v "$key" '%s' "$(params_expand_value "$value")"
        export "$key"
    done <"$file"
}
