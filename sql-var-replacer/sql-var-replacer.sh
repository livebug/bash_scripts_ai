#!/usr/bin/env bash
#===============================================================================
# sql-var-replacer.sh — 识别 .sql 文件中的 ${变量} 并交互式替换
#
# 用法:
#   ./sql-var-replacer.sh <xxx.sql>              # 交互式替换，输出到带时间戳的临时文件
#   ./sql-var-replacer.sh <xxx.sql> -o out.sql   # 指定输出文件
#   ./sql-var-replacer.sh <xxx.sql> --stdout     # 输出到 stdout（方便管道）
#   ./sql-var-replacer.sh <xxx.sql> --batch      # 非交互模式，使用历史值或空值
#
# 支持的变量格式:
#   ${VAR}              — 无默认值，交互模式下必须输入
#
# 历史记录:
#   执行目录下的 .sql-var-history 文件保存上次输入的值
#   下次遇到同名变量时自动读取作为默认值，回车使用历史值，输入新值则更新历史
#===============================================================================

set -euo pipefail

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- 帮助信息 ---
usage() {
    cat <<EOF
${BOLD}用法:${NC}  $(basename "$0") <xxx.sql> [选项]

${BOLD}选项:${NC}
  -o, --output FILE    指定输出文件路径（默认：带时间戳的临时文件）
  -s, --stdout         输出到标准输出（方便管道处理）
  -b, --batch          非交互模式：跳过提示，使用默认值或空值
  -h, --help           显示此帮助信息

${BOLD}支持的变量格式:${NC}
  \${VAR}                无默认值，交互模式下必须输入

${BOLD}历史记录:${NC}
  执行目录下的 ${CYAN}.sql-var-history${NC} 文件保存上次输入的值
  下次遇到同名变量时自动读取作为默认值，回车使用历史值，输入新值则更新历史

${BOLD}示例:${NC}
  ./sql-var-replacer.sh deploy.sql
  ./sql-var-replacer.sh deploy.sql -o ready.sql
  ./sql-var-replacer.sh deploy.sql --stdout | mysql -h host -u user -p
  ./sql-var-replacer.sh deploy.sql --batch | mysql -h host -u user -p
EOF
    exit 0
}

# --- 解析参数 ---
INPUT_FILE=""
OUTPUT_FILE=""
TO_STDOUT=false
BATCH_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -s|--stdout)
            TO_STDOUT=true
            shift
            ;;
        -b|--batch)
            BATCH_MODE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo -e "${RED}未知选项: $1${NC}" >&2
            usage
            ;;
        *)
            INPUT_FILE="$1"
            shift
            ;;
    esac
done

# --- 校验输入 ---
if [[ -z "$INPUT_FILE" ]]; then
    echo -e "${RED}错误: 请指定 .sql 文件${NC}" >&2
    usage
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    echo -e "${RED}错误: 文件不存在: $INPUT_FILE${NC}" >&2
    exit 1
fi

# --- 确定输出文件 ---
if [[ "$TO_STDOUT" == false && -z "$OUTPUT_FILE" ]]; then
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    BASENAME=$(basename "$INPUT_FILE" .sql)
    OUTPUT_FILE="${BASENAME}_${TIMESTAMP}.sql"
fi

# --- 历史记录文件 ---
HISTORY_FILE="$(pwd)/.sql-var-history"

# 加载历史记录
declare -A HIST_VALUES
if [[ -f "$HISTORY_FILE" ]]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        HIST_VALUES["$key"]="$value"
    done < "$HISTORY_FILE"
fi

# --- 提取所有 ${VAR} 变量（只匹配纯 ${VAR} 格式）---
echo -e "${CYAN}正在扫描变量...${NC}" >&2

mapfile -t VAR_NAMES < <(grep -Po '\$\{[a-zA-Z_][a-zA-Z0-9_]*\}' "$INPUT_FILE" \
    | sed 's/^\${//;s/}$//' \
    | sort -u || true)

if [[ ${#VAR_NAMES[@]} -eq 0 ]]; then
    echo -e "${GREEN}未发现任何 \${变量}，直接复制文件。${NC}" >&2
    if [[ "$TO_STDOUT" == true ]]; then
        cat "$INPUT_FILE"
    else
        cp "$INPUT_FILE" "$OUTPUT_FILE"
        echo -e "${GREEN}已输出到: $OUTPUT_FILE${NC}" >&2
    fi
    exit 0
fi

# --- 显示扫描结果 ---
echo -e "${BOLD}发现 ${#VAR_NAMES[@]} 个变量:${NC}" >&2
for v in "${VAR_NAMES[@]}"; do
    if [[ -n "${HIST_VALUES[$v]+isset}" ]]; then
        echo -e "  ${YELLOW}\${${v}}${NC}  ${GREEN}(历史: ${HIST_VALUES[$v]})${NC}" >&2
    else
        echo -e "  ${YELLOW}\${${v}}${NC}  ${RED}(必填)${NC}" >&2
    fi
done
echo "" >&2

# --- 收集变量值 ---
declare -A VAR_VALUES

if [[ "$BATCH_MODE" == true ]]; then
    echo -e "${CYAN}批处理模式：使用历史值或空值${NC}" >&2
    for v in "${VAR_NAMES[@]}"; do
        VAR_VALUES["$v"]="${HIST_VALUES[$v]:-}"
    done
else
    echo -e "${CYAN}请输入变量值（回车使用历史值，输入新值覆盖）:${NC}" >&2
    echo -e "${CYAN}──────────────────────────────────────${NC}" >&2

    # 交互模式下从 /dev/tty 读取，避免管道/stdin 重定向干扰
    for v in "${VAR_NAMES[@]}"; do
        if [[ -n "${HIST_VALUES[$v]+isset}" ]]; then
            # 有历史值，作为默认值
            printf "${BOLD}%s${NC} ${GREEN}[%s]${NC}: " "$v" "${HIST_VALUES[$v]}" >&2
            read -r val < /dev/tty
            VAR_VALUES["$v"]="${val:-${HIST_VALUES[$v]}}"
        else
            # 无历史值，必须输入
            while true; do
                printf "${BOLD}%s${NC}: " "$v" >&2
                read -r val < /dev/tty
                if [[ -n "$val" ]]; then
                    VAR_VALUES["$v"]="$val"
                    break
                else
                    echo -e "  ${RED}此变量为必填，请输入值${NC}" >&2
                fi
            done
        fi
    done

    echo -e "${CYAN}──────────────────────────────────────${NC}" >&2
    echo "" >&2
fi

# --- 保存历史记录（合并新值，跳过空值）---
for v in "${VAR_NAMES[@]}"; do
    if [[ -n "${VAR_VALUES[$v]}" ]]; then
        HIST_VALUES["$v"]="${VAR_VALUES[$v]}"
    fi
done

> "$HISTORY_FILE"
for v in "${!HIST_VALUES[@]}"; do
    echo "${v}=${HIST_VALUES[$v]}" >> "$HISTORY_FILE"
done

# --- 执行替换 ---
echo -e "${CYAN}正在替换变量...${NC}" >&2

# 构建 sed 替换脚本
SED_SCRIPT=""
for v in "${VAR_NAMES[@]}"; do
    val="${VAR_VALUES[$v]}"
    # 转义 sed 特殊字符：& / \
    escaped_val="${val//&/\\&}"
    escaped_val="${escaped_val//\//\\/}"
    escaped_val="${escaped_val//\\/\\\\}"

    SED_SCRIPT+="s|\\\$\\{$v\\}|$escaped_val|g;"
done

# 执行替换并输出
if [[ "$TO_STDOUT" == true ]]; then
    sed -E "$SED_SCRIPT" "$INPUT_FILE"
    echo -e "${GREEN}✓ 替换完成（输出到 stdout）${NC}" >&2
else
    sed -E "$SED_SCRIPT" "$INPUT_FILE" > "$OUTPUT_FILE"
    echo -e "${GREEN}✓ 替换完成 → ${BOLD}${OUTPUT_FILE}${NC}" >&2
    echo "" >&2
    echo -e "${CYAN}提示: 可直接用管道处理此文件，例如:${NC}" >&2
    echo -e "  cat ${OUTPUT_FILE} | mysql -h host -u user -p" >&2
    echo -e "  cat ${OUTPUT_FILE} | psql -h host -U user -d db" >&2
fi
