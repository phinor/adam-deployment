#!/bin/bash

# Determine the directory where this script is located to find the config file.
# 'readlink -f' resolves symlinks to find the script's true location.

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

if [ -f "${SCRIPT_DIR}/deploy.conf" ]; then
    source "${SCRIPT_DIR}/deploy.conf"

    if [ -z "$GITHUB_REPO" ]; then
        echo "Error: GITHUB_REPO is not set in deploy.conf." >&2
        exit 1
    fi
    if [ -z "$TOKEN_PATH" ]; then
        echo "Error: TOKEN_PATH is not set in deploy.conf." >&2
        exit 1
    fi
    if [ -z "$KEEP_RELEASES" ]; then
        echo "Warning: KEEP_RELEASES is not set in deploy.conf - assuming 5." >&2
        KEEP_RELEASES=5
    fi
    if [ -z "$FPM_USER" ]; then
        echo "Error: FPM_USER is not set in deploy.conf." >&2
        exit 1
    fi
else
    echo "Error: Configuration file not found" >&2
    exit 1
fi

# --- MODIFICATION START ---
# Set 'e' to exit on error and 'o pipefail' to ensure a pipeline's exit code
# is the status of the last command to exit with a non-zero status.
set -eo pipefail

# Wrap the entire execution in a block to pipe its output
{
# --- MODIFICATION END ---

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

echo "--- Starting deployment check at $(date) ---"
mkdir -p "$RELEASES_DIR"

# --- 3. Fetch Latest Release Info and Extract Tarball URL ---
API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

echo "Fetching latest release info from GitHub..."
LATEST_RELEASE_INFO=$(curl -s -L \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $(cat "$TOKEN_PATH")" \
  "$API_URL")

TARBALL_URL=$(echo "$LATEST_RELEASE_INFO" | jq -r '.tarball_url')

if [ -z "$TARBALL_URL" ] || [ "$TARBALL_URL" == "null" ]; then
    echo "Error: Could not find 'tarball_url' using jq. Aborting."
    exit 1
fi

# --- 4. Extract Hash and Compare Versions ---
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
    # Create a temporary directory for the build process.
    TMP_RELEASE_PATH="$RELEASES_DIR/tmp-$LATEST_HASH-$(date +%s)"
    mkdir -p "$TMP_RELEASE_PATH"

    # Set a trap: If the script exits for any reason, clean up the temp directory.
    trap 'echo "Deployment failed. Cleaning up temporary directory..."; rm -rf "$TMP_RELEASE_PATH"; exit 1' EXIT SIGHUP SIGINT SIGTERM

    echo "New release detected. Building in temporary directory: $TMP_RELEASE_PATH"

    echo "Downloading release archive from $TARBALL_URL"
    TMP_ARCHIVE=$(mktemp /tmp/release.XXXXXX.tar.gz)
    trap 'rm -f "$TMP_ARCHIVE"' EXIT

    # Added --fail to curl to exit with an error on HTTP failures (like 404).
    curl -s -L --fail -o "$TMP_ARCHIVE" \
      -H "Authorization: Bearer $(cat "$TOKEN_PATH")" \
      "$TARBALL_URL"

    tar -xzf "$TMP_ARCHIVE" -C "$TMP_RELEASE_PATH" --strip-components=1
    rm "$TMP_ARCHIVE"

    # Defense-in-depth: Check if the directory is empty after extraction.
    if [ -z "$(ls -A "$TMP_RELEASE_PATH")" ]; then
        echo "Error: The release directory is empty after extraction. Aborting."
        exit 1
    fi

    RESOLVED_LIVE_PATH="$(readlink -f "$LIVE_LINK")"

    if [ -L "$LIVE_LINK" ] && [ -d "$RESOLVED_LIVE_PATH" ]; then
        echo "Copying .ini configuration files..."
        find "$RESOLVED_LIVE_PATH" -maxdepth 1 -name "*.ini" -exec cp {} "$TMP_RELEASE_PATH/" \;
    fi

    echo "Running composer install..."
    if (cd "$TMP_RELEASE_PATH" && composer install --no-dev --optimize-autoloader --no-progress); then
        echo "Composer install successful."
    else
        echo "Composer install failed. Aborting."
        exit 1
    fi

    # All steps successful, now perform the atomic move.
    echo "Build successful. Moving to final destination."
    mv "$TMP_RELEASE_PATH" "$NEW_RELEASE_PATH"

    # Disable the trap since we have succeeded.
    trap - EXIT SIGHUP SIGINT SIGTERM
fi

# --- 6. Activate the New Release ---
echo "Activating release: $LATEST_HASH"
ln -sfn "$NEW_RELEASE_PATH" "$LIVE_LINK"
echo "$LATEST_HASH" > "$CURRENT_VERSION_FILE"
echo "$LATEST_HASH" > "$NEW_RELEASE_PATH/includes/current.txt"

# --- 7. Reset opcache ---
echo "Resetting PHP OPcache for the web server..."
sudo -u "$FPM_USER" /usr/local/bin/reset_opcache.sh

# --- 8. Clean up ---
echo "Cleaning up old releases..."
ls -1dt "$RELEASES_DIR"/* | tail -n +$(($KEEP_RELEASES + 1)) | xargs -r rm -rf

echo "Deployment of version $LATEST_HASH successful!"
echo "--- Deployment check finished ---"

# --- MODIFICATION START ---
# End of the execution block.
# Pipe both stdout and stderr (2>&1) to the while loop.
} 2>&1 | while IFS= read -r line; do
    # The 'date' format +%Y%m%d-%H%M%S is the shell equivalent of PHP's "Ymd-His"
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
done
# --- MODIFICATION END ---
