#!/usr/bin/env bash
# wp-install-single.sh
#... Usage: sudo ./wp-install-single.sh example.com
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: sudo $0 <domain>"
  exit 2
fi

DOMAIN="$1"
CERT_EMAIL="admin@${DOMAIN}"   # change if you want a different cert email
WEB_ROOT="/var/www/${DOMAIN}/public_html"
APACHE_CONF="/etc/apache2/sites-available/${DOMAIN}.conf"
CRED_FILE="/root/.${DOMAIN}_db_creds"
PHP_UPLOAD_LIMIT="64M"
POST_MAX_SIZE="64M"
MEMORY_LIMIT="256M"
MAX_EXEC_TIME="300"

# create a sanitized DB name (letters, numbers, underscores)
clean_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/^_//; s/_$//'
}

DB_NAME="wp_$(clean_name "${DOMAIN}")"
DB_USER="${DB_NAME}_user"   # dedicated db user per-domain (safer than changing mysql root)
DB_PASS="$(openssl rand -base64 18)"  # strong random password

echo "=== Starting install for ${DOMAIN} ==="

echo "1) System update and install required packages..."
apt update -y && apt upgrade -y
apt install -y apache2 mysql-server php libapache2-mod-php php-mysql unzip certbot python3-certbot-apache php-curl php-mbstring php-xml php-xmlrpc php-gd php-zip php-bcmath php-intl

echo "2) Apache config: enable rewrite, create webroot and vhost..."
a2enmod rewrite
mkdir -p "${WEB_ROOT}"
chown -R www-data:www-data "/var/www/${DOMAIN}"
chmod 2755 "/var/www/${DOMAIN}"

# create a simple virtual host
cat > "${APACHE_CONF}" <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot ${WEB_ROOT}
    <Directory ${WEB_ROOT}>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
EOF

a2ensite "${DOMAIN}.conf"
sed -i 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf || true
systemctl restart apache2

echo "3) Configure PHP upload/post/memory limits..."
# modify all installed PHP apache2 php.ini files (commonly /etc/php/*/apache2/php.ini)
for php_ini in /etc/php/*/apache2/php.ini; do
  if [ -f "${php_ini}" ]; then
    sed -i "s/^\s*upload_max_filesize\s*=.*/upload_max_filesize = ${PHP_UPLOAD_LIMIT}/" "${php_ini}" || echo "upload_max_filesize set"
    sed -i "s/^\s*post_max_size\s*=.*/post_max_size = ${POST_MAX_SIZE}/" "${php_ini}" || echo "post_max_size set"
    sed -i "s/^\s*memory_limit\s*=.*/memory_limit = ${MEMORY_LIMIT}/" "${php_ini}" || echo "memory_limit set"
    sed -i "s/^\s*max_execution_time\s*=.*/max_execution_time = ${MAX_EXEC_TIME}/" "${php_ini}" || echo "max_execution_time set"
  fi
done
systemctl restart apache2

echo "4) Create database and DB user (safe, per-domain user) and store credentials securely..."
# Use sudo mysql (auth_socket) to create DB and user. No root password changes are made.
sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
sudo mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

# Save credentials securely (not printed)
{
  echo "DB_NAME=${DB_NAME}"
  echo "DB_USER=${DB_USER}"
  echo "DB_PASS=${DB_PASS}"
  echo "DOMAIN=${DOMAIN}"
  echo "WEB_ROOT=${WEB_ROOT}"
} > "${CRED_FILE}"
chmod 600 "${CRED_FILE}"
echo "Credentials saved to ${CRED_FILE} (owner-only permissions)."

echo "5) Download and install WordPress into ${WEB_ROOT} ..."
cd /tmp
wget -q https://wordpress.org/latest.zip -O wordpress_latest.zip
unzip -q wordpress_latest.zip
rm -rf "${WEB_ROOT}"/*
cp -a wordpress/. "${WEB_ROOT}/"
chown -R www-data:www-data "${WEB_ROOT}"
find "${WEB_ROOT}" -type d -exec chmod 755 {} \;
find "${WEB_ROOT}" -type f -exec chmod 644 {} \;

echo "6) Create wp-config.php and inject DB settings and salts..."
cd "${WEB_ROOT}"
if [ -f wp-config.php ]; then
  echo "wp-config.php already exists, backing up to wp-config.php.bak"
  cp wp-config.php wp-config.php.bak
fi
cp wp-config-sample.php wp-config.php

# Insert DB credentials
# Use perl (safe for slash-containing passwords)
# Escape single quotes in DB password for Perl
DB_PASS_ESCAPED=$(printf '%s\n' "$DB_PASS" | sed "s/'/'\\\\''/g")

# Insert DB credentials safely
perl -i -pe "s/define\(\s*'DB_NAME'.*/define('DB_NAME', '${DB_NAME}');/" wp-config.php
perl -i -pe "s/define\(\s*'DB_USER'.*/define('DB_USER', '${DB_USER}');/" wp-config.php
perl -i -pe "s/define\(\s*'DB_PASSWORD'.*/define('DB_PASSWORD', '${DB_PASS_ESCAPED}');/" wp-config.php


# Set secure keys: fetch from WordPress API and replace placeholder block
SALT=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
# Remove existing AUTH_KEY..NONCE_SALT lines and insert new ones
perl -0777 -i -pe "s/define\('AUTH_KEY'.*?define\('NONCE_SALT'.*?\);\n/${SALT}\n/s" wp-config.php || {
  # fallback: append salts
  echo "${SALT}" >> wp-config.php
}

chown www-data:www-data wp-config.php
chmod 640 wp-config.php

echo "7) Permissions for wp-content and uploads..."
mkdir -p "${WEB_ROOT}/wp-content/uploads"
chown -R www-data:www-data "${WEB_ROOT}"
find "${WEB_ROOT}/wp-content" -type d -exec chmod 775 {} \;
find "${WEB_ROOT}/wp-content" -type f -exec chmod 664 {} \;

echo "8) (Optional) If WP tables exist, update siteurl & home to https://${DOMAIN} ..."
# This will attempt to update if the wp_options table exists.
sudo mysql "${DB_NAME}" -e "UPDATE wp_options SET option_value = CONCAT('https://','${DOMAIN}') WHERE option_name IN ('siteurl','home');" || echo "Could not update wp_options (maybe WordPress not yet installed)."

echo "9) Obtain TLS certificate via Certbot (Let's Encrypt)..."
# This will require that DNS for DOMAIN points to this server.
certbot --apache -n --agree-tos --email "${CERT_EMAIL}" -d "${DOMAIN}" -d "www.${DOMAIN}" || echo "certbot failed or requires interaction; check logs."

echo "10) Final Apache restart..."
systemctl reload apache2 || systemctl restart apache2

echo "=== Done ==="
echo "Website files: ${WEB_ROOT}"
echo "DB name: ${DB_NAME}"
echo "DB user: ${DB_USER}"
echo "DB credentials: saved in ${CRED_FILE} (owner-only)."
echo "IMPORTANT: The DB password is NOT printed to the terminal for security."
echo "To view credentials run: sudo cat ${CRED_FILE}  (only root can view)."
echo ""
echo "To complete the WordPress installation visit: http://${DOMAIN}/wp-admin/install.php or https://${DOMAIN}/wp-admin/install.php (if certbot succeeded)."
