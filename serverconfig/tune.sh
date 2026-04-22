#!/bin/bash
#
# LAMP Stack Tuning Automator (Stability Edition)
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

MODE=${1:-report} # Default to 'report' mode

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

# Enforce a 60MB minimum safety floor for calculations
if [ "$CALCULATED_PHP_AVG" -lt "60" ]; then
    AVG_PHP_PROCESS_MB=60
else
    AVG_PHP_PROCESS_MB=$CALCULATED_PHP_AVG
fi

# --- Database Location Detection ---
CONFIG_DIR="/var/www/adam/live"
USE_LOCAL_DB=true
DETECTION_MSG="Default (Local DB)"

if [ -d "$CONFIG_DIR" ]; then
    if grep -r "db_host" "$CONFIG_DIR"/config.*.ini &>/dev/null; then
        if grep -rE "db_host.*=.*(localhost|127\.0\.0\.1)" "$CONFIG_DIR"/config.*.ini &>/dev/null; then
            USE_LOCAL_DB=true
            DETECTION_MSG="Detected Local DB (found localhost in config)"
        else
            USE_LOCAL_DB=false
            DETECTION_MSG="Detected Remote DB (no localhost in config)"
        fi
    fi
fi

# --- Calculations (STABILITY TUNED) ---

if [ "$USE_LOCAL_DB" = true ]; then
    # Logic: If RAM < 8GB, be conservative (30% MySQL). If > 8GB, be aggressive (50%).
    IS_LOW_RAM=$(echo "$TOTAL_RAM_GB < 8" | bc)
    
    if [ "$IS_LOW_RAM" -eq 1 ]; then
        MYSQL_ALLOC_PCT=0.30
        PHP_ALLOC_PCT=0.35
    else
        MYSQL_ALLOC_PCT=0.50
        PHP_ALLOC_PCT=0.40
    fi
    
    # Initial calculation based on percentage
    RAW_MYSQL_MB=$(echo "$TOTAL_RAM_MB * $MYSQL_ALLOC_PCT" | bc | cut -d. -f1)

    # NEW LOGIC: Floor to nearest 1GB if over 1GB to prevent MySQL "Rounding Up" to 2GB
    if [ "$RAW_MYSQL_MB" -gt 1024 ]; then
        GIGS=$(echo "$RAW_MYSQL_MB / 1024" | bc)
        MYSQL_BUFFER_POOL_MB=$(echo "$GIGS * 1024" | bc)
    else
        MYSQL_BUFFER_POOL_MB=$RAW_MYSQL_MB
    fi
else
    # Remote DB
    MYSQL_ALLOC_PCT=0.00
    PHP_ALLOC_PCT=0.80
    MYSQL_BUFFER_POOL_MB=128
fi

MYSQL_LOG_FILE_MB=512
# UPDATED: Lowered from 100 to 60 to prevent OOM
MYSQL_MAX_CONN=60 
MYSQL_TABLE_CACHE=400
MYSQL_DEF_CACHE=400
MYSQL_SORT_BUFFER="1M"
MYSQL_JOIN_BUFFER="1M"

# PHP Calculation
RAM_FOR_PHP_MB=$(echo "$TOTAL_RAM_MB * $PHP_ALLOC_PCT" | bc | cut -d. -f1)
PHP_MAX_CHILDREN=$(echo "$RAM_FOR_PHP_MB / $AVG_PHP_PROCESS_MB" | bc)

# Sanity checks for PHP
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
# UPDATED: Lowered to 100 to match MySQL Connection Limit closer
APACHE_MAX_WORKERS=100
APACHE_THREADS_CHILD=25
APACHE_MAX_CONN_CHILD=1000

# --- File Path Detection ---
PHP_FPM_SERVICE=$(systemctl list-units --type=service --state=running *php*fpm*.service | grep -o 'php[0-9]\.[0-9]-fpm\.service' | sort -V | tail -n 1)

if [[ -n "$PHP_FPM_SERVICE" ]]; then
    PHP_VER=$(echo "$PHP_FPM_SERVICE" | sed -e 's/php//' -e 's/-fpm.service//')
    PHP_POOL_FILE="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
    PHP_INI_FILE="/etc/php/${PHP_VER}/fpm/php.ini"
    PHP_RESTART_CMD="systemctl restart php${PHP_VER}-fpm"
else
    PHP_VER="DETECT_FAILED"
fi

APACHE_MPM_FILE="/etc/apache2/mods-available/mpm_event.conf"
MYSQL_OVERRIDE_FILE="/etc/mysql/conf.d/z-tuning-script.cnf"

# ==============================================================================
# 2. SWAP CHECK FUNCTION
# ==============================================================================
ensure_swap() {
    SWAP_SIZE=$(free -m | grep Swap | awk '{print $2}')
    if [ "$SWAP_SIZE" -eq "0" ]; then
        echo -e "${YELLOW}Warning: No Swap Detected!${NC}"
        echo -n "Creating 4GB Swap file (The Airbag)... "
        fallocate -l 4G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile &>/dev/null
        swapon /swapfile
        
        # Add to fstab if not present
        if ! grep -q "/swapfile" /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        echo -e "${GREEN}Done${NC}"
    else
        echo -e "Swap Status: ${GREEN}OK${NC} (${SWAP_SIZE}MB detected)"
    fi
}

# ==============================================================================
# 3. REPORT MODE
# ==============================================================================
# Helpers
get_ini_val() { [ -f "$2" ] && grep "^$1" "$2" | cut -d= -f2 | tr -d ' ;M' || echo "Default"; }
get_apache_val() { [ -f "$2" ] && grep "$1" "$2" | awk '{print $2}' || echo "Default"; }

if [ "$MODE" == "report" ]; then
    # Current Values
    if [ -f "$MYSQL_OVERRIDE_FILE" ]; then
        CUR_MYSQL_BUF=$(get_ini_val "innodb_buffer_pool_size" "$MYSQL_OVERRIDE_FILE")
    else
        CUR_MYSQL_BUF="Default"
    fi
    CUR_PHP_CHILDREN=$(get_ini_val "pm.max_children" "$PHP_POOL_FILE")
    CUR_APACHE_WORKERS=$(get_apache_val "MaxRequestWorkers" "$APACHE_MPM_FILE")

    echo -e "${CYAN}--- LAMP Stack Tuning Report (Stability Edition) ---${NC}"
    echo -e "Resources: ${YELLOW}${TOTAL_RAM_GB}GB RAM${NC} | ${YELLOW}${TOTAL_CPUS} CPU Cores${NC}"
    
    # Swap Check for Report
    SWAP_CHECK=$(free -m | grep Swap | awk '{print $2}')
    if [ "$SWAP_CHECK" -eq "0" ]; then
        echo -e "Swap:      ${RED}MISSING (Danger!)${NC} - Run 'apply' to fix."
    else
        echo -e "Swap:      ${GREEN}OK${NC} (${SWAP_CHECK}MB)"
    fi

    echo ""
    echo -e "${GREEN}Proposed Changes for Stability:${NC}"

    echo -e "  [MySQL]  innodb_buffer_pool_size : ${YELLOW}${CUR_MYSQL_BUF}M${NC} -> ${GREEN}${MYSQL_BUFFER_POOL_MB}M${NC} (30% RAM)"
    echo -e "  [MySQL]  max_connections         : ${YELLOW}Unknown${NC} -> ${GREEN}${MYSQL_MAX_CONN}${NC}"
    echo -e "  [PHP]    pm.max_children         : ${YELLOW}${CUR_PHP_CHILDREN}${NC} -> ${GREEN}${PHP_MAX_CHILDREN}${NC}"
    echo -e "  [Apache] MaxRequestWorkers       : ${YELLOW}${CUR_APACHE_WORKERS}${NC} -> ${GREEN}${APACHE_MAX_WORKERS}${NC}"

    echo ""
    echo -e "To apply these changes, run: ${YELLOW}sudo ./tune.sh apply${NC}"
    exit 0
fi

# ==============================================================================
# 4. APPLY MODE
# ==============================================================================
if [ "$MODE" == "apply" ]; then
    echo -e "${CYAN}--- Applying Configuration Changes (v2 Surgical) ---${NC}"
    
    # 1. Swap (The Airbag)
    # Note: On some OpenVZ hosts, swapon will fail. The script handles this gracefully.
    ensure_swap

    # 2. MySQL (REVISED FOR OPENVZ STABILITY)
    echo -n "Configuring MySQL... "
    cat > "$MYSQL_OVERRIDE_FILE" <<EOF
[mysqld]
# Tuning Script - Stability Optimized (OpenVZ Fix)
innodb_buffer_pool_size = ${MYSQL_BUFFER_POOL_MB}M
innodb_log_file_size = ${MYSQL_LOG_FILE_MB}M
max_connections = ${MYSQL_MAX_CONN}

# FIX: Disable Performance Schema to save ~1GB of pre-allocated RAM
performance_schema = OFF

# FIX: Lower table caches to prevent 'sp_head' and file handle bloat
table_open_cache = ${MYSQL_TABLE_CACHE}
table_definition_cache = ${MYSQL_DEF_CACHE}

# FIX: Aggressive per-thread limits
sort_buffer_size = ${MYSQL_SORT_BUFFER}
join_buffer_size = ${MYSQL_JOIN_BUFFER}
binlog_cache_size = 32K
EOF
    echo -e "${GREEN}Done${NC}"

    # 3. PHP-FPM
    echo -n "Configuring PHP-FPM... "
    if [ -f "$PHP_POOL_FILE" ]; then
        [ ! -f "${PHP_POOL_FILE}.original.bak" ] && cp "$PHP_POOL_FILE" "${PHP_POOL_FILE}.original.bak"
        
        sed -i "s/^pm.max_children.*/pm.max_children = ${PHP_MAX_CHILDREN}/" "$PHP_POOL_FILE"
        sed -i "s/^pm.start_servers.*/pm.start_servers = ${PHP_START_SERVERS}/" "$PHP_POOL_FILE"
        sed -i "s/^pm.min_spare_servers.*/pm.min_spare_servers = ${PHP_MIN_SPARE}/" "$PHP_POOL_FILE"
        sed -i "s/^pm.max_spare_servers.*/pm.max_spare_servers = ${PHP_MAX_SPARE}/" "$PHP_POOL_FILE"
        sed -i "s/^pm =.*/pm = dynamic/" "$PHP_POOL_FILE"
        
        # OPCache
        [ ! -f "${PHP_INI_FILE}.original.bak" ] && cp "$PHP_INI_FILE" "${PHP_INI_FILE}.original.bak"
        sed -i "s/^;opcache.enable=.*/opcache.enable=1/" "$PHP_INI_FILE"
        sed -i "s/^opcache.enable=.*/opcache.enable=1/" "$PHP_INI_FILE"
        sed -i "s/^opcache.memory_consumption=.*/opcache.memory_consumption=${PHP_OPCACHE_MEM}/" "$PHP_INI_FILE"
        
        echo -e "${GREEN}Done${NC}"
    else
        echo -e "${RED}Failed${NC} (File not found)"
    fi

    # 4. Apache
    echo -n "Ensuring Apache is using mpm_event... "
    a2dismod mpm_prefork &>/dev/null
    a2enmod mpm_event &>/dev/null
    
    if [ -f "$APACHE_MPM_FILE" ]; then
        [ ! -f "${APACHE_MPM_FILE}.original.bak" ] && cp "$APACHE_MPM_FILE" "${APACHE_MPM_FILE}.original.bak"

        sed -i "s/StartServers.*/StartServers             3/" "$APACHE_MPM_FILE"
        sed -i "s/MinSpareThreads.*/MinSpareThreads          25/" "$APACHE_MPM_FILE"
        sed -i "s/MaxSpareThreads.*/MaxSpareThreads          75/" "$APACHE_MPM_FILE"
        sed -i "s/ThreadsPerChild.*/ThreadsPerChild          ${APACHE_THREADS_CHILD}/" "$APACHE_MPM_FILE"
        sed -i "s/MaxRequestWorkers.*/MaxRequestWorkers       ${APACHE_MAX_WORKERS}/" "$APACHE_MPM_FILE"
        # Added ListenBacklog to fix the "Connection Timeout" queue issue
        if ! grep -q "ListenBacklog" "$APACHE_MPM_FILE"; then
            echo "ListenBacklog 511" >> "$APACHE_MPM_FILE"
        fi
        echo -e "${GREEN}Done${NC}"
    fi

    # 5. Restart Services
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
# 5. REVERT MODE
# ==============================================================================
if [ "$MODE" == "revert" ]; then
    echo -e "${CYAN}--- Reverting Configuration ---${NC}"
    
    [ -f "$MYSQL_OVERRIDE_FILE" ] && rm "$MYSQL_OVERRIDE_FILE"
    
    if [ -f "${PHP_POOL_FILE}.original.bak" ]; then
        cp "${PHP_POOL_FILE}.original.bak" "$PHP_POOL_FILE"
    fi
    if [ -f "${PHP_INI_FILE}.original.bak" ]; then
        cp "${PHP_INI_FILE}.original.bak" "$PHP_INI_FILE"
    fi
    if [ -f "${APACHE_MPM_FILE}.original.bak" ]; then
        cp "${APACHE_MPM_FILE}.original.bak" "$APACHE_MPM_FILE"
    fi

    echo -e "${YELLOW}Restarting Services...${NC}"
    systemctl restart mysql
    $PHP_RESTART_CMD
    systemctl restart apache2
    echo -e "${GREEN}Revert Complete!${NC}"
    exit 0
fi
