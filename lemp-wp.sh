#!/bin/bash

echo "=== LEMP + WordPress + Redis + Cloudflare LXC Auto-Installer for Proxmox ==="

# --- Template selection ---
echo "Available Debian templates on local storage:"
TEMPLATES=($(pvesm list local --content vztmpl | awk '$6 ~ /debian/ {print $6}'))
for i in "${!TEMPLATES[@]}"; do
    echo "$((i+1))) ${TEMPLATES[$i]}"
done
DEFAULT_TEMPLATE_INDEX=$((${#TEMPLATES[@]}-1))
DEFAULT_TEMPLATE="${TEMPLATES[$DEFAULT_TEMPLATE_INDEX]}"

read -p "Enter the number of the template to use (default: $((DEFAULT_TEMPLATE_INDEX+1))): " TEMPLATE_INDEX
TEMPLATE_INDEX=${TEMPLATE_INDEX:-$((DEFAULT_TEMPLATE_INDEX+1))}
TEMPLATE="${TEMPLATES[$((TEMPLATE_INDEX-1))]}"
TEMPLATE="local:vztmpl/$TEMPLATE"

# --- LXC parameters ---
read -p "Container hostname (default: wp-site): " HOSTNAME
HOSTNAME=${HOSTNAME:-wp-site}
read -p "Container disk size in GB (default: 10): " DISK
DISK=${DISK:-10}
read -p "Container memory in MB (default: 4096): " MEMORY
MEMORY=${MEMORY:-4096}
read -p "CPU cores (default: 4): " CORES
CORES=${CORES:-4}

echo "Available storages:"
pvesm status --content rootdir | awk 'NR>1{print $1}'
read -p "Which storage to use for rootfs? (e.g. local-zfs): " STORAGE
STORAGE=${STORAGE:-local-zfs}

read -p "Network type (dhcp/static) [default: dhcp]: " NET_TYPE
NET_TYPE=${NET_TYPE:-dhcp}
if [[ "$NET_TYPE" == "static" ]]; then
    read -p "IP address (e.g., 192.168.1.100/24): " IP
    read -p "Gateway: " GATEWAY
    if [[ -n "$GATEWAY" ]]; then
        NET0_OPTIONS="name=eth0,bridge=vmbr0,ip=$IP,gw=$GATEWAY"
    else
        NET0_OPTIONS="name=eth0,bridge=vmbr0,ip=$IP"
    fi
else
    IP="dhcp"
    NET0_OPTIONS="name=eth0,bridge=vmbr0,ip=$IP"
fi

read -s -p "Root password for LXC: " ROOT_PASSWORD
echo

CTID=$(pvesh get /cluster/nextid)
DBPASS=$(openssl rand -base64 16)

echo "Creating LXC container $CTID on $STORAGE with template $TEMPLATE..."
pct create $CTID $TEMPLATE \
  --hostname $HOSTNAME \
  --cores $CORES \
  --memory $MEMORY \
  --rootfs ${STORAGE}:$DISK \
  --net0 "$NET0_OPTIONS" \
  --password $ROOT_PASSWORD \
  --features nesting=1 \
  --unprivileged 1

pct start $CTID
sleep 10

echo "Provisioning LEMP, Redis, and WordPress in container $CTID..."

pct exec $CTID -- bash -c "
apt update && apt upgrade -y
apt install -y locales
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
export LANG=en_US.UTF-8

apt install -y nginx mariadb-server php-fpm php-mysql php-xml php-gd php-curl php-zip php-mbstring wget unzip redis-server php-redis

systemctl enable redis-server
systemctl start redis-server

mysql -u root <<EOF
CREATE DATABASE wordpress;
CREATE USER 'wpuser'@'localhost' IDENTIFIED BY '$DBPASS';
GRANT ALL PRIVILEGES ON wordpress.* TO 'wpuser'@'localhost';
FLUSH PRIVILEGES;
EOF

cd /tmp
wget -q https://wordpress.org/latest.tar.gz
tar -xf latest.tar.gz
cp -r wordpress/* /var/www/html/
chown -R www-data:www-data /var/www/html
rm -rf wordpress latest.tar.gz

cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php
sed -i \"s/database_name_here/wordpress/\" /var/www/html/wp-config.php
sed -i \"s/username_here/wpuser/\" /var/www/html/wp-config.php
sed -i \"s/password_here/$DBPASS/\" /var/www/html/wp-config.php

cat <<'REDISCONF' >> /var/www/html/wp-config.php

// Redis Object Cache
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_PASSWORD', null);
REDISCONF

cat <<'CLOUDFLARE_HTTPS_FIX' >> /var/www/html/wp-config.php

// Cloudflare HTTPS fix
if (
    (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') ||
    (isset(\$_SERVER['HTTP_X_FORWARDED_SSL']) && \$_SERVER['HTTP_X_FORWARDED_SSL'] === 'on')
) {
    \$_SERVER['HTTPS'] = 'on';
}
CLOUDFLARE_HTTPS_FIX

cat > /etc/nginx/sites-available/wordpress <<NGINX
server {
    listen 80;
    server_name _;
    root /var/www/html;
    index index.php index.html index.htm;
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
    }
    location ~ /\.ht {
        deny all;
    }
}
NGINX
ln -sf /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl reload nginx

cd /var/www/html/wp-content/plugins/
wget -q https://downloads.wordpress.org/plugin/cloudflare.latest-stable.zip
unzip -q cloudflare.latest-stable.zip
rm cloudflare.latest-stable.zip

wget -q https://downloads.wordpress.org/plugin/redis-cache.latest-stable.zip
unzip -q redis-cache.latest-stable.zip
rm redis-cache.latest-stable.zip

chown -R www-data:www-data /var/www/html/wp-content/plugins
"

echo
echo "=== Deployment Complete ==="
echo "LXC ID: $CTID"
echo "MySQL user: wpuser"
echo "MySQL pass: $DBPASS"
echo "WordPress URL: http://<container-ip>/"
echo "LXC root password: $ROOT_PASSWORD"
echo
echo "After installation, log in to WordPress admin to finish Cloudflare and Redis plugin setup."
