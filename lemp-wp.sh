#!/bin/bash

echo "=== LEMP + WordPress + Redis LXC Auto-Installer for Proxmox ==="

# --- Template selection (scans all storages with vztmpl content) ---
storages=$(pvesm status --content vztmpl | awk 'NR>1 {print $1}')
TEMPLATES=()
for storage in $storages; do
    while read -r line; do
        # Only add Debian templates
        if [[ "$line" =~ debian ]]; then
            TEMPLATES+=("$line")
        fi
    done < <(pvesm list "$storage" --content vztmpl | awk '$1 ~ /debian/ {print $1}')
done

if [[ ${#TEMPLATES[@]} -eq 0 ]]; then
    echo "No Debian LXC templates found on any storage! Please download one in Proxmox GUI and rerun this script."
    exit 1
fi

echo "Available Debian templates:"
for i in "${!TEMPLATES[@]}"; do
    echo "$((i+1))) ${TEMPLATES[$i]}"
done
DEFAULT_TEMPLATE_INDEX=$((${#TEMPLATES[@]}-1))

read -p "Enter the number of the template to use (default: $((DEFAULT_TEMPLATE_INDEX+1))): " TEMPLATE_INDEX
TEMPLATE_INDEX=${TEMPLATE_INDEX:-$((DEFAULT_TEMPLATE_INDEX+1))}
TEMPLATE="${TEMPLATES[$((TEMPLATE_INDEX-1))]}"

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
        CONTAINER_IP="${IP%%/*}"
    else
        NET0_OPTIONS="name=eth0,bridge=vmbr0,ip=$IP"
        CONTAINER_IP="${IP%%/*}"
    fi
else
    IP="dhcp"
    NET0_OPTIONS="name=eth0,bridge=vmbr0,ip=$IP"
    CONTAINER_IP="" # will detect after container starts
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

# If using DHCP, dynamically get the container's IP from the host
if [[ -z "$CONTAINER_IP" ]]; then
    # Wait for container to get an IP
    echo "Waiting for container to obtain an IP address..."
    for i in {1..15}; do
        CONTAINER_IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')
        if [[ "$CONTAINER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        fi
        sleep 2
    done
    if [[ -z "$CONTAINER_IP" ]]; then
        echo "Could not detect container IP address. Exiting."
        exit 1
    fi
fi

echo "Container IP detected: $CONTAINER_IP"

echo "Provisioning LEMP, Redis, and WordPress in container $CTID..."

pct exec $CTID -- bash -c "
apt update && apt upgrade -y
apt install -y locales
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/^# *en_US ISO-8859-1/en_US ISO-8859-1/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8
export LANG=en_US.UTF-8
echo 'LANG=en_US.UTF-8' > /etc/default/locale

apt install -y nginx mariadb-server php-fpm php-mysql php-xml php-gd php-curl php-zip php-mbstring wget unzip redis-server php-redis

systemctl enable redis-server
systemctl start redis-server

mysql -u root <<EOF
CREATE DATABASE wordpress DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL ON wordpress.* TO 'wpuser'@'localhost' IDENTIFIED BY '$DBPASS';
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

# Set WordPress siteurl/home to the actual container IP
echo \"define('WP_HOME','http://$CONTAINER_IP');\" >> /var/www/html/wp-config.php
echo \"define('WP_SITEURL','http://$CONTAINER_IP');\" >> /var/www/html/wp-config.php

cat <<'REDISCONF' >> /var/www/html/wp-config.php

// Redis Object Cache
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_PASSWORD', null);
REDISCONF

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
echo "WordPress URL: http://$CONTAINER_IP/"
echo "LXC root password: $ROOT_PASSWORD"
echo
echo "After installation, log in to WordPress admin to finish Redis plugin setup."
