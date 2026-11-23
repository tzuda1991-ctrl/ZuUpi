#!/bin/sh
set -eu
: "${APP_KEY:?Set APP_KEY in Railway variables}"
: "${DB_HOST:?Set DB_HOST using Railway MySQL private hostname}"
php artisan config:clear
php artisan migrate --force
exec apache2-foreground
