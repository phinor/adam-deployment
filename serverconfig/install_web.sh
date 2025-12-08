#!/bin/bash
set -e

# --- Configuration ---
# Change this version number to upgrade PHP later!
PHP_VERSION="8.4" 
TIMEZONE="Africa/Johannesburg"
LOGFILE="/var/log/adam_web_install.log"

# --- Functions ---

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "❌ Run as root."
        exit 1
    fi
}

log() {
    echo "[$(date +'%F %T')] $1" | tee -a "$LOGFILE"
}

install_repos() {
    log "Adding Repositories..."
    LC_ALL=C.UTF-8 add-apt-repository -yn ppa:ondrej/php >> "$LOGFILE" 2>&1
    LC_ALL=C.UTF-8 add-apt-repository -yn ppa:ondrej/apache2 >> "$LOGFILE" 2>&1
    apt-get update -qy >> "$LOGFILE" 2>&1
}

install_mysql() {
    # Only prompts and installs if MySQL isn't already running
    if ! systemctl is-active --quiet mysql; then
        log "Installing MySQL..."
        read -s -p "Enter a NEW root password for MySQL: " mysqlpw
        echo
        DEBIAN_FRONTEND=noninteractive apt-get install -qy mysql-server >> "$LOGFILE" 2>&1
        
        log "Securing MySQL..."
        mysql -sfu root <<EOF
ALTER USER "root"@"localhost" IDENTIFIED BY "${mysqlpw}";
DELETE FROM mysql.user WHERE User="";
DELETE FROM mysql.user WHERE User="root" AND Host NOT IN ("localhost", "127.0.0.1", "::1");
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
EOF
        # Allow stored funcs
        if ! grep -q "log_bin_trust_function_creators" /etc/mysql/mysql.conf.d/mysqld.cnf; then
            echo "log_bin_trust_function_creators = 1" | tee -a /etc/mysql/mysql.conf.d/mysqld.cnf
        fi
        systemctl restart mysql
    else
        log "MySQL is already running. Skipping setup."
    fi
}

install_php_fpm() {
    log "Installing PHP $PHP_VERSION (FPM)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -qy \
        apache2 \
        "php$PHP_VERSION-fpm" \
        "php$PHP_VERSION-cli" \
        "php$PHP_VERSION-mysql" \
        "php$PHP_VERSION-xml" \
        "php$PHP_VERSION-curl" \
        "php$PHP_VERSION-mbstring" \
        "php$PHP_VERSION-zip" \
        "php$PHP_VERSION-gd" \
        "php$PHP_VERSION-intl" \
        "php$PHP_VERSION-ldap" \
        "php$PHP_VERSION-imap" \
        python3-certbot-apache >> "$LOGFILE" 2>&1
}

configure_php() {
    log "Applying PHP Configuration Override..."
    # We use FPM, so we configure the FPM pool and CLI
    for path in "fpm" "cli"; do
        DEST="/etc/php/$PHP_VERSION/$path/conf.d/99-adam-custom.ini"
        cat <<EOF > "$DEST"
max_input_vars = 5000
post_max_size = 1G
upload_max_filesize = 500M
max_file_uploads = 200
date.timezone = $TIMEZONE
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
display_errors = Off
EOF
    done
}

install_composer() {
    if ! command -v composer &> /dev/null; then
        log "Installing Composer..."
        EXPECTED=$(wget -q -O - https://composer.github.io/installer.sig)
        php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
        ACTUAL=$(php -r "echo hash_file('sha384', 'composer-setup.php');")

        if [ "$EXPECTED" != "$ACTUAL" ]; then
            log "❌ Composer signature invalid."
            rm composer-setup.php
            exit 1
        fi
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
        rm composer-setup.php
    else
        log "Composer already installed. Self-updating..."
        composer self-update --quiet || true
    fi
}

switch_apache_version() {
    log "Configuring Apache to use PHP $PHP_VERSION-FPM..."
    
    # 1. Enable proxy modules
    a2enmod proxy_fcgi setenvif rewrite headers ssl >> "$LOGFILE" 2>&1
    
    # 2. Disable ALL other PHP FPM configs currently enabled
    # This ensures we don't have two versions active after an upgrade
    CURRENT_CONFS=$(a2query -c | grep "php.*-fpm" | cut -d ' ' -f 1 || true)
    for conf in $CURRENT_CONFS; do
        if [ "$conf" != "php$PHP_VERSION-fpm" ]; then
             log "Disabling old config: $conf"
             a2disconf "$conf" >> "$LOGFILE" 2>&1
        fi
    done

    # 3. Disable mod_php if it exists (we are using FPM)
    a2dismod php* >> "$LOGFILE" 2>&1 || true

    # 4. Enable the target version
    a2enconf "php$PHP_VERSION-fpm" >> "$LOGFILE" 2>&1
    
    systemctl restart "php$PHP_VERSION-fpm"
    systemctl restart apache2
}

update_firewall_web() {
    log "Updating Firewall for Web Traffic..."
    if command -v ufw &> /dev/null; then
        ufw allow 80/tcp comment 'HTTP' >> "$LOGFILE" 2>&1
        ufw allow 443/tcp comment 'HTTPS' >> "$LOGFILE" 2>&1
        ufw reload >> "$LOGFILE" 2>&1
    fi
}

# --- Main Execution ---
check_root
log "Starting Web Stack Installation (Target: PHP $PHP_VERSION)..."

install_repos
install_mysql
install_php_fpm
configure_php
install_composer
switch_apache_version
update_firewall_web

# Download Default Index if missing
if [ ! -f /var/www/html/index.html ]; then
    log "Downloading default index page..."
    curl -L -k "https://school1.adam.co.za/index.html" -o /var/www/html/index.html || true
fi

echo
echo "✅ Web Stack setup complete!"
echo "PHP Version: $(php -r 'echo PHP_VERSION;')"
echo "MySQL and Apache are running."
