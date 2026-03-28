#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────
#  Xboard FrankenPHP — Container Entrypoint
# ──────────────────────────────────────────────────────────────────

log() { echo "[entrypoint] $*"; }
log_success() { echo "[entrypoint] ✅ $*"; }
log_warn()    { echo "[entrypoint] ⚠️  $*"; }

APP_DIR=/app

# ── 1. 生成 APP_KEY（若未设置）─────────────────────────────────────
if [ -z "${APP_KEY:-}" ]; then
  log_warn "APP_KEY not set, generating..."
  cd "$APP_DIR"
  php artisan key:generate --force
fi

# ── 2. 等待数据库就绪 ──────────────────────────────────────────────
if [ -n "${DB_HOST:-}" ]; then
  log "Waiting for database at ${DB_HOST}:${DB_PORT:-3306}..."
  for i in $(seq 1 30); do
    if mysqladmin ping -h "${DB_HOST}" -P "${DB_PORT:-3306}" \
        -u "${DB_USERNAME:-root}" \
        -p"${DB_PASSWORD:-}" --silent 2>/dev/null; then
      log_success "Database is ready"
      break
    fi
    if [ $i -eq 30 ]; then
      log_warn "Database not ready after 30 attempts, proceeding anyway..."
      break
    fi
    sleep 2
  done
fi

# ── 3. 等待 Redis 就绪 ────────────────────────────────────────────
if [ -n "${REDIS_HOST:-}" ]; then
  log "Waiting for Redis at ${REDIS_HOST}:${REDIS_PORT:-6379}..."
  for i in $(seq 1 15); do
    if redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT:-6379}" \
        ${REDIS_PASSWORD:+-a "$REDIS_PASSWORD"} ping 2>/dev/null | grep -q PONG; then
      log_success "Redis is ready"
      break
    fi
    sleep 1
  done
fi

cd "$APP_DIR"

# ── 4. 数据库迁移 ─────────────────────────────────────────────────
if [ "${RUN_MIGRATIONS:-true}" = "true" ]; then
  log "Running database migrations..."
  php artisan migrate --force --no-interaction 2>&1 || log_warn "Migration failed (continuing)"
  log_success "Migrations complete"
fi

# ── 5. 发布资源 & 缓存优化 ────────────────────────────────────────
log "Optimizing application..."
php artisan config:cache   --no-interaction 2>/dev/null || true
php artisan route:cache    --no-interaction 2>/dev/null || true
php artisan view:cache     --no-interaction 2>/dev/null || true
php artisan event:cache    --no-interaction 2>/dev/null || true
php artisan storage:link   --no-interaction 2>/dev/null || true
log_success "Application optimized"

# ── 6. 权限修复 ───────────────────────────────────────────────────
chown -R www-data:www-data \
  storage \
  bootstrap/cache \
  2>/dev/null || true

# ── 7. 启动 Supervisor（队列 + 定时任务）─────────────────────────
if [ "${ENABLE_SUPERVISOR:-true}" = "true" ]; then
  log "Starting Supervisor (queue workers + scheduler)..."
  supervisord -c /etc/supervisor/conf.d/xboard.conf -n &
  log_success "Supervisor started (PID $!)"
fi

log_success "Xboard FrankenPHP container ready 🚀"
log "Executing: $*"

exec "$@"
