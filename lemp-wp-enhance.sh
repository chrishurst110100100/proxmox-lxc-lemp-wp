#!/bin/bash

set -e

# 1. Enable and tune PHP Opcache
PHP_INI=$(php --ini | grep "Loaded Configuration" | awk '{print $4}')
OPCACHE_INI=$(php -r 'echo PHP_VERSION_ID >= 80000 ? "/etc/php/8.2/fpm/conf.d/10-opcache.ini" : "/etc/php/7.4/fpm/conf.d/10-opcache.ini";')
OPCACHE_INI=${OPCACHE_INI:-/etc/php/$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')/fpm/conf.d/10-opcache.ini}

cat <<EOF > "$OPCACHE_INI"
zend_extension=opcache.so
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
opcache.validate_timestamps=1
opcache.save_comments=1
opcache.fast_shutdown=1
EOF

# 2. Enable MariaDB Query Cache
MARIADB_CNF="/etc/mysql/mariadb.conf.d/50-server.cnf"
if ! grep -q query_cache_size $MARIADB_CNF; then
  echo '
# Query cache settings
query_cache_type = 1
query_cache_limit = 1M
query_cache_min_res_unit = 2k
query_cache_size = 64M
' >> "$MARIADB_CNF"
fi

# 3. Enable Nginx Gzip Compression and Browser Caching
NGINX_CONF="/etc/nginx/nginx.conf"
if ! grep -q "gzip on" $NGINX_CONF; then
  sed -i '/http {/a \
  gzip on;\
  gzip_vary on;\
  gzip_proxied any;\
  gzip_comp_level 6;\
  gzip_buffers 16 8k;\
  gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;\
  \
  # Browser cache\
  include /etc/nginx/conf.d/cache_static.conf;\
  ' $NGINX_CONF
fi

# Create static cache settings if not present
cat <<'EOC' > /etc/nginx/conf.d/cache_static.conf
location ~* \.(jpg|jpeg|png|gif|ico|css|js|pdf|txt|tar|woff|woff2|ttf|svg|eot|mp4|ogg|webm)$ {
    expires 30d;
    add_header Pragma public;
    add_header Cache-Control "public";
}
EOC

# 4. Enable FastCGI Cache for Nginx
cat <<'EOC' > /etc/nginx/conf.d/fastcgi_cache.conf
fastcgi_cache_path /var/cache/nginx levels=1:2 keys_zone=WORDPRESS:100m inactive=60m;
fastcgi_cache_key "$scheme$request_method$host$request_uri";
fastcgi_cache_use_stale error timeout invalid_header http_500;
fastcgi_ignore_headers Cache-Control Expires Set-Cookie;
EOC

mkdir -p /var/cache/nginx
chown -R www-data:www-data /var/cache/nginx

# Add FastCGI cache and security to site config (idempotent)
SITE_CONF="/etc/nginx/sites-available/wordpress"
if ! grep -q fastcgi_cache $SITE_CONF; then
  awk '/location ~ \\.php\\$/ {
    print;
    print "        fastcgi_cache WORDPRESS;";
    print "        fastcgi_cache_valid 200 60m;";
    print "        add_header X-FastCGI-Cache $upstream_cache_status;";
    next
  }1' $SITE_CONF > ${SITE_CONF}.tmp && mv ${SITE_CONF}.tmp $SITE_CONF
fi

# 5. Security hardening
# Hide versions
sed -i 's/server_tokens on;/server_tokens off;/g' $NGINX_CONF || true
sed -i 's/expose_php = On/expose_php = Off/' "$PHP_INI" || true

# Disable dangerous PHP functions
sed -i 's/^disable_functions =.*/disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source/' "$PHP_INI"

# Set open_basedir
if ! grep -q open_basedir "$PHP_INI"; then
  echo "open_basedir = /var/www/html:/tmp/" >> "$PHP_INI"
fi

# Restrict directory listing in Nginx
if ! grep -q "autoindex off" $SITE_CONF; then
  sed -i '/root \/var\/www\/html;/a \    autoindex off;' $SITE_CONF
fi

# Set file and dir permissions
find /var/www/html -type d -exec chmod 755 {} \;
find /var/www/html -type f -exec chmod 644 {} \;

systemctl restart nginx
systemctl restart php*-fpm
systemctl restart mariadb

echo
echo "=== Enhancement and hardening complete ==="
echo "Opcache, query cache, gzip, browser cache, FastCGI cache, and security tweaks applied."
echo "Test your site thoroughly before merging these changes into your main installer."
