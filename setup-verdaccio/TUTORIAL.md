# 🏗️ 本地 npm 私有仓库 搭建教程

## 架构概览

```
┌──────────────┐     npm install     ┌──────────────────┐
│  你的项目     │ ──────────────────> │  Verdaccio        │
│              │ <───────────────── │  localhost:4873   │
└──────────────┘     返回包          └─────┬────────────┘
                                          │
                          ┌───────────────┼───────────────┐
                          │               │               │
                          ▼               ▼               ▼
                   ┌────────────┐ ┌────────────┐ ┌────────────┐
                   │  本地缓存   │ │ npmmirror  │ │  npmjs.org │
                   │  (storage)  │ │  (国内)     │ │  (国际)     │
                   └────────────┘ └────────────┘ └────────────┘
```

- **Verdaccio** 作为本地代理层，拦截所有 `npm install` 请求
- 首次安装时从上游拉取并缓存到本地，后续安装直接走缓存（秒级）
- **上游优先级**：`npmmirror`（国内，快）→ `npmjs.org`（国际，兜底）

---

## 一、前置条件

| 依赖 | 版本要求 | 检查命令 |
|------|---------|----------|
| Node.js | >=18 | `node --version` |
| npm | >=9 | `npm --version` |
| systemd | 任意 | `systemctl --user` |

---

## 二、一键安装（推荐）

```bash
cd /home/dingxh/repo/bash_scripts_ai
bash setup-verdaccio.sh
```

脚本自动完成以下操作：

1. ✅ 检查 Node.js / npm 环境
2. ✅ 安装 Verdaccio（已安装则跳过）
3. ✅ 生成配置文件（双上游代理）
4. ✅ 安装 systemd 用户服务（开机自启）
5. ✅ 调整 npm registry 指向本地

---

## 三、手动安装（分步操作）

### 3.1 安装 Verdaccio

```bash
npm install -g verdaccio
```

### 3.2 创建目录

```bash
mkdir -p ~/.config/verdaccio
mkdir -p ~/.local/share/verdaccio/storage
```

### 3.3 编写配置文件

`~/.config/verdaccio/config.yaml`：

```yaml
storage: /home/dingxh/.local/share/verdaccio/storage

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
    file: /home/dingxh/.config/verdaccio/htpasswd
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
```

### 3.4 安装 systemd 服务

创建 `~/.config/systemd/user/verdaccio.service`：

```ini
[Unit]
Description=Verdaccio - 本地 npm 私有仓库
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/home/dingxh/.nvm/versions/node/v25.8.1/bin/verdaccio --config /home/dingxh/.config/verdaccio/config.yaml
Restart=on-failure
RestartSec=5s
Environment=PATH=/home/dingxh/.nvm/versions/node/v25.8.1/bin:/usr/local/bin:/usr/bin:/bin
Environment=HOME=/home/dingxh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=verdaccio

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable verdaccio
systemctl --user start verdaccio
systemctl --user status verdaccio
```

### 3.5 调整 npm 配置

```bash
npm config set registry http://localhost:4873
```

验证：

```bash
npm config get registry
# 输出: http://localhost:4873
```

---

## 四、日常使用

### 基本命令

```bash
# 查看服务状态
systemctl --user status verdaccio

# 启动 / 重启 / 停止
systemctl --user start verdaccio
systemctl --user restart verdaccio
systemctl --user stop verdaccio

# 查看实时日志
journalctl --user -u verdaccio -f

# 手动启动（调试用）
verdaccio --config ~/.config/verdaccio/config.yaml
```

### 注册用户（用于发布私有包）

```bash
npm adduser --registry http://localhost:4873
```

### 登录

```bash
npm login --registry http://localhost:4873
```

### 发布私有包

```bash
# 在包目录中
npm publish --registry http://localhost:4873
```

### 安装包（自动走本地仓库）

```bash
npm install lodash        # 首次从 npmmirror 拉取并缓存
npm install lodash        # 第二次直接从本地缓存返回（极快）
```

### 切换回官方源（按需）

```bash
npm config set registry https://registry.npmjs.org
# 切回本地
npm config set registry http://localhost:4873
```

---

## 五、常见问题

### Q: 如何查看 Verdaccio Web 界面？

浏览器打开 **http://localhost:4873**，可搜索包、查看缓存状态。

### Q: 如果 nvm 路径变了怎么办？

更新 systemd 服务中的 `ExecStart` 和 `Environment=PATH`：

```bash
which verdaccio  # 拷贝实际路径
vim ~/.config/systemd/user/verdaccio.service
systemctl --user daemon-reload
systemctl --user restart verdaccio
```

### Q: 想在局域网内共享仓库？

修改 `~/.config/verdaccio/config.yaml` 中 `listen`：

```yaml
server:
  listen:
    - host: 0.0.0.0
      port: 4873
```

然后重启服务。其他机器上配置：

```bash
npm config set registry http://<你的IP>:4873
```

### Q: 缓存占用太多磁盘空间？

```bash
# 查看缓存大小
du -sh ~/.local/share/verdaccio/storage

# 清理特定包
rm -rf ~/.local/share/verdaccio/storage/<package-name>

# 清空全部缓存并重建
rm -rf ~/.local/share/verdaccio/storage/*
systemctl --user restart verdaccio
```

### Q: 如何添加更多上游？

编辑 `config.yaml` 中的 `uplinks`：

```yaml
uplinks:
  npmmirror:
    url: https://registry.npmmirror.com
    ...
  npmjs:
    url: https://registry.npmjs.org
    ...
  # 新增
  github:
    url: https://npm.pkg.github.com
    ...
```

然后在 `packages` 的 `proxy` 中添加即可。

---

## 六、文件清单

| 路径 | 用途 |
|------|------|
| `~/.config/verdaccio/config.yaml` | 配置文件 |
| `~/.config/verdaccio/htpasswd` | 用户密码文件 |
| `~/.local/share/verdaccio/storage/` | 包缓存目录 |
| `~/.config/systemd/user/verdaccio.service` | systemd 服务 |
| `setup-verdaccio.sh` | 一键安装脚本 |
