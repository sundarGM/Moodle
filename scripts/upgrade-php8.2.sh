#!/bin/bash
set -e

echo ">>> Adding PHP repository..."
sudo add-apt-repository ppa:ondrej/php -y
sudo apt-get update -y

echo ">>> Installing PHP 8.2 and extensions..."
sudo apt-get install -y php8.2 php8.2-cli php8.2-fpm \
    php8.2-common php8.2-mysql php8.2-xml php8.2-gd \
    php8.2-intl php8.2-curl php8.2-zip php8.2-mbstring

echo ">>> Removing old PHP 8.1..."
sudo apt-get purge -y php8.1*

echo ">>> Updating nginx configs to use PHP 8.2..."
sudo sed -i 's|php8.1-fpm.sock|php8.2-fpm.sock|g' /etc/nginx/sites-enabled/*
sudo sed -i 's|php-fpm.sock|php8.2-fpm.sock|g' /etc/nginx/sites-enabled/*

echo ">>> Restarting services..."
sudo systemctl enable php8.2-fpm
sudo systemctl restart php8.2-fpm
sudo systemctl restart nginx

echo ">>> PHP upgrade complete!"
php -v

#!/bin/bash
set -euo pipefail

# This script should run as root (CustomScript does that).
# Idempotent: safe to run multiple times.

echo "=== START: VMSS PHP 8.2 + Moodle tuning ==="

# 1) Basic apt update + add PPA
if ! apt-get update -y >/dev/null 2>&1; then
  echo "apt-get update failed, retrying once..."
  apt-get update -y
fi

# Add Ondřej PPA if not present
if ! grep -q "^deb .\+ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
  apt-get install -y -q software-properties-common ca-certificates apt-transport-https lsb-release
  add-apt-repository -y ppa:ondrej/php
  apt-get update -y
fi

echo "=== Installing PHP 8.2 and extensions ==="
DEPS="php8.2 php8.2-fpm php8.2-cli php8.2-common php8.2-mysql \
php8.2-xml php8.2-curl php8.2-gd php8.2-intl php8.2-mbstring \
php8.2-zip php8.2-soap php8.2-bcmath php8.2-readline php8.2-bz2 php8.2-opcache"

# Install packages (be tolerant if some are already installed)
apt-get install -y $DEPS || apt-get install -y --fix-missing $DEPS

# 2) Disable older PHP-FPM versions (if present)
for ver in 8.1 8.3 8.4 7.4; do
  if systemctl list-unit-files --type=service | grep -q "php${ver}-fpm.service"; then
    systemctl stop "php${ver}-fpm" || true
    systemctl disable "php${ver}-fpm" || true
  fi
done

# Ensure php8.2-fpm enabled and running
systemctl enable --now php8.2-fpm

# 3) Configure php.ini settings for FPM and CLI
set_ini_value() {
  local file="$1"; local key="$2"; local val="$3"
  # if key exists, replace; else append
  if grep -q -E "^\s*${key}\s*=" "$file"; then
    sed -i -E "s|^\s*${key}\s*=.*|${key} = ${val}|" "$file"
  else
    echo "${key} = ${val}" >> "$file"
  fi
}

PHPINI_FPM="/etc/php/8.2/fpm/php.ini"
PHPINI_CLI="/etc/php/8.2/cli/php.ini"

# Moodle recommended / safe values
set_ini_value "$PHPINI_FPM" "max_input_vars" "5000"
set_ini_value "$PHPINI_CLI" "max_input_vars" "5000"
set_ini_value "$PHPINI_FPM" "memory_limit" "512M"
set_ini_value "$PHPINI_CLI" "memory_limit" "512M"
set_ini_value "$PHPINI_FPM" "upload_max_filesize" "100M"
set_ini_value "$PHPINI_CLI" "upload_max_filesize" "100M"
set_ini_value "$PHPINI_FPM" "post_max_size" "100M"
set_ini_value "$PHPINI_CLI" "post_max_size" "100M"
set_ini_value "$PHPINI_FPM" "max_execution_time" "300"
set_ini_value "$PHPINI_CLI" "max_execution_time" "300"

# 4) Ensure php_value[max_input_vars]=5000 in FPM pool
FPM_POOL="/etc/php/8.2/fpm/pool.d/www.conf"
if [ -f "$FPM_POOL" ]; then
  # remove any existing php_value[max_input_vars] duplicates first
  sed -i '/php_value\[max_input_vars\]/d' "$FPM_POOL" || true
  # add comment + value
  echo "" >> "$FPM_POOL"
  echo "; Moodle tuning: ensure sufficient input vars" >> "$FPM_POOL"
  echo "php_value[max_input_vars] = 5000" >> "$FPM_POOL"
else
  echo "Warning: FPM pool not found at $FPM_POOL"
fi

# 5) Update nginx fastcgi socket references (if nginx installed)
if command -v nginx >/dev/null 2>&1; then
  # Replace any phpX.Y-fpm.sock or generic php-fpm.sock to php8.2-fpm.sock in site configs
  sed -i 's|php[0-9]\+\.[0-9]\+-fpm.sock|php8.2-fpm.sock|g' /etc/nginx/sites-enabled/* 2>/dev/null || true
  sed -i 's|php-fpm.sock|php8.2-fpm.sock|g' /etc/nginx/sites-enabled/* 2>/dev/null || true

  # If /etc/alternatives/php-fpm.sock exists, point it to 8.2
  if [ -L /etc/alternatives/php-fpm.sock ] || [ -e /etc/alternatives/php-fpm.sock ]; then
    ln -sf /run/php/php8.2-fpm.sock /etc/alternatives/php-fpm.sock
  fi

  # test nginx config and reload
  nginx -t || { echo "nginx config test failed"; nginx -t; exit 1; }
  systemctl restart nginx || systemctl reload nginx || true
fi

# 6) Restart PHP-FPM to pick up changes
systemctl restart php8.2-fpm

# 7) Small verification output
echo "=== Verification: php -v ==="
php -v || true

echo "=== Verification: php -m (soap present?) ==="
php -m | grep -i soap || echo "soap not present"

echo "=== Verification (FPM pool): max_input_vars from phpinfo (FPM) ==="
# try local curl of info.php if webroot available
if [ -f /var/www/html/info.php ]; then
  curl -s http://127.0.0.1/info.php | grep -E "max_input_vars|PHP Version" || true
else
  echo "No /var/www/html/info.php to test (create one to verify)"
fi

echo "=== DONE: VMSS PHP 8.2 + Moodle tuning applied ==="

