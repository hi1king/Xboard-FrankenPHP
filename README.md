# 🚀 Xboard × FrankenPHP CI/CD 自动化构建

> 基于 [cedar2025/Xboard](https://github.com/cedar2025/Xboard) 上游，使用 **FrankenPHP Worker 模式**替代 PHP-FPM/Nginx，实现更高并发与更低延迟。

---

## 📐 架构总览

```
GitHub 定时任务 (每天 2:00 UTC)
    │
    ▼
检查上游 cedar2025/Xboard 是否有新 Tag / 提交
    │
    ├─ 无变化 ──→ 跳过构建
    │
    └─ 有更新 ──→
         ├─ Clone 上游代码
         ├─ 覆盖 FrankenPHP Dockerfile & 配置
         ├─ 多架构构建 (amd64 + arm64)
         ├─ Push 到 GHCR / Docker Hub
         ├─ 合并多架构 Manifest
         ├─ Smoke Test
         └─ 创建 GitHub Release（仅 Tag 触发）
```

---

## ⚡ FrankenPHP Worker 模式优势

| 特性 | PHP-FPM | FrankenPHP Worker |
|------|---------|-------------------|
| 启动方式 | 每次请求初始化 | 进程常驻，一次启动 |
| Laravel 冷启动 | 每次 ~20-50ms | 首次后 ~1-3ms |
| OPcache 效率 | 高 | 极高（配合 JIT） |
| HTTP/3 (QUIC) | 需 Nginx 额外配置 | 内置支持 |
| 内存占用 | 低 | 略高（但换来高吞吐） |
| 并发处理 | FPM 进程池 | Worker 协程 |

---

## 📂 项目结构

```
.
├── .github/
│   └── workflows/
│       └── build-frankenphp.yml   # 主 CI/CD 工作流
├── docker/
│   ├── Caddyfile                  # FrankenPHP 路由配置
│   ├── worker.php                 # Worker 模式启动文件
│   ├── entrypoint.sh              # 容器启动脚本
│   ├── supervisord.conf           # 队列 + 定时任务
│   └── php/
│       ├── php.ini                # PHP 生产配置
│       └── opcache.ini            # OPcache + JIT 调优
├── Dockerfile                     # FrankenPHP 多阶段构建
├── docker-compose.yml             # 本地开发 / 生产部署
└── .last_built_sha                # 记录最后构建的 SHA（自动维护）
```

---

## 🔧 快速开始

### 1. Fork 并配置 Secrets

在你的 GitHub 仓库 → Settings → Secrets and variables → Actions 添加：

| Secret | 说明 | 必须 |
|--------|------|------|
| `DOCKERHUB_USERNAME` | Docker Hub 用户名 | 否 |
| `DOCKERHUB_TOKEN` | Docker Hub Access Token | 否 |
| `GITHUB_TOKEN` | 自动提供，无需手动添加 | 是 |

### 2. 触发构建

```bash
# 方式一：手动触发（GitHub UI → Actions → Run workflow）

# 方式二：Push 到 main 分支触发
git push origin main

# 方式三：等待每日定时检查（凌晨 2:00 UTC）
```

### 3. 本地运行

```bash
# 复制环境变量
cp .env.example .env
# 编辑 .env 填写 APP_KEY、DB 等配置

# 拉取镜像并启动（推荐）
docker compose pull
docker compose up -d

# 或本地构建
docker compose up -d --build
```

### 4. 直接使用预构建镜像

```bash
docker run -d \
  --name xboard \
  -p 80:80 \
  -p 443:443 \
  -p 443:443/udp \
  -e APP_KEY=base64:your_key_here \
  -e DB_HOST=your-db-host \
  -e DB_DATABASE=xboard \
  -e DB_USERNAME=xboard \
  -e DB_PASSWORD=your_password \
  -e REDIS_HOST=your-redis-host \
  -v xboard_storage:/app/storage \
  ghcr.io/YOUR_USERNAME/xboard-frankenphp:latest
```

---

## ⚙️ 环境变量参考

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `APP_KEY` | 无 | Laravel 加密密钥（必须）|
| `APP_URL` | `http://localhost` | 应用 URL |
| `APP_ENV` | `production` | 环境 |
| `DB_HOST` | 无 | MySQL 主机 |
| `REDIS_HOST` | 无 | Redis 主机 |
| `FRANKENPHP_WORKERS` | `4` | Worker 进程数 |
| `QUEUE_WORKERS` | `2` | 队列 Worker 数 |
| `RUN_MIGRATIONS` | `true` | 启动时是否自动迁移 |
| `ENABLE_SUPERVISOR` | `true` | 启用队列+定时任务 |

---

## 🔄 工作流详解

### 自动检测上游更新

工作流会：
1. 查询 `cedar2025/Xboard` 最新 Release Tag
2. 与 `.last_built_sha` 中记录的 SHA 对比
3. 有变化 → 触发完整构建；无变化 → 跳过

### 多架构支持

同时构建 `linux/amd64` 和 `linux/arm64`，支持：
- x86 服务器 / VPS
- Apple Silicon Mac (M1/M2/M3)
- ARM 树莓派

### 镜像标签策略

```
latest                    # 最新稳定版
v1.6.3                    # 对应上游版本
v1.6.3-frankenphp         # GitHub Release 标签
sha-abc1234               # 精确 SHA（可回滚）
```

---

## 🛠️ 自定义扩展

### 添加 PHP 扩展

在 `Dockerfile` 的 `install-php-extensions` 中添加：

```dockerfile
RUN install-php-extensions \
    swoole \     # 异步扩展（可选）
    imagick \    # 图片处理
    mongodb      # MongoDB 支持
```

### 调整 Worker 数量

根据服务器 CPU 核心数设置：

```bash
# 8 核服务器推荐
FRANKENPHP_WORKERS=8 docker compose up -d
```

---

## 📝 License

本 CI/CD 配置基于 MIT License。上游 [Xboard](https://github.com/cedar2025/Xboard) 遵循其原始许可证。
