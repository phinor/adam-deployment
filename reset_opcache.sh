#!/bin/bash
set -e

# Change to a world-readable directory to prevent 'Permission denied' warnings
cd /tmp

# Find the active PHP-FPM socket file automatically
PHP_FPM_SOCKET=$(find /var/run/php -type s -name "*.sock" | head -n 1)

if [ -z "$PHP_FPM_SOCKET" ]; then
    echo "Error: Could not find any PHP-FPM socket in /var/run/php/" >&2
    exit 1
fi

# Run the cachetool command with the dynamically found socket
/usr/local/bin/cachetool opcache:reset --fcgi="${PHP_FPM_SOCKET}"