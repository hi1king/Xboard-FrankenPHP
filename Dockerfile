# ╔══════════════════════════════════════════════════════════════════╗
# ║          Xboard — FrankenPHP Production Dockerfile              ║
# ║  Based on cedar2025/Xboard with FrankenPHP runtime              ║
# ╚══════════════════════════════════════════════════════════════════╝

# ── Stage 1: Composer dependencies ────────────────────────────────
FROM composer:2.7 AS composer-deps

WORKDIR /app

COPY composer.json composer.lock ./
RUN composer install \
      --no-dev \
      --no-scripts \
      --no-autoloader \
      --prefer-dist \
      --ignore-platform-reqs

COPY . .
RUN composer dump-autoload \
      --optimize \
      --classmap-authoritative \
      --no-dev

# ── Stage 2: Node / Vite frontend build ───────────────────────────
FROM node:20-alpine AS node-build

WORKDIR /app
COPY package*.json ./
RUN npm ci --prefer-offline 2>/dev/null || npm install

COPY . .
RUN npm run build 2>/dev/null || echo "No frontend build step"

# ── Stage 3: FrankenPHP Production Image ──────────────────────────
FROM dunglas/frankenphp:1-php8.3-alpine AS production

ARG UPSTREAM_SHA=unknown
ARG UPSTREAM_VERSION=unknown
ARG BUILD_DATE=unknown

LABEL maintainer="CI/CD Auto Build" \
      org.opencontainers.image.title="Xboard FrankenPHP" \
      org.opencontainers.image.description="High-performance Xboard panel with FrankenPHP" \
      upstream.sha="${UPSTREAM_SHA}" \
      upstream.version="${UPSTREAM_VERSION}" \
      build.date="${BUILD_DATE}"

# ── System dependencies ───────────────────────────────────────────
RUN apk add --no-cache \
      bash \
      curl \
      git \
      supervisor \
      mysql-client \
      redis \
      acl \
      fcgi \
      # Image processing
      libpng-dev \
      libjpeg-turbo-dev \
      freetype-dev \
      # For bcmath/gmp
      gmp-dev \
    && rm -rf /var/cache/apk/*

# ── PHP Extensions ────────────────────────────────────────────────
RUN install-php-extensions \
      # Core
      opcache \
      pdo_mysql \
      pdo_sqlite \
      redis \
      # String/encoding
      mbstring \
      intl \
      # Math
      bcmath \
      gmp \
      # Image
      gd \
      # Network/async
      pcntl \
      sockets \
      # Compression
      zip \
      # Misc
      exif \
      calendar \
      gettext

# ── PHP Runtime Configuration ─────────────────────────────────────
COPY docker/php/php.ini /usr/local/etc/php/conf.d/99-xboard.ini
COPY docker/php/opcache.ini /usr/local/etc/php/conf.d/99-opcache.ini

# ── Caddyfile (FrankenPHP routing) ────────────────────────────────
COPY docker/Caddyfile /etc/caddy/Caddyfile

# ── Supervisor (queue + scheduler) ───────────────────────────────
COPY docker/supervisord.conf /etc/supervisor/conf.d/xboard.conf

# ── App files ─────────────────────────────────────────────────────
WORKDIR /app

COPY --from=composer-deps /app/vendor ./vendor
COPY --from=composer-deps /app .
COPY --from=node-build /app/public/build ./public/build 2>/dev/null || true

# ── Permissions ───────────────────────────────────────────────────
RUN mkdir -p storage/logs storage/framework/{cache,sessions,views} bootstrap/cache \
    && chown -R www-data:www-data storage bootstrap/cache \
    && chmod -R 775 storage bootstrap/cache

# ── Entrypoint ────────────────────────────────────────────────────
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80 443 443/udp

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -fsS http://localhost/health || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]
