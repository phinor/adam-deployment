#!/bin/bash
#
# LAMP Stack Tuning Automator (Ubuntu Optimized)
#
# Usage:
#   ./tune.sh report   (Default: Just calculates and shows values)
#   ./tune.sh apply    (Applies changes, backups configs, restarts services)
#   ./tune.sh revert   (Restores original configs, restarts services)
#

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# --- Check Requirements ---
if ! command -v bc &> /dev/null; then
    echo "Error: 'bc' is required. Run: sudo apt install bc"
    exit 1
fi

MODE=${1:-report} # Default to 'report' mode if no argument given

if [[ "$MODE" == "apply" || "$MODE" == "revert" ]]; then
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: You must run 'apply' or 'revert' as root (sudo).${NC}"
        exit 1
    fi
fi

# ==============================================================================
# 1. RESOURCE DETECTION & CALCULATION
# ==============================================================================

# Get Resources
TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print $2}' | xargs -I {} echo "scale=0; {} / 1024" | bc)
TOTAL_RAM_GB=$(echo "scale=1; $TOTAL_RAM_MB / 1024" | bc)
TOTAL_CPUS=$(nproc)

# Detect PHP Memory Usage
CALCULATED_PHP_AVG=$(ps -eo rss,cmd | grep "[p]hp-fpm" | awk '{sum+=$1} END {if (NR>0) print int(sum/NR/1024); else print 0}')

# Enforce a 60MB minimum, otherwise use the calculated average
if [ "$CALCULATED_PHP_AVG" -lt "60" ]; then
    AVG_PHP_PROCESS_MB=60
else
    AVG_PHP_PROCESS_MB=$CALCULATED_PHP_AVG
fi

# --- Database Location Detection ---
# Check /var/www/adam/live/config.*.ini for db_host
CONFIG_DIR="/var/www/adam/live"
USE_LOCAL_DB=true # Default to true for safety
DETECTION_MSG="Default (Local DB)"

if [ -d "$CONFIG_DIR" ]; then
    # Check if there are any config files with db_host
    if grep -r "db_host" "$CONFIG_DIR"/config.*.ini &>/dev/null; then
        # Check if ANY config file points to localhost or 127.0.0.1
        if grep -rE "db_host.*=.*(localhost|127\.0\.0\.1)" "$CONFIG_DIR"/config.*.ini &>/dev/null; then
            USE_LOCAL_DB=true
            DETECTION_MSG="Detected Local DB (found localhost in config)"
        else
            USE_LOCAL_DB=false
            DETECTION_MSG="Detected Remote DB (no localhost in config)"
        fi
    fi
fi

# --- Calculations ---

if [ "$USE_LOCAL_DB" = true ]; then
    # Standard Split: 40% MySQL / 40% PHP
    MYSQL_ALLOC_PCT=0.40
    PHP_ALLOC_PCT=0.40
    MYSQL_BUFFER_POOL_MB=$(echo "$TOTAL_RAM_MB * $MYSQL_ALLOC_PCT" | bc | cut -d. -f1)
else
    # Remote DB Split: 0% MySQL (Minimal) / 80% PHP
    MYSQL_ALLOC_PCT=0.00
    PHP_ALLOC_PCT=0.80
    # Set MySQL to minimal 128MB safety floor if installed but unused
    MYSQL_BUFFER_POOL_MB=128
fi

MYSQL_LOG_FILE_MB=512
MYSQL_MAX_CONN=100

# PHP Calculation
RAM_FOR_PHP_MB=$(echo "$TOTAL_RAM_MB * $PHP_ALLOC_PCT" | bc | cut -d. -f1)
PHP_MAX_CHILDREN=$(echo "$RAM_FOR_PHP_MB / $AVG_PHP_PROCESS_MB" | bc)
[ "$PHP_MAX_CHILDREN" -lt "5" ] && PHP_MAX_CHILDREN=5

PHP_START_SERVERS=$(echo "$PHP_MAX_CHILDREN / 4" | bc)
PHP_MIN_SPARE=$(echo "$PHP_MAX_CHILDREN / 8" | bc)
PHP_MAX_SPARE=$(echo "($PHP_MAX_CHILDREN / 3) + 1" | bc)
[ "$PHP_START_SERVERS" -lt "2" ] && PHP_START_SERVERS=2
[ "$PHP_MIN_SPARE" -lt "1" ] && PHP_MIN_SPARE=1
[ "$PHP_MAX_SPARE" -lt "2" ] && PHP_MAX_SPARE=2

PHP_MEMORY_LIMIT="256M"
PHP_OPCACHE_MEM=256

# Apache
APACHE_MAX_WORKERS=150
APACHE_THREADS_CHILD=25
APACHE_MAX_CONN_CHILD=1000

# --- File Path Detection (Ubuntu Specific) ---
PHP_FPM_SERVICE=$(systemctl list-units --type=service --state=running *php*fpm*.service | grep -o 'php[0-9]\.[0-9]-fpm\.service' | sort -V | tail -n 1)

if [[ -n "$PHP_FPM_SERVICE" ]]; then
    PHP_VER=$(echo "$PHP_FPM_SERVICE" | sed -e 's/php//' -e 's/-fpm.service//')
    PHP_POOL_FILE="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
    PHP_INI_FILE="/etc/php/${PHP_VER}/fpm/php.ini"
    PHP_RESTART_CMD="systemctl restart php${PHP_VER}-fpm"
else
    # Fallback/Error if PHP not found, but we proceed for report mode
    PHP_VER="DETECT_FAILED"
fi

APACHE_MPM_FILE="/etc/apache2/mods-available/mpm_event.conf"
MYSQL_OVERRIDE_FILE="/etc/mysql/conf.d/z-tuning-script.cnf"

# ==============================================================================
# 2. REPORT MODE
# ==============================================================================
if [ "$MODE" == "report" ]; then
    echo -e "${CYAN}--- LAMP Stack Tuning Report (Dry Run) ---${NC}"
    echo -e "Resources: ${YELLOW}${TOTAL_RAM_GB}GB RAM${NC} | ${YELLOW}${TOTAL_CPUS} CPU Cores${NC}"
    echo -e "PHP Avg Process: ${YELLOW}${AVG_PHP_PROCESS_MB} MB${NC} (Minimum enforced: 60MB)"
    echo -e "DB Mode: ${YELLOW}${DETECTION_MSG}${NC}"
    echo ""
    echo -e "${GREEN}Proposed Settings:${NC}"
    if [ "$USE_LOCAL_DB" = true ]; then
        echo -e "  [MySQL]  innodb_buffer_pool_size = ${MYSQL_BUFFER_POOL_MB}M (40% Allocation)"
    else
        echo -e "  [MySQL]  innodb_buffer_pool_size = ${MYSQL_BUFFER_POOL_MB}M (Minimal Safety Floor)"
    fi
    echo -e "  [MySQL]  innodb_log_file_size    = ${MYSQL_LOG_FILE_MB}M"
    echo -e "  [PHP]    pm.max_children         = ${PHP_MAX_CHILDREN} ($(echo "$PHP_ALLOC_PCT * 100" | bc | cut -d. -f1)% Allocation)"
    echo -e "  [Apache] MaxRequestWorkers       = ${APACHE_MAX_WORKERS}"
    echo ""
    echo -e "To apply these changes, run: ${YELLOW}sudo ./tune.sh apply${NC}"
    exit 0
fi

# ==============================================================================
# 3. APPLY MODE
# ==============================================================================
if [ "$MODE" == "apply" ]; then
    echo -e "${CYAN}--- Applying Configuration Changes ---${NC}"
    echo -e "Mode: ${YELLOW}${DETECTION_MSG}${NC}"

    # --- 1. MySQL ---
    echo -n "Configuring MySQL... "
    cat > "$MYSQL_OVERRIDE_FILE" <<EOF
[mysqld]
# Auto-generated by tune.sh
innodb_buffer_pool_size = ${MYSQL_BUFFER_POOL_MB}M
innodb_log_file_size = ${MYSQL_LOG_FILE_MB}M
max_connections = ${MYSQL_MAX_CONN}
EOF
    echo -e "${GREEN}Done${NC} (Created $MYSQL_OVERRIDE_FILE)"

    # --- 2. PHP-FPM ---
    echo -n "Configuring PHP-FPM... "
    if [ -f "$PHP_POOL_FILE" ]; then
        # Backup only if original backup doesn't exist
        if [ ! -f "${PHP_POOL_FILE}.original.bak" ]; then
            cp "$PHP_POOL_FILE" "${PHP_POOL_FILE}.original.bak"
        fi

        # Use sed to replace lines. We use a temporary file to avoid partial writes.
        # We look for the directive at the start of the line (ignoring whitespace)
        # Note: This regex assumes standard config format.
        sed -i "s/^pm.max_children.*/pm.max_children = ${PHP_MAX_CHILDREN}/" "$PHP_POOL_FILE"
        sed -i "s/^pm.start_servers.*/pm.start_servers = ${PHP_START_SERVERS}/" "$PHP_POOL_FILE"
        sed -i "s/^pm.min_spare_servers.*/pm.min_spare_servers = ${PHP_MIN_SPARE}/" "$PHP_POOL_FILE"
        sed -i "s/^pm.max_spare_servers.*/pm.max_spare_servers = ${PHP_MAX_SPARE}/" "$PHP_POOL_FILE"
        # Ensure mode is dynamic
        sed -i "s/^pm =.*/pm = dynamic/" "$PHP_POOL_FILE"

        # PHP INI (OPCache)
        if [ ! -f "${PHP_INI_FILE}.original.bak" ]; then
            cp "$PHP_INI_FILE" "${PHP_INI_FILE}.original.bak"
        fi
        sed -i "s/^;opcache.enable=.*/opcache.enable=1/" "$PHP_INI_FILE"
        sed -i "s/^opcache.enable=.*/opcache.enable=1/" "$PHP_INI_FILE"
        sed -i "s/^;opcache.memory_consumption=.*/opcache.memory_consumption=${PHP_OPCACHE_MEM}/" "$PHP_INI_FILE"
        sed -i "s/^opcache.memory_consumption=.*/opcache.memory_consumption=${PHP_OPCACHE_MEM}/" "$PHP_INI_FILE"

        echo -e "${GREEN}Done${NC}"
    else
        echo -e "${RED}Failed${NC} (File $PHP_POOL_FILE not found)"
    fi

    # --- 3. Apache ---
    echo -n "Configuring Apache... "
    if [ -f "$APACHE_MPM_FILE" ]; then
        if [ ! -f "${APACHE_MPM_FILE}.original.bak" ]; then
            cp "$APACHE_MPM_FILE" "${APACHE_MPM_FILE}.original.bak"
        fi

        sed -i "s/StartServers.*/StartServers             3/" "$APACHE_MPM_FILE"
        sed -i "s/MinSpareThreads.*/MinSpareThreads          25/" "$APACHE_MPM_FILE"
        sed -i "s/MaxSpareThreads.*/MaxSpareThreads          75/" "$APACHE_MPM_FILE"
        sed -i "s/ThreadsPerChild.*/ThreadsPerChild          ${APACHE_THREADS_CHILD}/" "$APACHE_MPM_FILE"
        sed -i "s/MaxRequestWorkers.*/MaxRequestWorkers      ${APACHE_MAX_WORKERS}/" "$APACHE_MPM_FILE"

        echo -e "${GREEN}Done${NC}"
    else
        echo -e "${RED}Skipped${NC} (Event MPM config not found at $APACHE_MPM_FILE)"
    fi

    # --- 4. Restart Services ---
    echo ""
    echo -e "${YELLOW}Restarting Services...${NC}"
    systemctl restart mysql && echo -e "MySQL: ${GREEN}OK${NC}" || echo -e "MySQL: ${RED}Failed${NC}"
    $PHP_RESTART_CMD && echo -e "PHP-FPM: ${GREEN}OK${NC}" || echo -e "PHP-FPM: ${RED}Failed${NC}"
    systemctl restart apache2 && echo -e "Apache: ${GREEN}OK${NC}" || echo -e "Apache: ${RED}Failed${NC}"

    echo ""
    echo -e "${GREEN}Optimization Complete!${NC}"
    exit 0
fi

# ==============================================================================
# 4. REVERT MODE
# ==============================================================================
if [ "$MODE" == "revert" ]; then
    echo -e "${CYAN}--- Reverting to Original Configuration ---${NC}"

    # Remove MySQL Override
    if [ -f "$MYSQL_OVERRIDE_FILE" ]; then
        rm "$MYSQL_OVERRIDE_FILE"
        echo -e "MySQL Override: ${GREEN}Removed${NC}"
    else
        echo -e "MySQL Override: ${YELLOW}Not found${NC}"
    fi

    # Restore PHP
    if [ -f "${PHP_POOL_FILE}.original.bak" ]; then
        cp "${PHP_POOL_FILE}.original.bak" "$PHP_POOL_FILE"
        echo -e "PHP-FPM Config: ${GREEN}Restored${NC}"
    else
        echo -e "PHP-FPM Backup: ${YELLOW}Not found${NC}"
    fi

    if [ -f "${PHP_INI_FILE}.original.bak" ]; then
        cp "${PHP_INI_FILE}.original.bak" "$PHP_INI_FILE"
        echo -e "PHP INI Config: ${GREEN}Restored${NC}"
    fi

    # Restore Apache
    if [ -f "${APACHE_MPM_FILE}.original.bak" ]; then
        cp "${APACHE_MPM_FILE}.original.bak" "$APACHE_MPM_FILE"
        echo -e "Apache Config:  ${GREEN}Restored${NC}"
    else
        echo -e "Apache Backup:  ${YELLOW}Not found${NC}"
    fi

    # Restart Services
    echo ""
    echo -e "${YELLOW}Restarting Services...${NC}"
    systemctl restart mysql
    $PHP_RESTART_CMD
    systemctl restart apache2

    echo -e "${GREEN}Revert Complete!${NC}"
    exit 0
fi

# Fallback for unknown commands
echo "Usage: ./tune.sh [report|apply|revert]"
exit 1