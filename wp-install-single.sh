#!/usr/bin/env bash
# wp-install-single.sh (resumable & safe)
# Usage: sudo ./wp-install-single.sh example.com
set -euo pipefail

# Enable debug output for progress visibility
set -x

# --- 1️⃣ DOMAIN INPUT ---
if [ "$#" -ge 1 ]; then
    DOMAIN="$1"
else
    read -p "Enter your domain name (e.g. example.com): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo "No domain entered. Exiting."
        exit 1
    fi
fi

CERT_EMAIL="admin@${DOMAIN}"
WEB_ROOT="/var/www/html"
APACHE_CONF="/etc/apache2/sites-available/000-default.conf"
CRED_FILE="/root/.html_db_creds"
PHP_UPLOAD_LIMIT="64M"
POST_MAX_SIZE="64M"
MEMORY_LIMIT="256M"
MAX_EXEC_TIME="300"

# --- 2️⃣ CLEAN DB NAME ---
clean_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/^_//; s/_$//'
}

DB_NAME="wp_$(clean_name "${DOMAIN}")"
DB_USER="${DB_NAME}_user"

# --- 3️⃣ GENERATE DB PASSWORD ---
if [ ! -f "${CRED_FILE}" ]; then
    DB_PASS=$(tr -dc 'a-zA-Z0-9@#$%*&' < /dev/urandom | head -c 12)
else
    source "${CRED_FILE}"
fi

echo "=== Starting/resuming install for ${DOMAIN} ==="

# --- 4️⃣ SYSTEM PACKAGES ---
if ! dpkg -s apache2 mysql-server php >/dev/null 2>&1; then
    apt update -y && apt upgrade -y
    apt install -y apache2 mysql-server php libapache2-mod-php php-mysql unzip certbot python3-certbot-apache php-curl php-mbstring php-xml php-xmlrpc php-gd php-zip php-bcmath php-intl
fi

# --- 5️⃣ APACHE CONFIG ---
mkdir -p "${WEB_ROOT}"
chown -R www-data:www-data "${WEB_ROOT}"
chmod 755 "${WEB_ROOT}"

sed -i "s|DocumentRoot .*|DocumentRoot ${WEB_ROOT}|" "${APACHE_CONF}" || true
sed -i "s|<Directory .*|<Directory ${WEB_ROOT}|" "${APACHE_CONF}" || true
sed -i 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf || true
systemctl reload apache2

# --- 6️⃣ PHP LIMITS ---
for php_ini in /etc/php/*/apache2/php.ini; do
    [ -f "$php_ini" ] || continue
    sed -i "s/^\s*upload_max_filesize\s*=.*/upload_max_filesize = ${PHP_UPLOAD_LIMIT}/" "$php_ini" || true
    sed -i "s/^\s*post_max_size\s*=.*/post_max_size = ${POST_MAX_SIZE}/" "$php_ini" || true
    sed -i "s/^\s*memory_limit\s*=.*/memory_limit = ${MEMORY_LIMIT}/" "$php_ini" || true
    sed -i "s/^\s*max_execution_time\s*=.*/max_execution_time = ${MAX_EXEC_TIME}/" "$php_ini" || true
done
systemctl restart apache2

# --- 7️⃣ CREATE DATABASE AND USER ---
if [ ! -f "${CRED_FILE}" ]; then
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
    mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    # Save credentials
    {
        echo "DB_NAME=${DB_NAME}"
        echo "DB_USER=${DB_USER}"
        echo "DB_PASS=${DB_PASS}"
        echo "DOMAIN=${DOMAIN}"
        echo "WEB_ROOT=${WEB_ROOT}"
    } > "${CRED_FILE}"
    chmod 600 "${CRED_FILE}"
fi
source "${CRED_FILE}"

# --- 8️⃣ DOWNLOAD AND INSTALL WORDPRESS ---
if [ ! -f "${WEB_ROOT}/wp-config.php" ]; then
    cd /tmp
    wget -q https://wordpress.org/latest.zip -O wordpress_latest.zip
    unzip -q wordpress_latest.zip
    rm -rf "${WEB_ROOT}"/*
    cp -a wordpress/. "${WEB_ROOT}/"
    chown -R www-data:www-data "${WEB_ROOT}"
    find "${WEB_ROOT}" -type d -exec chmod 755 {} \;
    find "${WEB_ROOT}" -type f -exec chmod 644 {} \;
fi

# --- 9️⃣ CONFIGURE wp-config.php ---
cd "${WEB_ROOT}"
if [ ! -f wp-config.php ]; then
    cp wp-config-sample.php wp-config.php
    perl -i -pe "s/define\(\s*'DB_NAME'.*/define('DB_NAME', '${DB_NAME}');/" wp-config.php
    perl -i -pe "s/define\(\s*'DB_USER'.*/define('DB_USER', '${DB_USER}');/" wp-config.php
    ESCAPED_DB_PASS=$(printf "%s" "$DB_PASS" | sed "s/'/'\\\\''/g")
    perl -i -pe "s/define\(\s*'DB_PASSWORD'.*/define('DB_PASSWORD', '${ESCAPED_DB_PASS}');/" wp-config.php

    SALT=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
    perl -0777 -i -pe "s/define\('AUTH_KEY'.*?define\('NONCE_SALT'.*?\);\n/${SALT}\n/s" wp-config.php || echo "${SALT}" >> wp-config.php

    chown www-data:www-data wp-config.php
    chmod 640 wp-config.php
fi

# --- 🔟 WP CONTENT UPLOADS ---
mkdir -p "${WEB_ROOT}/wp-content/uploads"
chown -R www-data:www-data "${WEB_ROOT}"
find "${WEB_ROOT}/wp-content" -type d -exec chmod 775 {} \;
find "${WEB_ROOT}/wp-content" -type f -exec chmod 664 {} \;

# --- 1️⃣1️⃣ OPTIONAL WP URL UPDATE ---
mysql "${DB_NAME}" -e "UPDATE wp_options SET option_value = CONCAT('https://','${DOMAIN}') WHERE option_name IN ('siteurl','home');" || true

# --- 1️⃣2️⃣ CERTBOT SSL ---
certbot --apache -n --agree-tos --email "${CERT_EMAIL}" -d "${DOMAIN}" -d "www.${DOMAIN}" || echo "Certbot skipped/failed."

# --- 1️⃣3️⃣ FINAL APACHE RELOAD ---
systemctl reload apache2 || systemctl restart apache2

# --- 1️⃣4️⃣ PRINT SITE URL IN GREEN CLICKABLE FORMAT ---
GREEN="\e[32m"
RESET="\e[0m"
URL="https://${DOMAIN}/wp-admin/install.php"
echo -e "=== Done ==="
echo -e "Visit: \e]8;;${URL}\a${GREEN}${URL}${RESET}\e]8;;\a"
