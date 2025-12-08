#!/bin/bash
set -e  # Exit immediately if a command exits with a non-zero status.
set -u  # Treat unset variables as an error.
set -o pipefail # Return value of a pipeline is the status of the last command to exit with a non-zero status.

# --- Configuration & Constants ---
BASE_WEB_DIR="/var/webdata"
BASE_APP_DIR="/var/www/adam/live"
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
    openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16
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
echo "   ADAM Setup Script: Safe & Robust Edition       "
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

# --- SAFETY CHECK 2: CONFIG FILES ---
if [[ -f "$BASE_APP_DIR/config.$domain.ini" ]]; then
    error_exit "Configuration file '$BASE_APP_DIR/config.$domain.ini' ALREADY EXISTS.\n       Aborting to prevent overwriting an active site configuration."
fi

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
    # --- REMOTE PATH (MANUAL) ---
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
        sudo mysql -u root -e "$SQL_COMMANDS"
    fi
    log "Local database created."
fi

# --- Step 4: File System Setup ---
log "Creating directory structure..."
# We already checked that the parent $school folder doesn't exist, so this is safe.
mkdir -p "$BASE_WEB_DIR/adam/$school/"{pictures,backup,docrep,export/clever,export/google}
mkdir -p "$BASE_WEB_DIR/temp/$school/updates"
mkdir -p "$BASE_APP_DIR"

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
db_pass = $db_pass

[configuration]
installdir = $BASE_APP_DIR/
url = https://$domain/

[settings]
settings [ dir_pic ] = $BASE_WEB_DIR/adam/$school/pictures/
settings [ dir_temp ] = $BASE_WEB_DIR/temp/$school/
settings [ dir_update ] = $BASE_WEB_DIR/temp/$school/updates/
settings [ gappssync_export_dir ] = $BASE_WEB_DIR/adam/$school/export/google/
settings [ cleversync_export_dir ] = $BASE_WEB_DIR/adam/$school/export/clever/
settings [ cron_backup_location ] = $BASE_WEB_DIR/adam/$school/backup/
settings [ external_url ] = https://$domain/
settings [ docrep_location ] = $BASE_WEB_DIR/adam/$school/docrep/
settings [ 3party_wkhtmltopdf ] = /usr/local/bin/wkhtmltopdf.sh
settings [ 3party_wkhtmltopdf_arg ] = --zoom 0.9877
EOF

# Move config safely
sudo mv "$temp_config" "$BASE_APP_DIR/config.$domain.ini"
sudo chown www-data:www-data "$BASE_APP_DIR/config.$domain.ini"
sudo chmod 640 "$BASE_APP_DIR/config.$domain.ini"

# --- Step 6: Cron Job Setup ---
log "Updating Crontab..."
current_cron=$(crontab -l -u www-data 2>/dev/null || true)
new_cron=$(echo "$current_cron" | grep -v "--config=$domain")
new_cron_entry="* * * * * php $BASE_APP_DIR/cron.php --config=$domain > /dev/null 2>&1"

echo "$new_cron
$new_cron_entry" | crontab -u www-data -

# --- Step 7: Apache Configuration ---
log "Configuring Apache..."
apache_conf="$APACHE_AVAIL_DIR/$domain.conf"

cat << EOF > "$apache_conf"
<VirtualHost *:80>
    ServerName $domain
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

# --- Step 8: Certbot ---
log "Running Certbot..."
certbot --apache -d "$domain"

echo
echo -e "${GREEN}=================================================="
echo "   DEPLOYMENT COMPLETE for $school"
echo "==================================================${NC}"
