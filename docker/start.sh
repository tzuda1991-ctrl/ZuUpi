#!/usr/bin/env bash
set -euo pipefail

cd /var/www/html

PORT="${PORT:-8080}"
PROCESS_TYPE="${PROCESS_TYPE:-all}"

if [ -z "${APP_KEY:-}" ]; then
    echo "ERROR: APP_KEY is not set in Railway Variables. Generate one with: php -r \"echo 'base64:'.base64_encode(random_bytes(32)).PHP_EOL;\"" >&2
    exit 1
fi

mkdir -p storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache
chown -R www-data:www-data storage bootstrap/cache
chmod -R ug+rwX storage bootstrap/cache

# Rebuild caches from live Railway environment variables
php artisan config:clear --no-interaction
php artisan config:cache --no-interaction
php artisan route:cache --no-interaction
php artisan view:cache --no-interaction

if [ "${RUN_MIGRATIONS:-true}" = "true" ] && { [ "$PROCESS_TYPE" = "web" ] || [ "$PROCESS_TYPE" = "all" ]; }; then
    php artisan migrate --force --no-interaction
    php artisan app:bootstrap-admin --no-interaction
fi

# Sync disk installed marker if an admin already exists in MySQL
if php -r '
    require "vendor/autoload.php";
    $app = require "bootstrap/app.php";
    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
    exit(App\Models\User::where("role", "admin")->exists() ? 0 : 1);
' 2>/dev/null; then
    date -Iseconds > storage/installed
    chown www-data:www-data storage/installed
    chmod 600 storage/installed
fi

start_workers() {
    (
        while true; do
            su -s /bin/sh www-data -c "php artisan queue:work database --queue=default --tries=6 --timeout=60 --sleep=3 --memory=128 --max-time=3600" || true
            sleep 2
        done
    ) &

    (
        while true; do
            su -s /bin/sh www-data -c "php artisan schedule:run --no-interaction" || true
            sleep 60
        done
    ) &
}

if [ "$PROCESS_TYPE" = "worker" ]; then
    start_workers
    wait
    exit 0
fi

# Bind Apache dynamically to Railway's $PORT
sed -ri "s/Listen [0-9]+/Listen ${PORT}/g" /etc/apache2/ports.conf
sed -ri "s/<VirtualHost \*:[0-9]+>/<VirtualHost *:${PORT}>/g" /etc/apache2/sites-available/000-default.conf

if [ "$PROCESS_TYPE" = "all" ]; then
    start_workers
fi

exec apache2-foreground
