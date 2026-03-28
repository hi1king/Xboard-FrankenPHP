# ╔══════════════════════════════════════════════════════════════════╗
# ║        Xboard × FrankenPHP  —  Self-Contained Dockerfile        ║
# ║  所有配置文件均内联为 heredoc，无任何外部文件依赖                  ║
# ╚══════════════════════════════════════════════════════════════════╝

# ── Stage 1: Composer dependencies ────────────────────────────────
FROM composer:2.7 AS composer-deps

WORKDIR /app

# 先只复制清单文件，利用 Docker layer 缓存（代码变动时跳过 install）
COPY composer.json composer.lock* ./
COPY . .

# --optimize-autoloader 在 install 结束时直接生成优化 classmap，
# 无需再单独跑 dump-autoload，也不用 --classmap-authoritative
# （后者会导致 Laravel Facade / 动态绑定在运行时找不到类）
RUN composer install \
      --no-dev \
      --no-scripts \
      --optimize-autoloader \
      --prefer-dist \
      --ignore-platform-reqs

# ── Stage 2: FrankenPHP Production Runtime ────────────────────────
FROM dunglas/frankenphp:1-php8.3-alpine AS production

ARG UPSTREAM_SHA=unknown
ARG UPSTREAM_VERSION=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="Xboard FrankenPHP" \
      org.opencontainers.image.description="High-performance Xboard panel powered by FrankenPHP Worker mode" \
      upstream.sha="${UPSTREAM_SHA}" \
      upstream.version="${UPSTREAM_VERSION}" \
      build.date="${BUILD_DATE}"

# ── System packages ───────────────────────────────────────────────
RUN apk add --no-cache \
      bash curl git supervisor mysql-client redis acl \
      gmp-dev libpng-dev libjpeg-turbo-dev freetype-dev \
    && rm -rf /var/cache/apk/*

# ── PHP Extensions ────────────────────────────────────────────────
RUN install-php-extensions \
      opcache pdo_mysql pdo_sqlite redis \
      mbstring intl bcmath gmp gd \
      pcntl sockets zip exif

# ── php.ini ───────────────────────────────────────────────────────
RUN cat > /usr/local/etc/php/conf.d/99-xboard.ini <<'EOF'
memory_limit = 256M
max_execution_time = 60
max_input_vars = 10000
upload_max_filesize = 64M
post_max_size = 64M
display_errors = Off
log_errors = On
error_log = /app/storage/logs/php_errors.log
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
session.cookie_secure = 1
session.cookie_httponly = 1
session.cookie_samesite = Lax
date.timezone = Asia/Shanghai
realpath_cache_size = 4096K
realpath_cache_ttl = 600
EOF

# ── opcache.ini ───────────────────────────────────────────────────
RUN cat > /usr/local/etc/php/conf.d/99-opcache.ini <<'EOF'
[opcache]
opcache.enable = 1
opcache.enable_cli = 1
opcache.memory_consumption = 256
opcache.interned_strings_buffer = 32
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 0
opcache.jit = tracing
opcache.jit_buffer_size = 128M
opcache.fast_shutdown = 1
EOF

# ── Caddyfile ─────────────────────────────────────────────────────
RUN mkdir -p /etc/caddy && cat > /etc/caddy/Caddyfile <<'EOF'
{
    frankenphp
    log { level INFO }
    servers { protocols h1 h2 h3 }
}

:80 {
    root * /app/public

    respond /health 200 {
        body "OK"
    }

    log {
        output file /app/storage/logs/access.log {
            roll_size 50mb
            roll_keep 10
        }
        format json
    }

    encode gzip zstd

    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }

    @static {
        path /build/* /css/* /js/* /images/* /fonts/* /favicon.ico /robots.txt
    }
    header @static Cache-Control "public, max-age=31536000, immutable"

    php_server {
        worker {
            file /app/worker.php
            num {$FRANKENPHP_WORKERS:4}
        }
        resolve_root_symlink
    }
}
EOF

# ── supervisord.conf ──────────────────────────────────────────────
RUN mkdir -p /etc/supervisor/conf.d && cat > /etc/supervisor/conf.d/xboard.conf <<'EOF'
[unix_http_server]
file=/tmp/supervisor.sock
chmod=0700

[supervisord]
nodaemon=false
user=root
logfile=/app/storage/logs/supervisord.log
logfile_maxbytes=10MB
logfile_backups=3
pidfile=/tmp/supervisord.pid
loglevel=info

[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///tmp/supervisor.sock

[program:queue-worker]
process_name=%(program_name)s_%(process_num)02d
command=php /app/artisan queue:work %(ENV_QUEUE_CONNECTION)s --queue=%(ENV_QUEUE_NAME)s --sleep=3 --tries=3 --max-time=3600
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
numprocs=%(ENV_QUEUE_WORKERS)s
user=www-data
redirect_stderr=true
stdout_logfile=/app/storage/logs/queue.log
stdout_logfile_maxbytes=20MB

[program:scheduler]
command=bash -c "while true; do php /app/artisan schedule:run --no-interaction >> /app/storage/logs/scheduler.log 2>&1; sleep 60; done"
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=/app/storage/logs/scheduler.log
stdout_logfile_maxbytes=10MB
EOF

# ── entrypoint.sh ─────────────────────────────────────────────────
RUN cat > /usr/local/bin/entrypoint.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log()         { echo "[entrypoint] $*"; }
log_success() { echo "[entrypoint] ✅ $*"; }
log_warn()    { echo "[entrypoint] ⚠️  $*"; }

APP_DIR=/app

# 1. APP_KEY
if [ -z "${APP_KEY:-}" ]; then
  log_warn "APP_KEY not set, generating ..."
  php "$APP_DIR/artisan" key:generate --force
fi

# 2. Wait for MySQL
if [ -n "${DB_HOST:-}" ]; then
  log "Waiting for MySQL at ${DB_HOST}:${DB_PORT:-3306} ..."
  for i in $(seq 1 30); do
    if mysqladmin ping -h "${DB_HOST}" -P "${DB_PORT:-3306}" \
        -u "${DB_USERNAME:-root}" -p"${DB_PASSWORD:-}" --silent 2>/dev/null; then
      log_success "MySQL ready"; break
    fi
    [ "$i" -eq 30 ] && log_warn "MySQL not ready after 30s, continuing ..."
    sleep 2
  done
fi

# 3. Wait for Redis
if [ -n "${REDIS_HOST:-}" ]; then
  log "Waiting for Redis at ${REDIS_HOST}:${REDIS_PORT:-6379} ..."
  for i in $(seq 1 15); do
    if redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT:-6379}" \
        ${REDIS_PASSWORD:+-a "$REDIS_PASSWORD"} ping 2>/dev/null | grep -q PONG; then
      log_success "Redis ready"; break
    fi
    sleep 1
  done
fi

cd "$APP_DIR"

# 4. Migrations
if [ "${RUN_MIGRATIONS:-true}" = "true" ]; then
  log "Running migrations ..."
  php artisan migrate --force --no-interaction 2>&1 || log_warn "Migration failed (continuing)"
  log_success "Migrations done"
fi

# 5. Cache optimisation
php artisan config:cache  --no-interaction 2>/dev/null || true
php artisan route:cache   --no-interaction 2>/dev/null || true
php artisan view:cache    --no-interaction 2>/dev/null || true
php artisan event:cache   --no-interaction 2>/dev/null || true
php artisan storage:link  --no-interaction 2>/dev/null || true
log_success "Application optimized"

# 6. Permissions
chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || true

# 7. Supervisor
if [ "${ENABLE_SUPERVISOR:-true}" = "true" ]; then
  supervisord -c /etc/supervisor/conf.d/xboard.conf -n &
  log_success "Supervisor started"
fi

log_success "🚀 Xboard FrankenPHP ready"
exec "$@"
EOF

RUN chmod +x /usr/local/bin/entrypoint.sh

# ── worker.php (FrankenPHP worker bootstrap) ──────────────────────
RUN cat > /tmp/worker.php <<'EOF'
<?php
/**
 * FrankenPHP Worker Mode Bootstrap
 * Laravel 启动一次后复用进程处理所有请求
 */
require __DIR__ . '/vendor/autoload.php';
$app    = require_once __DIR__ . '/bootstrap/app.php';
$kernel = $app->make(Illuminate\Contracts\Http\Kernel::class);

while (frankenphp_handle_request(function () use ($app, $kernel) {
    $request  = Illuminate\Http\Request::capture();
    $response = $kernel->handle($request);
    $response->send();
    $kernel->terminate($request, $response);
})) {
    gc_collect_cycles();
}
EOF

# ── Application files ─────────────────────────────────────────────
WORKDIR /app

COPY --from=composer-deps /app/vendor ./vendor
COPY --from=composer-deps /app .

RUN mv /tmp/worker.php /app/worker.php

# ── Permissions ───────────────────────────────────────────────────
RUN mkdir -p storage/logs \
             storage/framework/cache \
             storage/framework/sessions \
             storage/framework/views \
             bootstrap/cache \
    && chown -R www-data:www-data storage bootstrap/cache \
    && chmod -R 775 storage bootstrap/cache

EXPOSE 80 443 443/udp

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -fsS http://localhost/health || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]
