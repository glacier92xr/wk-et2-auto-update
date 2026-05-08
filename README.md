# wk-et2-auto-update

## 项目概述

本项目是一个基于 GitHub Actions 的 Cloudflare Worker 自动同步与部署工具，专门用于从上游 [cmliu/edgetunnel](https://github.com/cmliu/edgetunnel) 仓库自动获取最新 Worker 代码并进行部署。

### 核心能力

| 能力            | 说明                                         |
| --------------- | -------------------------------------------- |
| **自动检测**    | 通过直接比对 Worker 文件内容判断是否需要更新 |
| **代码混淆**    | 自动对 Worker 代码进行混淆处理，保护源代码   |
| **KV 存储管理** | 自动创建或复用 Cloudflare KV 命名空间        |
| **多环境支持**  | 支持通过环境变量配置 UUID、ADMIN 等参数      |
| **自定义域名**  | 支持配置自定义域名，自动设置路由规则         |
| **自动部署**    | 检测到更新后自动部署到 Cloudflare Workers    |

---

## 快速开始

### 前置条件

- GitHub 账号
- Cloudflare 账号（需具备 Workers 和 KV 管理权限）

### 部署步骤

1. **Fork 本仓库**：点击页面右上角 **Fork** 按钮，将仓库复制到你的 GitHub 账号。

2. **启用 GitHub Actions**：进入你 Fork 后的仓库，点击 **Actions** 页面，首次访问会提示启用 workflows。

3. **配置敏感信息**：在仓库 **Settings → Secrets and variables → Actions** 中添加以下敏感信息：

   | 名称              | 必填 | 说明                           |
   | ----------------- | ---- | ------------------------------ |
   | `CF_API_TOKEN`    | 是   | Cloudflare API Token           |
   | `CF_ACCOUNT_ID`   | 是   | Cloudflare 账户 ID             |
   | `CF_VAR_UUID`     | 否   | Worker 环境变量 UUID 值        |
   | `CF_VAR_ADMIN`    | 否   | Worker 管理员密码              |
   | `CF_ROUTE_DOMAIN` | 否   | 自定义域名（如 `example.com`） |

4. **触发更新**：
   - **手动触发**：进入 **Actions** 页面，选择 "auto update and deploy" 工作流，点击 **Run workflow**。
   - **自动执行**：每天 **UTC 16:00（北京时间 00:00）** 自动检查并执行更新。

---

## 功能特性

### 核心功能详解

| 功能                | 说明                                                                                                |
| ------------------- | --------------------------------------------------------------------------------------------------- |
| **文件比对更新**    | 直接从上游仓库下载 `_worker.js` 并与本地 `_worker_origin.js` 比对，内容不一致时触发更新             |
| **代码混淆**        | 使用 `javascript-obfuscator` 对 Worker 代码进行混淆，包含控制流扁平化、死代码注入、字符串数组等保护 |
| **KV 命名空间管理** | 自动查询是否已存在同名 KV namespace，若存在则复用，否则创建新 namespace                             |
| **配置自动更新**    | 自动更新 `wrangler.toml` 中的 KV ID、UUID、ADMIN 等配置项                                           |
| **自定义域名路由**  | 支持配置自定义域名，自动添加 `[[routes]]` 配置并设置 `workers_dev = false`                          |
| **自动提交推送**    | 更新完成后自动提交代码变更并推送至 `main` 分支                                                      |
| **历史记录清理**    | 自动删除超过 7 天的 workflow runs，仅保留最新 1 条                                                  |

---

## 工作流程

### 触发条件

| 触发方式     | 说明                                         |
| ------------ | -------------------------------------------- |
| **定时触发** | 每天 UTC 16:00 自动执行                      |
| **手动触发** | 在 Actions 页面选择工作流点击 "Run workflow" |

### 执行流程

```text
┌─────────────────────────────────────────────────────────────────┐
│                        阶段一：代码更新                           │
├─────────────────────────────────────────────────────────────────┤
│ 1. Checkout 仓库                                                │
│ 2. 设置 Node.js LTS                                             │
│ 3. 安装依赖 (jq, curl, unzip)                                   │
│ 4. 下载上游 _worker.js 到 tmp/                                  │
│ 5. 与本地 _worker_origin.js 比对                                │
│    ├─ 内容一致 → 结束流程                                        │
│    └─ 内容不一致 → 继续执行                                      │
│ 6. 代码混淆处理                                                 │
│ 7. 提交并推送 _worker.js 和 _worker_origin.js                   │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                        阶段二：部署配置                           │
├─────────────────────────────────────────────────────────────────┤
│ 8.  安装项目依赖 (wrangler)                                     │
│ 9.  执行 step-kv.sh 创建/复用 KV 命名空间                       │
│ 10. 更新 wrangler.toml (KV ID, UUID, ADMIN)                     │
│ 11. 配置自定义域名路由                                          │
│ 12. 部署到 Cloudflare Workers                                   │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                        阶段三：清理                              │
├─────────────────────────────────────────────────────────────────┤
│ 13. 删除超过 7 天的 workflow runs                               │
└─────────────────────────────────────────────────────────────────┘
```

### 跳过机制

当检测到版本一致（`need_update=false`）时，工作流**跳过步骤 6-12**，直接结束执行。

---

## 目录结构

```text
wk-et2-auto-update/
├── _worker.js              # 混淆后的 Worker 主文件（已混淆）
├── _worker_origin.js       # 上游原始 Worker 文件（未混淆）
├── wrangler.toml           # Cloudflare Workers 配置文件
├── package.json            # 项目依赖配置
├── .gitignore              # Git 忽略规则
├── .gitattributes          # Git 属性配置（行尾符、脚本类型）
├── scripts/
│   ├── step-kv.sh         # KV 命名空间管理脚本 (Bash/Linux/macOS)
│   └── step-kv.ps1        # KV 命名空间管理脚本 (PowerShell/Windows)
└── .github/
    └── workflows/
        └── update_worker.yml  # GitHub Actions CI/CD 工作流
```

### 技术栈

| 类别     | 技术                  | 说明                          |
| -------- | --------------------- | ----------------------------- |
| 运行时   | Cloudflare Workers    | Edge Computing 平台           |
| 部署工具 | Wrangler              | ^4.0.0 Cloudflare Workers CLI |
| CI/CD    | GitHub Actions        | 自动化工作流引擎              |
| 代码混淆 | javascript-obfuscator | Worker 代码保护               |
| 脚本语言 | Bash / PowerShell     | KV 自动化脚本                 |
| 上游项目 | cmliu/edgetunnel      | Worker 源码来源               |

---

## 配置说明

### 1. GitHub Secrets 配置

| 名称              | 必填 | 权限要求                                                                      | 说明                                        |
| ----------------- | ---- | ----------------------------------------------------------------------------- | ------------------------------------------- |
| `CF_API_TOKEN`    | 是   | Workers 脚本编辑、KV 存储编辑、Workers 路由编辑、用户信息读取、自定义域名编辑 | Cloudflare API Token                        |
| `CF_ACCOUNT_ID`   | 是   | -                                                                             | Cloudflare 账户 ID（Dashboard URL 中获取）  |
| `CF_VAR_UUID`     | 否   | -                                                                             | 更新 `wrangler.toml` 中 `[vars].UUID` 的值  |
| `CF_VAR_ADMIN`    | 否   | -                                                                             | 更新 `wrangler.toml` 中 `[vars].ADMIN` 的值 |
| `CF_ROUTE_DOMAIN` | 否   | -                                                                             | 自定义域名，配置后自动启用自定义路由        |

### 2. 工作流环境变量

| 变量名       | 默认值                                                                          | 说明                       |
| ------------ | ------------------------------------------------------------------------------- | -------------------------- |
| `WORKER_URL` | `https://raw.githubusercontent.com/cmliu/edgetunnel/refs/heads/main/_worker.js` | 上游 Worker 文件 URL       |
| `KV_NAME`    | `wb-et-kv`                                                                      | Cloudflare KV 命名空间名称 |

> **修改方式**：编辑 `.github/workflows/update_worker.yml` 文件中的 `env` 区块。

### 3. wrangler.toml 配置

```toml
name = "wk-et"
main = "_worker.js"
compatibility_date = "2026-05-08"
no_bundle = true
workers_dev = true
preview_urls = true

[vars]
UUID = "your-uuid-here"
ADMIN = "admin"

[[kv_namespaces]]
binding = "KV"
id = "your-kv-id-here"

[observability]
[observability.logs]
enabled = true
[observability.traces]
enabled = true
```

| 配置项               | 类型    | 说明                                  |
| -------------------- | ------- | ------------------------------------- |
| `name`               | string  | Worker 名称                           |
| `main`               | string  | 入口文件路径                          |
| `compatibility_date` | string  | 兼容性日期                            |
| `no_bundle`          | boolean | 是否禁用打包（`true` 直接上传单文件） |
| `workers_dev`        | boolean | 是否启用 workers.dev 子域名           |
| `[vars]`             | object  | 环境变量（UUID、ADMIN 等）            |
| `[[kv_namespaces]]`  | array   | KV 命名空间绑定列表                   |

---

## 本地开发

### 环境要求

- Node.js >= 18
- Wrangler CLI (`npx wrangler login` 完成认证)

### 命令

```bash
# 安装依赖
npm install

# 本地开发调试
npm run dev

# 部署到 Cloudflare
npm run deploy
```

### 手动执行 KV 脚本

```bash
# Linux/macOS
./scripts/step-kv.sh <KV_NAME>

# Windows (PowerShell)
.\scripts\step-kv.ps1 <KV_NAME>
```

---

## 故障排除

### 常见问题

**Q: 工作流执行失败，提示 "KV namespace not found"**

> 确保 `CF_API_TOKEN` 具有 `Account:Workers KV Storage:Edit` 权限，并检查 `KV_NAME` 是否与 Cloudflare Dashboard 中的名称完全一致。

**Q: 自定义域名配置后 Worker 无法访问**

> 检查 DNS 是否已正确配置指向 Cloudflare，并确保 `CF_ROUTE_DOMAIN` 设置的域名已在 Cloudflare 添加为有效域名。

**Q: 部署成功但 Worker 仍使用旧代码**

> 清除浏览器缓存或使用隐私模式访问，因为边缘节点可能缓存了旧版本。

**Q: javascript-obfuscator 安装失败**

> 工作流中已通过 `npm install -g` 全局安装，若本地调试可使用 `npx javascript-obfuscator` 替代。

### 调试方法

1. 查看 GitHub Actions 工作流日志
2. 检查 `scripts/step-kv.log` 日志文件
3. 手动执行 `npm run dev` 本地调试

---

## 免责声明

1. **使用目的**：本项目仅供**教育、科学研究及个人安全测试**之目的。
2. **合规使用**：使用者在下载或使用本项目代码时，必须严格遵守所在地区的法律法规。
3. **无责任声明**：作者对任何滥用本项目代码导致的行为或后果均不承担任何责任。
4. **无担保**：本项目不对因使用代码引起的任何直接或间接损害负责。

---

## 特别说明

| 项目         | 说明                                                                         |
| ------------ | ---------------------------------------------------------------------------- |
| **上游来源** | 本仓库同步内容来源于 [cmliu/edgetunnel](https://github.com/cmliu/edgetunnel) |
| **版权归属** | 原项目版权归原作者所有                                                       |
| **项目目的** | 本项目仅用于自动同步更新，不对原内容进行修改                                 |

---

## Star History

![Star History Chart](https://api.star-history.com/svg?repos=glacier92xr/wk-et2-auto-update&type=Timeline)
