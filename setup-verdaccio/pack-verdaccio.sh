#!/bin/bash
# ============================================================
# pack-verdaccio.sh — 打包 Verdaccio 缓存的 npm 包，用于内网传输
# ============================================================
# 用法:
#   bash pack-verdaccio.sh                          # 打包全部缓存
#   bash pack-verdaccio.sh --recent 7               # 只打包最近 7 天
#   bash pack-verdaccio.sh --recent 1 --output /tmp # 最近 1 天，输出到 /tmp
#   bash pack-verdaccio.sh --no-metadata            # 只打包 .tgz，不打包 package.json
#
# 输出:
#   verdaccio-offline-YYYYMMDD-HHmmss.tar.gz        # 可直接迁移的离线包
#   verdaccio-offline-YYYYMMDD-HHmmss/              # 解压目录，
#     ├── storage/          ← 拷贝到目标机器的 storage 目录
#     ├── config.yaml       ← 内网环境可用的 Verdaccio 配置
#     └── setup-intranet.sh ← 在目标内网机器上执行的还原脚本
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${CYAN}==>${NC} ${CYAN}$*${NC}"; }

# ---- 默认值 ----
STORAGE_DIR="${HOME}/.local/share/verdaccio/storage"
CONFIG_FILE="${HOME}/.config/verdaccio/config.yaml"
OUTPUT_DIR="$(pwd)"
RECENT_DAYS=""          # 空=全部
EXCLUDE_METADATA=false  # 默认包含 package.json 元数据
DRY_RUN=false

# ---- 解析参数 ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --recent)
            RECENT_DAYS="$2"
            shift 2
            ;;
        --output|-o)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --no-metadata)
            EXCLUDE_METADATA=true
            shift
            ;;
        --dry-run|-n)
            DRY_RUN=true
            shift
            ;;
        --storage)
            STORAGE_DIR="$2"
            shift 2
            ;;
        --config|-c)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --recent N      只打包最近 N 天修改的包"
            echo "  --output DIR    输出目录 (默认: 当前目录)"
            echo "  --no-metadata   不包含 package.json 元数据 (只打 .tgz)"
            echo "  --dry-run       预览将要打包的文件，不实际执行"
            echo "  --storage DIR   Verdaccio 存储目录 (默认: ~/.local/share/verdaccio/storage)"
            echo "  --config FILE   Verdaccio 配置文件 (默认: ~/.config/verdaccio/config.yaml)"
            echo "  --help          显示帮助"
            exit 0
            ;;
        *)
            error "未知选项: $1"
            exit 1
            ;;
    esac
done

# ---- 验证 ----
if [ ! -d "${STORAGE_DIR}" ]; then
    error "存储目录不存在: ${STORAGE_DIR}"
    error "请确认 Verdaccio 已正确安装并运行过"
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

# ---- 生成时间戳 ----
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PACK_NAME="verdaccio-offline-${TIMESTAMP}"
WORK_DIR="${OUTPUT_DIR}/${PACK_NAME}"
ARCHIVE_NAME="${PACK_NAME}.tar.gz"

# ============================================================
step "1/4  收集包文件"
# ============================================================

# 统计信息
TOTAL_TGZ=0
TOTAL_META=0
TOTAL_SIZE=0

# 构建 find 命令的时间过滤条件
if [ -n "${RECENT_DAYS}" ]; then
    FIND_FILTER="-mtime -${RECENT_DAYS}"
    info "过滤条件: 最近 ${RECENT_DAYS} 天修改过的文件"
else
    FIND_FILTER=""
    info "模式: 打包全部缓存"
fi

# 创建临时文件列表
TEMP_LIST=$(mktemp)
trap "rm -f ${TEMP_LIST}" EXIT

# 收集 .tgz 文件
while IFS= read -r -d '' tgz_file; do
    echo "${tgz_file}" >> "${TEMP_LIST}"
    TOTAL_TGZ=$((TOTAL_TGZ + 1))
    fsize=$(stat -c%s "${tgz_file}" 2>/dev/null || echo 0)
    TOTAL_SIZE=$((TOTAL_SIZE + fsize))
done < <(find "${STORAGE_DIR}" -name "*.tgz" -type f ${FIND_FILTER} -print0 2>/dev/null || true)

# 收集 package.json 元数据文件
if [ "${EXCLUDE_METADATA}" = false ]; then
    while IFS= read -r -d '' meta_file; do
        echo "${meta_file}" >> "${TEMP_LIST}"
        TOTAL_META=$((TOTAL_META + 1))
        fsize=$(stat -c%s "${meta_file}" 2>/dev/null || echo 0)
        TOTAL_SIZE=$((TOTAL_SIZE + fsize))
    done < <(find "${STORAGE_DIR}" -name "package.json" -type f ${FIND_FILTER} -print0 2>/dev/null || true)

    # 收集 .verdaccio-db.json 等根级关键文件
    while IFS= read -r -d '' dbfile; do
        echo "${dbfile}" >> "${TEMP_LIST}"
        TOTAL_META=$((TOTAL_META + 1))
    done < <(find "${STORAGE_DIR}" -maxdepth 1 -name ".verdaccio-db*" -type f -print0 2>/dev/null || true)
fi

TOTAL_FILES=$((TOTAL_TGZ + TOTAL_META))
TOTAL_SIZE_MB=$(echo "scale=1; ${TOTAL_SIZE} / 1048576" | bc 2>/dev/null || echo "0")

echo ""
info "找到:  ${TOTAL_TGZ} 个 .tgz 包 + ${TOTAL_META} 个元数据 = ${TOTAL_FILES} 个文件"
info "大小:  ~${TOTAL_SIZE_MB} MB"

if [ "${TOTAL_FILES}" -eq 0 ]; then
    warn "没有找到任何符合条件的文件，退出"
    exit 0
fi

# ============================================================
step "2/4  构建离线包目录"
# ============================================================

if [ "${DRY_RUN}" = true ]; then
    echo ""
    info "=== 预览打包文件列表 ==="
    cat "${TEMP_LIST}" | while IFS= read -r f; do
        rel="${f#${STORAGE_DIR}/}"
        echo "  storage/${rel}"
    done
    echo ""
    info "--- 预览结束 (dry-run 模式，未实际打包) ---"
    rm -f "${TEMP_LIST}"
    exit 0
fi

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}/storage"

# 复制文件，保持目录结构
info "正在复制文件..."
copied=0
while IFS= read -r src_file; do
    rel_path="${src_file#${STORAGE_DIR}/}"
    dest_file="${WORK_DIR}/storage/${rel_path}"
    mkdir -p "$(dirname "${dest_file}")"
    cp "${src_file}" "${dest_file}"
    copied=$((copied + 1))
done < "${TEMP_LIST}"
rm -f "${TEMP_LIST}"

info "已复制 ${copied} 个文件到 ${WORK_DIR}/storage/"

# ============================================================
step "3/4  生成配套文件"
# ============================================================

# -- 生成内网 Verdaccio 配置 --
cat > "${WORK_DIR}/config.yaml" << 'YAMLEOF'
# ========================================
# 内网 Verdaccio 配置 — 离线/隔离网络使用
# ========================================
# 使用方式:
#   verdaccio --config ./config.yaml
#
# 如果你在内网也有自己的上游镜像，可以在 uplinks 中添加

storage: ./storage

# 如果内网完全离线，可以不配置 uplinks（仅使用本地缓存）
# 如果内网有上游仓库，取消下面的注释并修改 URL：
# uplinks:
#   internal:
#     url: http://your-internal-registry:4873
#     maxage: 30m
#
# packages:
#   '**':
#     access: $all
#     publish: $authenticated
#     proxy: internal

packages:
  '**':
    access: $all
    publish: $authenticated
    # proxy: no-query   # 离线模式：不查询上游

web:
  enable: true
  title: 内网 npm 仓库

server:
  listen:
    - host: 0.0.0.0
      port: 4873

log:
  - { type: stdout, format: pretty, level: http }

auth:
  htpasswd:
    file: ./htpasswd
    max_users: -1
    algorithm: bcrypt
    rounds: 10

security:
  api:
    jwt:
      sign:
        expiresIn: 7d

middlewares:
  audit:
    enabled: true
YAMLEOF

# -- 生成内网还原脚本 --
cat > "${WORK_DIR}/setup-intranet.sh" << 'SCRIPTEOF'
#!/bin/bash
# ============================================================
# setup-intranet.sh — 在内网/离线环境中还原 Verdaccio 仓库
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Verdaccio 内网仓库还原脚本 ==="
echo ""

# 检查 verdaccio
if ! command -v verdaccio &>/dev/null; then
    echo "[INFO] Verdaccio 未安装，正在安装..."
    npm install -g verdaccio
fi

# 准备目录
VERDACCIO_STORAGE="${HOME}/.local/share/verdaccio/storage"
VERDACCIO_CONFIG="${HOME}/.config/verdaccio"

mkdir -p "${VERDACCIO_STORAGE}"
mkdir -p "${VERDACCIO_CONFIG}"

echo "[INFO] 正在复制缓存包..."
cp -r "${SCRIPT_DIR}/storage/"* "${VERDACCIO_STORAGE}/" 2>/dev/null || true

echo "[INFO] 正在复制配置..."
cp "${SCRIPT_DIR}/config.yaml" "${VERDACCIO_CONFIG}/config.yaml"

# systemd 用户服务
NODE_BIN_DIR="$(dirname "$(command -v node)")"
mkdir -p "${HOME}/.config/systemd/user"

cat > "${HOME}/.config/systemd/user/verdaccio.service" << UNITEOF
[Unit]
Description=Verdaccio - 内网 npm 仓库
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${NODE_BIN_DIR}/verdaccio --config ${VERDACCIO_CONFIG}/config.yaml
Restart=on-failure
RestartSec=5s
Environment=PATH=${NODE_BIN_DIR}:/usr/local/bin:/usr/bin:/bin
Environment=HOME=${HOME}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=verdaccio

[Install]
WantedBy=default.target
UNITEOF

systemctl --user daemon-reload
systemctl --user enable verdaccio
systemctl --user restart verdaccio

# 配置 npm
npm config set registry http://localhost:4873

echo ""
echo "=========================================="
echo "  ✓ 内网仓库还原完成！"
echo "  仓库地址: http://localhost:4873"
echo "  Web 界面: http://localhost:4873"
echo "=========================================="
echo ""
SCRIPTEOF

chmod +x "${WORK_DIR}/setup-intranet.sh"

# -- 生成 README --
cat > "${WORK_DIR}/README.md" << READMEEOF
# Verdaccio 离线包

生成时间: $(date '+%Y-%m-%d %H:%M:%S')
来源机器: $(hostname)
包统计:   ${TOTAL_TGZ} 个 .tgz + ${TOTAL_META} 个元数据

## 内网还原步骤

### 方式一：一键还原（推荐）

```bash
tar xzf ${ARCHIVE_NAME}
cd ${PACK_NAME}
bash setup-intranet.sh
```

### 方式二：手动还原

```bash
# 1. 解压
tar xzf ${ARCHIVE_NAME}

# 2. 复制缓存包到 Verdaccio 存储目录
cp -r ${PACK_NAME}/storage/* ~/.local/share/verdaccio/storage/

# 3. 使用离线配置启动 Verdaccio
verdaccio --config ${PACK_NAME}/config.yaml
```

### 方式三：直接用离线配置启动（不解压到系统目录）

```bash
tar xzf ${ARCHIVE_NAME}
cd ${PACK_NAME}
verdaccio --config ./config.yaml
```

Web 界面: http://localhost:4873
READMEEOF

# ============================================================
step "4/4  打包压缩"
# ============================================================

info "正在创建压缩包..."
cd "${OUTPUT_DIR}"
tar czf "${ARCHIVE_NAME}" "${PACK_NAME}"
ARCHIVE_SIZE=$(du -h "${ARCHIVE_NAME}" | cut -f1)

# 清理工作目录
rm -rf "${WORK_DIR}"

# ============================================================
# 完成
# ============================================================
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     📦 离线包打包完成！                        ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  文件: ${CYAN}${OUTPUT_DIR}/${ARCHIVE_NAME}${NC}"
echo -e "${GREEN}║${NC}  大小: ${CYAN}${ARCHIVE_SIZE}${NC}"
echo -e "${GREEN}║${NC}  包含: ${CYAN}${TOTAL_TGZ} 个 .tgz + ${TOTAL_META} 个元数据${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  ${YELLOW}内网还原命令:${NC}"
echo -e "${GREEN}║${NC}  $ tar xzf ${ARCHIVE_NAME}"
echo -e "${GREEN}║${NC}  $ cd ${PACK_NAME}"
echo -e "${GREEN}║${NC}  $ bash setup-intranet.sh"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""
