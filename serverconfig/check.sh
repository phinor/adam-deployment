#!/bin/bash
#
# LAMP Stack Tuning Calculator
#
# This script DETECTS your system's RAM and CPU count and RECOMMENDS
# balanced configuration values for MySQL, PHP-FPM, and Apache (Event MPM).
#
# !! WARNING !!
# This script DOES NOT make any changes. It only prints recommendations.
# You must manually edit the configuration files.
#
# ALWAYS back up your config files before editing!
# e.g., cp /etc/my.cnf /etc/my.cnf.bak
#

# --- Colors for Readability ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Check for required 'bc' command ---
if ! command -v bc &> /dev/null
then
    echo -e "${RED}ERROR: 'bc' command not found.${NC}" >&2
    echo -e "This script requires 'bc' for floating-point calculations." >&2
    echo -e "Please install it to continue:" >&2
    echo -e "  - ${YELLOW}On Debian/Ubuntu:${NC} sudo apt update && sudo apt install bc" >&2
    echo -e "  - ${YELLOW}On RHEL/CentOS/Fedora:${NC} sudo dnf install bc (or yum install bc)" >&2
    exit 1
fi

echo -e "${CYAN}--- LAMP Stack Tuning Calculator ---${NC}"

# --- Step 1: Detect System Resources ---

# Get Total RAM in MB
# We use /proc/meminfo as 'free -m' can be formatted differently
TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print $2}' | xargs -I {} echo "scale=0; {} / 1024" | bc)
TOTAL_RAM_GB=$(echo "scale=1; $TOTAL_RAM_MB / 1024" | bc)

# Get Total CPU Cores
TOTAL_CPUS=$(nproc)

echo -e "${GREEN}Detected System Resources:${NC}"
echo -e "  - ${YELLOW}Total RAM:${NC}   ${TOTAL_RAM_MB} MB (~${TOTAL_RAM_GB} GB)"
echo -e "  - ${YELLOW}Total CPUs:${NC}  ${TOTAL_CPUS} vCPUs"


# --- Step 1.5: Detect Average PHP Process Memory ---
# We calculate the average RSS (Resident Set Size) of currently running php-fpm processes.
# If the server is idle, this might be slightly lower than under load, but it's better than a guess.
CALCULATED_PHP_AVG=$(ps -eo rss,cmd | grep "[p]hp-fpm" | awk '{sum+=$1} END {if (NR>0) print int(sum/NR/1024); else print 0}')

if [ "$CALCULATED_PHP_AVG" -gt "0" ]; then
    AVG_PHP_PROCESS_MB=$CALCULATED_PHP_AVG
    echo -e "  - ${YELLOW}PHP Memory:${NC}  ~${AVG_PHP_PROCESS_MB} MB per process (Calculated from running processes)"
else
    AVG_PHP_PROCESS_MB=50
    echo -e "  - ${YELLOW}PHP Memory:${NC}  Could not detect running PHP processes. Using default: ${AVG_PHP_PROCESS_MB} MB"
fi
echo ""

# --- Step 2: Calculate Tuning Values ---

# We'll use a 40% (MySQL) / 40% (PHP) / 20% (OS/Apache/Other) split as a baseline.
# This is a balanced, safe starting point.

# --- MySQL Calculations ---
# 40% of Total RAM
MYSQL_BUFFER_POOL_MB=$(echo "$TOTAL_RAM_MB * 0.40" | bc | cut -d. -f1)
MYSQL_BUFFER_POOL_G=$(echo "scale=1; $MYSQL_BUFFER_POOL_MB / 1024" | bc)
MYSQL_LOG_FILE_MB=512 # A robust default for 8GB+ RAM
MYSQL_MAX_CONN=100    # Default

# --- PHP-FPM Calculations ---
# 40% of Total RAM for the PHP pool
RAM_FOR_PHP_MB=$(echo "$TOTAL_RAM_MB * 0.40" | bc | cut -d. -f1)

# Use the calculated or default average process size
PHP_MAX_CHILDREN=$(echo "$RAM_FOR_PHP_MB / $AVG_PHP_PROCESS_MB" | bc)

# Ensure max_children is at least a reasonable number
if [ "$PHP_MAX_CHILDREN" -lt "5" ]; then
    PHP_MAX_CHILDREN=5
fi

# Base other pool settings on max_children
PHP_START_SERVERS=$(echo "$PHP_MAX_CHILDREN / 4" | bc)
PHP_MIN_SPARE=$(echo "$PHP_MAX_CHILDREN / 8" | bc)
PHP_MAX_SPARE=$(echo "($PHP_MAX_CHILDREN / 3) + 1" | bc)

# Keep reasonable minimums
if [ "$PHP_START_SERVERS" -lt "2" ]; then PHP_START_SERVERS=2; fi
if [ "$PHP_MIN_SPARE" -lt "1" ]; then PHP_MIN_SPARE=1; fi
if [ "$PHP_MAX_SPARE" -lt "2" ]; then PHP_MAX_SPARE=2; fi


# --- PHP.ini Calculations ---
PHP_MEMORY_LIMIT="256M" # A safe per-script limit
PHP_OPCACHE_MEM=256   # 256MB is generous for OPcache

# --- Apache Calculations ---
# Based more on CPUs and connection handling
APACHE_MAX_WORKERS=150
APACHE_THREADS_CHILD=25
APACHE_MAX_CONN_CHILD=1000 # Good for memory leak protection

# --- Step 2.5: Auto-detect PHP-FPM paths ---

PHP_FPM_SERVICE_NAME=""
PHP_VERSION=""
PHP_FPM_POOL_CONF=""
PHP_INI_PATH=""
PHP_RESTART_CMD=""
PHP_VERSION_DETECTED=false

# Try to find a running php-fpm service
# We sort -V to get the highest version first if multiple are running (e.g., 8.2 > 8.1)
# We grep for Debian/Ubuntu style (phpX.Y-fpm) and RHEL style (php-fpm)
PHP_FPM_SERVICE_NAME=$(systemctl list-units --type=service --state=running *php*fpm*.service | grep -o 'php[0-9]\.[0-9]-fpm\.service\|php-fpm\.service' | sort -V | tail -n 1)

if [[ "$PHP_FPM_SERVICE_NAME" == "php-fpm.service" ]]; then
    # RHEL/CentOS/Fedora style setup
    PHP_VERSION="N/A (RHEL-style)"
    PHP_FPM_POOL_CONF="/etc/php-fpm.d/www.conf"
    PHP_INI_PATH="/etc/php.ini"
    PHP_RESTART_CMD="php-fpm"

elif [[ "$PHP_FPM_SERVICE_NAME" == *"-fpm.service"* ]]; then
    # Debian/Ubuntu style setup, e.g., php8.2-fpm.service
    PHP_VERSION=$(echo "$PHP_FPM_SERVICE_NAME" | sed -e 's/php//' -e 's/-fpm.service//') # Extracts "8.2"
    PHP_FPM_POOL_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
    PHP_INI_PATH="/etc/php/${PHP_VERSION}/fpm/php.ini"
    PHP_RESTART_CMD="php${PHP_VERSION}-fpm"
fi

# --- Fallback if we found nothing or files don't exist ---
if [ -z "$PHP_FPM_SERVICE_NAME" ] || [ ! -f "$PHP_FPM_POOL_CONF" ] || [ ! -f "$PHP_INI_PATH" ]; then
    echo -e "${RED}WARNING: Could not auto-detect running PHP-FPM service or paths.${NC}" >&2
    echo -e "Using placeholders. ${YELLOW}Please find your PHP paths manually.${NC}" >&2
    echo ""
    PHP_VERSION="YOUR_VERSION"
    PHP_FPM_POOL_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
    PHP_INI_PATH="/etc/php/${PHP_VERSION}/fpm/php.ini"
    PHP_RESTART_CMD="php${PHP_VERSION}-fpm"
    PHP_VERSION_DETECTED=false
else
    echo -e "${GREEN}Detected PHP-FPM Version:${NC} ${YELLOW}${PHP_VERSION}${NC} (Service: ${PHP_FPM_SERVICE_NAME})"
    echo -e "  - ${YELLOW}Pool Config:${NC} $PHP_FPM_POOL_CONF"
    echo -e "  - ${YELLOW}INI Config:${NC}  $PHP_INI_PATH"
    echo ""
    PHP_VERSION_DETECTED=true
fi


# --- Step 3: Print The Report ---

echo -e "${GREEN}Recommended Configuration Settings:${NC}"
echo -e "Based on ${YELLOW}${TOTAL_RAM_GB}G RAM${NC} and ${YELLOW}${TOTAL_CPUS} CPUs${NC}. ${RED}Please back up all files before editing!${NC}"
echo ""

# --- MySQL Report ---
echo -e "-----------------------------------------------------------------"
echo -e "${CYAN}FILE: /etc/my.cnf (or /etc/mysql/my.cnf)${NC}"
echo -e "(${YELLOW}Find the [mysqld] section and add/update these lines${NC})"
echo -e "-----------------------------------------------------------------"
echo -e "${YELLOW}innodb_buffer_pool_size${NC} = ${MYSQL_BUFFER_POOL_MB}M  # (~${MYSQL_BUFFER_POOL_G}G)"
echo -e "${YELLOW}innodb_log_file_size${NC} = ${MYSQL_LOG_FILE_MB}M"
echo -e "${YELLOW}max_connections${NC} = ${MYSQL_MAX_CONN}"
echo ""

# --- PHP-FPM Report ---
echo -e "-----------------------------------------------------------------"
echo -e "${CYAN}FILE: ${PHP_FPM_POOL_CONF}${NC}"
if [ "$PHP_VERSION_DETECTED" = false ]; then
    echo -e "(${YELLOW}Find your active PHP version, e.g., 8.1, 8.2, etc.${NC})"
fi
echo -e "(${YELLOW}Using calculated process size: ${AVG_PHP_PROCESS_MB}MB${NC})"
echo -e "-----------------------------------------------------------------"
echo -e "${YELLOW}pm${NC} = dynamic"
echo -e "${YELLOW}pm.max_children${NC} = ${PHP_MAX_CHILDREN}"
echo -e "${YELLOW}pm.start_servers${NC} = ${PHP_START_SERVERS}"
echo -e "${YELLOW}pm.min_spare_servers${NC} = ${PHP_MIN_SPARE}"
echo -e "${YELLOW}pm.max_spare_servers${NC} = ${PHP_MAX_SPARE}"
echo ""

# --- PHP.ini Report ---
echo -e "-----------------------------------------------------------------"
echo -e "${CYAN}FILE: ${PHP_INI_PATH}${NC}"
if [ "$PHP_VERSION_DETECTED" = false ]; then
    echo -e "(${YELLOW}Find your active PHP-FPM php.ini file${NC})"
fi
echo -e "-----------------------------------------------------------------"
echo -e "${YELLOW}memory_limit${NC} = ${PHP_MEMORY_LIMIT}"
echo -e "${YELLOW}opcache.enable${NC} = 1"
echo -e "${YELLOW}opcache.memory_consumption${NC} = ${PHP_OPCACHE_MEM}"
echo -e "${YELLOW}opcache.interned_strings_buffer${NC} = 32"
echo -e "${YELLOW}opcache.max_accelerated_files${NC} = 10000"
echo ""

# --- Apache Report ---
echo -e "-----------------------------------------------------------------"
echo -e "${CYAN}FILE: /etc/apache2/mods-available/mpm_event.conf${NC}"
echo -e "(${YELLOW}On RHEL/CentOS, this may be /etc/httpd/conf.modules.d/00-mpm.conf${NC})"
echo -e "(${YELLOW}Ensure you are using the Event MPM!${NC})"
echo -e "-----------------------------------------------------------------"
echo -e "<IfModule mpm_event_module>"
echo -e "    ${YELLOW}StartServers${NC}             3"
echo -e "    ${YELLOW}MinSpareThreads${NC}          25"
echo -e "    ${YELLOW}MaxSpareThreads${NC}          75"
echo -e "    ${YELLOW}ThreadsPerChild${NC}         ${APACHE_THREADS_CHILD}"
echo -e "    ${YELLOW}MaxRequestWorkers${NC}      ${APACHE_MAX_WORKERS}"
echo -e "    ${YELLOW}MaxConnectionsPerChild${NC}  ${APACHE_MAX_CONN_CHILD}"
echo -e "</IfModule>"
echo ""

# --- Final Instructions ---
echo -e "-----------------------------------------------------------------"
echo -e "${GREEN}Finished!${NC}"
echo -e "After manually applying these settings, restart all services to"
echo -e "apply the changes:"
echo -e "${YELLOW}sudo systemctl restart mysql${NC}"
echo -e "${YELLOW}sudo systemctl restart ${PHP_RESTART_CMD}${NC}"
echo -e "${YELLOW}sudo systemctl restart apache2${NC} (or httpd)"
echo ""
echo -e "${RED}IMPORTANT:${NC} Monitor your server's RAM usage with ${YELLOW}htop${NC} after"
echo -e "restarting. If you run out of memory, reduce"
echo -e "${YELLOW}innodb_buffer_pool_size${NC} or ${YELLOW}pm.max_children${NC} first."
