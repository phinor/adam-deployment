#!/bin/bash
set -e  # Exit immediately if a command exits with a non-zero status.
set -u  # Treat unset variables as an error.
set -o pipefail # Return value of a pipeline is the status of the last command to exit with a non-zero status.

# --- ROOT PRIVILEGE CHECK ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root."
   echo "Please run it using: sudo $0"
   exit 1
fi

# --- DETERMINE REAL USER ---
# If SUDO_USER is set, use it; otherwise fallback to current user (root)
REAL_USER="${SUDO_USER:-$(whoami)}"

# --- Configuration & Constants ---
BASE_WEB_DIR="/var/webdata"
APP_BASE_DIR="/var/www/adam"
BASE_APP_DIR="$APP_BASE_DIR/live"
# School configuration files live outside every release; each release holds a link to each one.
# deploy.sh keeps the links (sync-configs.sh).
CONFIGS_DIR="$APP_BASE_DIR/configs"
DEPLOY_MUTEX="$APP_BASE_DIR/deploy.mutex"
APACHE_AVAIL_DIR="/etc/apache2/sites-available"
LOG_FILE="./adam_setup.log"

# --- Formatting ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Functions ---

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
    echo -e "${RED}ERROR: $1${NC}"
    log "ERROR: $1"
    exit 1
}

generate_password() {
    local pass
    while true; do
        # FIXED: Use raw bytes (openssl rand 500) instead of base64.
        pass=$(LC_ALL=C openssl rand 500 | tr -dc 'a-zA-Z0-9!@^_-' | head -c 20)

        # Verify compliance: Must have Upper, Lower, Digit, AND Symbol
        if echo "$pass" | grep -q '[A-Z]' && \
           echo "$pass" | grep -q '[a-z]' && \
           echo "$pass" | grep -q '[0-9]' && \
           echo "$pass" | grep -q '[!@^_-]'; then
            echo "$pass"
            break
        fi
    done
}

test_mysql_connection() {
    local host=$1
    local user=$2
    local pass=$3
    local db=$4
    
    if mysql -h "$host" -u "$user" -p"$pass" "$db" -e "quit" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# --- Main Script ---

clear
echo "=================================================="
echo "   ADAM Setup Script: Robust & Secure             "
echo "=================================================="
echo

# 1. School Name
read -p "Enter the folder name for the school (e.g. stmarys): " raw_school
school=$(echo "$raw_school" | tr -dc 'a-zA-Z0-9')

if [[ -z "$school" ]]; then
    error_exit "School name cannot be empty."
fi

# --- SAFETY CHECK 1: DIRECTORIES ---
if [[ -d "$BASE_WEB_DIR/adam/$school" ]]; then
    error_exit "Directory '$BASE_WEB_DIR/adam/$school' ALREADY EXISTS.\n       Aborting to prevent data loss. Please check the name or clean up manually."
fi

# 2. Domain Name
read -p "Enter the full domain name (e.g. school.adam.co.za): " domain

# 2b. Cloudflare custom origin name
# A school on its own domain (a Cloudflare for SaaS custom hostname) reaches this server through
# the custom origin set on that hostname. Cloudflare connects with the ORIGIN name as the TLS name
# (SNI) and the school's domain as the Host header, so Apache must answer to both in one site, and
# the certificate must carry both. Without that, Cloudflare reports error 526.
echo
echo "If '$domain' is a Cloudflare custom hostname, enter the custom origin server set on it in"
echo "Cloudflare (e.g. saints.school.adam.co.za). Leave blank for an ordinary *.adam.co.za school."
read -p "Cloudflare custom origin name [none]: " origin_name
origin_name=$(echo "$origin_name" | tr -d '[:space:]')

if [[ -n "$origin_name" && "$origin_name" == "$domain" ]]; then
    error_exit "The custom origin name must differ from the domain name."
fi

# --- SAFETY CHECK 2: CONFIG FILES ---
# The live release must exist: the school's configuration is linked into it, and the web installer
# check below runs ADAM from it. deploy.sh creates it.
if [[ ! -L "$BASE_APP_DIR" || ! -d "$BASE_APP_DIR" ]]; then
    error_exit "'$BASE_APP_DIR' is not a link to a deployed release.\n       Run deploy.sh first."
fi

for existing in "$CONFIGS_DIR/config.$domain.ini" "$BASE_APP_DIR/config.$domain.ini"; do
    if [[ -e "$existing" || -L "$existing" ]]; then
        error_exit "Configuration file '$existing' ALREADY EXISTS.\n       Aborting to prevent overwriting an active site configuration."
    fi
done

# --- SAFETY CHECK 3: APACHE ---
if [[ -f "$APACHE_AVAIL_DIR/$domain.conf" ]]; then
    error_exit "Apache configuration '$APACHE_AVAIL_DIR/$domain.conf' ALREADY EXISTS.\n       Aborting."
fi

echo -e "${GREEN}Safety checks passed. Proceeding with deployment...${NC}"
echo

# 3. Database Strategy
echo
echo "--- Database Configuration ---"
echo "Is the MySQL server running on THIS server (Local) or a remote server?"
read -p "Type 'local' or 'remote': " db_type

db_pass=$(generate_password)
db_name="adam_$school"
db_user="adam_$school"

if [[ "$db_type" == "remote" ]]; then
    # --- REMOTE PATH ---
    read -p "Enter Remote DB Hostname/IP: " db_host
    
    detected_ip=$(hostname -I | awk '{print $1}')
    read -p "Enter THIS Web Server's IP (for DB whitelist) [$detected_ip]: " web_server_ip
    web_server_ip=${web_server_ip:-$detected_ip}

    clear
    echo "================================================================="
    echo -e "${YELLOW} ACTION REQUIRED: REMOTE DATABASE SETUP ${NC}"
    echo "================================================================="
    echo "Run the following SQL on the REMOTE Database Server:"
    echo "-----------------------------------------------------------------"
    echo "CREATE DATABASE IF NOT EXISTS \`$db_name\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    echo "CREATE USER IF NOT EXISTS '$db_user'@'$web_server_ip' IDENTIFIED BY '$db_pass';"
    echo "ALTER USER '$db_user'@'$web_server_ip' IDENTIFIED BY '$db_pass';"
    echo "GRANT ALL ON \`$db_name\`.* TO '$db_user'@'$web_server_ip';"
    echo "FLUSH PRIVILEGES;"
    echo "-----------------------------------------------------------------"
    
    while true; do
        read -p "Press [Enter] once you have run these commands to verify connection..."
        echo "Testing connection to $db_host..."
        
        if test_mysql_connection "$db_host" "$db_user" "$db_pass" "$db_name"; then
            echo -e "${GREEN}SUCCESS: Connection verified!${NC}"
            log "Remote database connection verified."
            break
        else
            echo -e "${RED}ERROR: Could not connect.${NC}"
            echo " 1. Did you run the SQL commands?"
            echo " 2. Is firewalld allowing port 3306 from $web_server_ip?"
        fi
    done

else
    # --- LOCAL PATH ---
    db_host="127.0.0.1"
    echo -n "Enter Local DB Root Password (leave blank if none): "
    read -s db_admin_pass
    echo

    log "Creating local database..."
    
    SQL_COMMANDS="
    CREATE DATABASE IF NOT EXISTS \`$db_name\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS '$db_user'@'localhost' IDENTIFIED BY '$db_pass';
    ALTER USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';
    GRANT ALL ON \`$db_name\`.* TO '$db_user'@'localhost';
    FLUSH PRIVILEGES;
    "

    if [[ -n "$db_admin_pass" ]]; then
        MYSQL_PWD="$db_admin_pass" mysql -u root -e "$SQL_COMMANDS"
    else
        mysql -u root -e "$SQL_COMMANDS"
    fi
    log "Local database created."
fi

# --- Step 4: File System Setup ---
log "Creating directory structure..."
mkdir -p "$BASE_WEB_DIR/adam/$school/"{pictures,backup,docrep}
mkdir -p "$BASE_WEB_DIR/temp/$school"

log "Setting permissions..."
chown -R www-data:www-data "$BASE_WEB_DIR/adam/$school"
chown -R www-data:www-data "$BASE_WEB_DIR/temp/$school"
chmod -R 750 "$BASE_WEB_DIR/adam/$school" 

# --- Step 5: Application Configuration ---
log "Generating config.ini..."
temp_config=$(mktemp)

cat << EOF > "$temp_config"
[database]
db_host = $db_host
db_name = $db_name
db_user = $db_user
db_pass = "$db_pass"

[configuration]
installdir = $BASE_APP_DIR/
url = https://$domain/

[settings]
settings [ dir_temp ] = $BASE_WEB_DIR/temp/$school/
settings [ cron_backup_location ] = $BASE_WEB_DIR/adam/$school/backup/
settings [ external_url ] = https://$domain/
settings [ docrep_location ] = $BASE_WEB_DIR/adam/$school/docrep/
settings [ 3party_wkhtmltopdf ] = /usr/local/bin/wkhtmltopdf.sh
settings [ 3party_wkhtmltopdf_arg ] = --zoom 1.25
EOF

config_file="$CONFIGS_DIR/config.$domain.ini"

# The shared folder is normally created by deploy.sh. Create it the same way if it is missing:
# owned by the deploy user (the owner of the releases folder), readable by www-data, and setgid so
# the files in it keep the www-data group.
if [[ ! -d "$CONFIGS_DIR" ]]; then
    log "Creating $CONFIGS_DIR..."
    mkdir -p "$CONFIGS_DIR"
    chown "$(stat -c %U "$APP_BASE_DIR/releases"):www-data" "$CONFIGS_DIR"
    chmod 2750 "$CONFIGS_DIR"
fi

# Hold the deployment lock while the file and its link are created, so a deployment that is
# building a release cannot miss this school. The lock is only taken if deploy.sh has created it:
# opened for reading, it is never created here (a root-owned lock file would stop deploy.sh).
lock_held=false
if [[ -f "$DEPLOY_MUTEX" ]]; then
    exec 9<"$DEPLOY_MUTEX"
    log "Waiting for any running deployment to finish..."
    if flock -w 900 9; then
        lock_held=true
    else
        echo -e "${YELLOW}Warning: a deployment is still running after 15 minutes. Continuing without the lock.${NC}"
        log "Deployment lock not acquired; continuing."
    fi
fi

# Move config safely
mv "$temp_config" "$config_file"

# Set Owner to the actual User ($SUDO_USER), but Group to www-data.
# This ensures the user can edit it, and Apache can read it (via group permissions).
chown "${REAL_USER}:www-data" "$config_file"
chmod 644 "$config_file"

# Link it into the live release. Later releases get their link from deploy.sh.
ln -s "$config_file" "$BASE_APP_DIR/config.$domain.ini"
log "Configuration written to $config_file and linked into $BASE_APP_DIR."

if [[ "$lock_held" == true ]]; then
    flock -u 9
fi
exec 9<&-

# --- Step 6: Apache Configuration ---
log "Configuring Apache..."
apache_conf="$APACHE_AVAIL_DIR/$domain.conf"

# Certbot copies this alias into the HTTPS site it creates.
server_alias_line=""
if [[ -n "$origin_name" ]]; then
    server_alias_line="ServerAlias $origin_name"
fi

cat << EOF > "$apache_conf"
<VirtualHost *:80>
    ServerName $domain
    $server_alias_line
    DocumentRoot "$BASE_APP_DIR"
    <Directory "$BASE_APP_DIR">
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/$domain-error.log
    CustomLog \${APACHE_LOG_DIR}/$domain-access.log combined
</VirtualHost>
EOF

if ! a2ensite "$domain.conf" > /dev/null; then
    log "Warning: a2ensite issue. Please check manually."
fi

if apache2ctl configtest; then
    service apache2 reload
    log "Apache reloaded."
else
    log "CRITICAL: Apache config bad. Not reloading."
    exit 1
fi

# --- Step 7: Certbot ---
certbot_domains=(-d "$domain")
if [[ -n "$origin_name" ]]; then
    certbot_domains+=(-d "$origin_name")

    echo
    echo "================================================================="
    echo -e "${YELLOW} ACTION REQUIRED: CLOUDFLARE, BEFORE THE CERTIFICATE ${NC}"
    echo "================================================================="
    echo "Let's Encrypt checks '$origin_name' through Cloudflare. While this server has"
    echo "no certificate for it, Cloudflare answers that check with error 526."
    echo
    echo "In the adam.co.za zone, add a temporary Configuration Rule:"
    echo "    When: http.host eq \"$origin_name\""
    echo "    Then: SSL = Full"
    echo "Delete the rule once this script has finished."
    echo "-----------------------------------------------------------------"
    read -p "Press [Enter] once the rule is in place..."
fi

log "Running Certbot..."
certbot --apache --cert-name "$domain" "${certbot_domains[@]}"

# --- Step 8: Web installer, then cron ---
# Cron must not start until the database is installed and fully migrated. Against an empty
# database it fails every minute; against a half-installed one (the web installer takes minutes)
# every job reports missing tables to BugSnag. The school's details are captured by the web
# installer, so cron waits for that too.
cron_entry="* * * * * php $BASE_APP_DIR/cron.php --config=$domain > /dev/null 2>&1"

install_cron() {
    log "Updating Crontab..."
    local current_cron new_cron
    current_cron=$(crontab -l -u www-data 2>/dev/null || true)
    new_cron=$(echo "$current_cron" | grep -v -e "--config=$domain" || true)

    echo "$new_cron
$cron_entry" | crontab -u www-data -
    log "Cron installed for $domain."
}

# Run as www-data: ADAM writes caches into the school's temp directory, and files created
# there by root would be unwritable for the web server afterwards.
schema_is_current() {
    sudo -u www-data php "$BASE_APP_DIR/adam" schema:status "--config=$domain" 2>/dev/null \
        | grep -q "Schema is up to date"
}

echo
echo "================================================================="
echo -e "${YELLOW} ACTION REQUIRED: COMPLETE THE WEB INSTALLER ${NC}"
echo "================================================================="
echo "Open https://$domain/ and complete the installation form."
echo "Cron is installed only once the database is installed and up to date."
echo "-----------------------------------------------------------------"

while true; do
    read -p "Press [Enter] once the installer has finished, or type 'skip' to install cron later: " installer_answer

    if [[ "$installer_answer" == "skip" ]]; then
        echo -e "${YELLOW}Cron NOT installed. Once the web installer has finished, add this line to${NC}"
        echo -e "${YELLOW}www-data's crontab (sudo crontab -u www-data -e):${NC}"
        echo "    $cron_entry"
        log "Cron skipped for $domain."
        break
    fi

    if schema_is_current; then
        install_cron
        break
    fi

    echo -e "${RED}The database is not installed, or migrations are still pending.${NC}"
    echo " 1. Has the installation form been submitted, and has it finished loading?"
    echo " 2. Check: sudo -u www-data php $BASE_APP_DIR/adam schema:status --config=$domain"
done

echo
echo -e "${GREEN}=================================================="
echo "   DEPLOYMENT COMPLETE for $school"
echo "==================================================${NC}"
