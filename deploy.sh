#!/bin/bash

# Determine the directory where this script is located to find the config file.
# 'readlink -f' resolves symlinks to find the script's true location.

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

if [ -f "${SCRIPT_DIR}/deploy.conf" ]; then
    source "${SCRIPT_DIR}/deploy.conf"
else
    echo "Error: Configuration file not found" >&2
    exit 1
fi

set -e

# --- Derived Variables ---
RELEASES_DIR="$APP_BASE_DIR/releases"
LIVE_LINK="$APP_BASE_DIR/live"
CURRENT_VERSION_FILE="$APP_BASE_DIR/current.txt"
LOCK_FILE="$APP_BASE_DIR/deploy.lock"

# --- 1. Check for Deployment Lock ---
if [ -f "$LOCK_FILE" ]; then
    echo "Deployment is locked. Aborting."
    exit 0
fi

# --- 2. Check for Authentication Token ---
if [ ! -f "$TOKEN_PATH" ]; then
    echo "Authentication Error: GitHub token file not found at $TOKEN_PATH"
    exit 1
fi
GITHUB_TOKEN=$(cat "$TOKEN_PATH")

echo "--- Starting deployment check at $(date) ---"
mkdir -p "$RELEASES_DIR"

# --- 3. Fetch Latest Release Info and Extract Tarball URL ---
API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

echo "Fetching latest release info from GitHub..."
LATEST_RELEASE_INFO=$(curl -s -L \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  "$API_URL")

# Extract the tarball URL using a simple, reliable grep
TARBALL_URL=$(echo "$LATEST_RELEASE_INFO" | grep -o '"tarball_url":[ ]*"[^"]*"' | cut -d '"' -f 4)

if [ -z "$TARBALL_URL" ]; then
    echo "Error: Could not find 'tarball_url' in the API response. Aborting."
    exit 1
fi

# --- 4. Extract Hash and Compare Versions ---
# The hash is the last part of the URL path. 'basename' extracts it cleanly.
LATEST_HASH=$(basename "$TARBALL_URL")

CURRENT_HASH=""
[ -f "$CURRENT_VERSION_FILE" ] && CURRENT_HASH=$(cat "$CURRENT_VERSION_FILE")

if [ "$LATEST_HASH" == "$CURRENT_HASH" ]; then
    echo "Application is already up to date (Version: $CURRENT_HASH)."
    exit 0
fi

echo "Target version detected: '$LATEST_HASH'. Current live version is '$CURRENT_HASH'."

# --- 5. Prepare Release Directory ---
NEW_RELEASE_PATH="$RELEASES_DIR/$LATEST_HASH"

if [ -d "$NEW_RELEASE_PATH" ]; then
    echo "Release directory for $LATEST_HASH already exists. Re-using."
else
    echo "New release detected. Downloading and building..."
    mkdir -p "$NEW_RELEASE_PATH"

    echo "Downloading release archive from $TARBALL_URL"
    # GitHub's tarball URL requires the -L flag to follow redirects
    curl -s -L -o "/tmp/release.tar.gz" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      "$TARBALL_URL"

    # The downloaded tarball has a top-level directory; we use --strip-components=1 to ignore it.
    tar -xzf "/tmp/release.tar.gz" -C "$NEW_RELEASE_PATH" --strip-components=1
    rm "/tmp/release.tar.gz"

    if [ -L "$LIVE_LINK" ] && [ -d "$(readlink -f $LIVE_LINK)" ]; then
        echo "Copying .ini configuration files..."
        find "$(readlink -f $LIVE_LINK)" -maxdepth 1 -name "*.ini" -exec cp {} "$NEW_RELEASE_PATH/" \;
    fi

    echo "Running composer install..."
    # Try to run composer in the root. If it fails (due to the '||'), try it in the '3party' subdirectory.
    # If the second one also fails, the 'set -e' at the top of the script will cause the entire deployment to abort.
    if (cd "$NEW_RELEASE_PATH" && composer install --no-dev --optimize-autoloader); then
        echo "Composer install successful in root directory."
    else
        echo "Composer install failed in both root and '3party' directories. Aborting."
        exit 1
    fi
fi

# --- 6. Activate the New Release ---
echo "Activating release: $LATEST_HASH"
ln -sfn "$NEW_RELEASE_PATH" "$LIVE_LINK"
echo "$LATEST_HASH" > "$CURRENT_VERSION_FILE"
echo "$LATEST_HASH" > "$NEW_RELEASE_PATH/includes/current.txt"

# --- 7. Reset opcache ---
# Reset PHP OPcache by calling the secret file through the web server
echo "Resetting PHP OPcache for the web server..."
sudo -u "$FPM_USER" /usr/local/bin/reset_opcache.sh

# --- 8. Clean up ---
echo "Cleaning up old releases..."
ls -1dt "$RELEASES_DIR"/* | tail -n +$(($KEEP_RELEASES + 1)) | xargs -r rm -rf

echo "Deployment of version $LATEST_HASH successful!"
echo "--- Deployment check finished ---"