# lemp-wp-enhance.sh version: 1.3.0
VERSION="1.3.0"
echo "[INFO] lemp-wp-enhance.sh version: $VERSION"
set -e

echo "[INFO] Enhancing PHP Opcache..."

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

echo "[INFO] Tuning MariaDB query cache..."

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

echo "[INFO] Configuring Nginx gzip compression..."

NGINX_CONF="/etc/nginx/nginx.conf"

echo "[INFO] Removing any conflicting fastcgi_cache.conf includes..."
if [ -f "/etc/nginx/conf.d/fastcgi_cache.conf" ]; then
  rm -f /etc/nginx/conf.d/fastcgi_cache.conf
fi

if ! grep -q "gzip on" $NGINX_CONF; then
  sed -i '/http {/a \
  gzip on;\
  gzip_vary on;\
  gzip_proxied any;\
  gzip_comp_level 6;\
  gzip_buffers 16 8k;\
  gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;\
  ' $NGINX_CONF
fi

SITE_CONF="/etc/nginx/sites-available/wordpress"

# Always replace the static file cache block (idempotent & safe placement)
if [ -f "$SITE_CONF" ]; then
  echo "[INFO] Ensuring static file cache block in $SITE_CONF"
  sed -i '/### BEGIN STATIC CACHE ###/,/### END STATIC CACHE ###/d' "$SITE_CONF"
  awk '
  /server[ \t]*{/ { in_server=1 }
  in_server && /\}/ && !static_done {
    print "    ### BEGIN STATIC CACHE ###"
    print "    location ~* \\.(jpg|jpeg|png|gif|ico|css|js|pdf|txt|tar|woff|woff2|ttf|svg|eot|mp4|ogg|webm)$ {"
    print "        expires 30d;"
    print "        add_header Pragma public;"
    print "        add_header Cache-Control \"public\";"
    print "    }"
    print "    ### END STATIC CACHE ###"
    print ""
    static_done=1
  }
  { print }
  ' "$SITE_CONF" > "${SITE_CONF}.tmp" && mv "${SITE_CONF}.tmp" "$SITE_CONF"
fi

# Always replace FastCGI cache block (idempotent)
if [ -f "$SITE_CONF" ]; then
  echo "[INFO] Ensuring FastCGI cache directives in PHP location block in $SITE_CONF"
  sed -i '/### BEGIN FASTCGI CACHE ###/,/### END FASTCGI CACHE ###/d' "$SITE_CONF"
  awk '
  /location ~ \.php\$/ && !fastcgi_done {
    print "    ### BEGIN FASTCGI CACHE ###"
    print "        fastcgi_cache WORDPRESS;"
    print "        fastcgi_cache_valid 200 60m;"
    print "        add_header X-FastCGI-Cache $$upstream_cache_status;"
    print "    ### END FASTCGI CACHE ###"
    fastcgi_done=1
    next
  }
  {print}
  ' "$SITE_CONF" > "${SITE_CONF}.tmp" && mv "${SITE_CONF}.tmp" "$SITE_CONF"
fi

# Always ensure FastCGI cache config in nginx.conf (remove old block, insert fresh)
if grep -q "### BEGIN FASTCGI CACHE ZONE ###" $NGINX_CONF; then
  sed -i '/### BEGIN FASTCGI CACHE ZONE ###/,/### END FASTCGI CACHE ZONE ###/d' $NGINX_CONF
fi
if ! grep -q "fastcgi_cache_path" $NGINX_CONF; then
  echo "[INFO] Ensuring FastCGI cache zone config in $NGINX_CONF"
  sed -i '/http {/a \
  ### BEGIN FASTCGI CACHE ZONE ###\
  fastcgi_cache_path /var/cache/nginx levels=1:2 keys_zone=WORDPRESS:100m inactive=60m;\
  fastcgi_cache_key "$scheme$request_method$host$request_uri";\
  fastcgi_cache_use_stale error timeout invalid_header http_500;\
  fastcgi_ignore_headers Cache-Control Expires Set-Cookie;\
  ### END FASTCGI CACHE ZONE ###\
  ' $NGINX_CONF
fi

mkdir -p /var/cache/nginx
chown -R www-data:www-data /var/cache/nginx

# Security hardening (idempotent)
echo "[INFO] Applying security hardening..."
sed -i 's/server_tokens on;/server_tokens off;/g' $NGINX_CONF || true
sed -i 's/expose_php = On/expose_php = Off/' "$PHP_INI" || true
sed -i 's/^disable_functions =.*/disable_functions = exec,passthru,shell_exec,system,proc_open,popen,curl_exec,curl_multi_exec,parse_ini_file,show_source/' "$PHP_INI"
if ! grep -q open_basedir "$PHP_INI"; then
  echo "open_basedir = /var/www/html:/tmp/" >> "$PHP_INI"
fi
if [ -f "$SITE_CONF" ]; then
  sed -i '/autoindex off/d' $SITE_CONF
  sed -i '/root \/var\/www\/html;/a \    autoindex off;' $SITE_CONF
fi

find /var/www/html -type d -exec chmod 755 {} \;
find /var/www/html -type f -exec chmod 644 {} \;

echo "[INFO] Restarting services..."
systemctl restart nginx
systemctl restart php*-fpm
systemctl restart mariadb

echo
echo "=== Enhancement and hardening complete ==="
echo "Opcache, query cache, gzip, browser cache, FastCGI cache, and security tweaks applied."
echo "Test your site thoroughly before merging these changes into your main installer."
