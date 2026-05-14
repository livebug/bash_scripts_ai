#!/bin/bash
# ============================================================
# setup-verdaccio.sh — 一键搭建本地 npm 私有仓库
# ============================================================
# 功能:
#   1. 安装 Verdaccio
#   2. 生成配置文件（国内 npmmirror + 国际 npmjs 双上游）
#   3. 安装 systemd 用户服务，实现开机自启
#   4. 调整 npm 配置指向本地仓库
#   5. 添加 nrm 快捷管理
# ============================================================

set -euo pipefail

# ---- 颜色输出 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
step()  { echo -e "\n${CYAN}==>${NC} ${CYAN}$*${NC}"; }

# ---- 路径定义 ----
VERDACCIO_HOME="${HOME}/.config/verdaccio"
STORAGE_DIR="${HOME}/.local/share/verdaccio/storage"
CONFIG_FILE="${VERDACCIO_HOME}/config.yaml"
HTPASSWD_FILE="${VERDACCIO_HOME}/htpasswd"
SYSTEMD_UNIT="${HOME}/.config/systemd/user/verdaccio.service"

# ---- 自动检测 ----
NODE_BIN_DIR=$(dirname "$(command -v node)")
NPM_BIN_DIR=$(dirname "$(command -v npm)")
VERDACCIO_BIN="${NODE_BIN_DIR}/verdaccio"
LOCAL_REGISTRY="http://localhost:4873"

# ============================================================
step "1/6  检查依赖环境"
# ============================================================
command -v node   >/dev/null 2>&1 || { error "未找到 node，请先安装 Node.js"; exit 1; }
command -v npm    >/dev/null 2>&1 || { error "未找到 npm"; exit 1; }
command -v systemctl >/dev/null 2>&1 || { warn "未找到 systemctl，将跳过服务安装"; }

info "node $(node --version)  @ ${NODE_BIN_DIR}"
info "npm  $(npm --version)   @ ${NPM_BIN_DIR}"

# ============================================================
step "2/6  安装 Verdaccio"
# ============================================================
if command -v verdaccio >/dev/null 2>&1; then
    info "Verdaccio 已安装: $(${VERDACCIO_BIN} --version)"
else
    info "正在安装 Verdaccio ..."
    npm install -g verdaccio
    info "安装完成: $(${VERDACCIO_BIN} --version)"
fi

# ============================================================
step "3/6  创建目录 & 配置文件"
# ============================================================
mkdir -p "${VERDACCIO_HOME}"
mkdir -p "${STORAGE_DIR}"
mkdir -p "$(dirname "${SYSTEMD_UNIT}")"

if [ -f "${CONFIG_FILE}" ]; then
    warn "配置文件已存在，备份为 config.yaml.bak"
    cp "${CONFIG_FILE}" "${CONFIG_FILE}.bak"
fi

cat > "${CONFIG_FILE}" << 'YAMLEOF'
#
# Verdaccio 配置 — 本地 npm 私有仓库
# 国内 npmmirror 优先，国际 npmjs 兜底
#

storage: __STORAGE_DIR__

uplinks:
  npmmirror:
    url: https://registry.npmmirror.com
    maxage: 10m
    max_fails: 5
    timeout: 60s
    fail_timeout: 5m
  npmjs:
    url: https://registry.npmjs.org
    maxage: 10m
    max_fails: 3
    timeout: 120s
    fail_timeout: 10m

packages:
  '**':
    access: $all
    publish: $authenticated
    unpublish: $authenticated
    proxy: npmmirror npmjs

web:
  enable: true
  title: 本地 npm 私有仓库

server:
  listen:
    - host: localhost
      port: 4873

log:
  - { type: stdout, format: pretty, level: http }

auth:
  htpasswd:
    file: __HTPASSWD_FILE__
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

# 替换路径变量
sed -i "s|__STORAGE_DIR__|${STORAGE_DIR}|g"     "${CONFIG_FILE}"
sed -i "s|__HTPASSWD_FILE__|${HTPASSWD_FILE}|g" "${CONFIG_FILE}"

info "配置文件已写入: ${CONFIG_FILE}"

# ============================================================
step "4/6  安装 systemd 用户服务"
# ============================================================
if command -v systemctl >/dev/null 2>&1; then
    cat > "${SYSTEMD_UNIT}" << UNITEOF
[Unit]
Description=Verdaccio - 本地 npm 私有仓库
Documentation=https://verdaccio.org
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${VERDACCIO_BIN} --config ${CONFIG_FILE}
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
    info "systemd 用户服务已安装并启动"
    info "常用命令:"
    info "  systemctl --user status  verdaccio"
    info "  systemctl --user restart verdaccio"
    info "  systemctl --user stop    verdaccio"
    info "  journalctl --user -u verdaccio -f"
else
    warn "未找到 systemctl，跳过服务安装"
    warn "你可以手动启动: verdaccio --config ${CONFIG_FILE} &"
fi

# ============================================================
step "5/6  调整 npm 配置"
# ============================================================
info "设置 npm registry 指向本地仓库: ${LOCAL_REGISTRY}"
npm config set registry "${LOCAL_REGISTRY}"

# ============================================================
step "6/6  验证"
# ============================================================
sleep 1
if curl -s "${LOCAL_REGISTRY}" >/dev/null 2>&1; then
    info "✓ 本地仓库运行正常: ${LOCAL_REGISTRY}"
else
    warn "仓库可能还未完全启动，稍等几秒再试"
fi

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     🎉 本地 npm 私有仓库 搭建完成！           ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  仓库地址:   ${CYAN}${LOCAL_REGISTRY}${NC}"
echo -e "${GREEN}║${NC}  Web 界面:   ${CYAN}${LOCAL_REGISTRY}${NC}"
echo -e "${GREEN}║${NC}  配置位置:   ${CYAN}${CONFIG_FILE}${NC}"
echo -e "${GREEN}║${NC}  缓存目录:   ${CYAN}${STORAGE_DIR}${NC}"
echo -e "${GREEN}║${NC}  上游优先级: ${CYAN}npmmirror(国内) → npmjs(国际)${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  创建用户:   ${YELLOW}npm adduser --registry ${LOCAL_REGISTRY}${NC}"
echo -e "${GREEN}║${NC}  启动状态:   ${YELLOW}systemctl --user status verdaccio${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""
