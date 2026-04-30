#!/bin/bash

# Determine the directory where this script is located to find the config file.
# 'readlink -f' resolves symlinks to find the script's true location.
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CONFIG_FILE="${SCRIPT_DIR}/deploy.conf"

if [ -f "$CONFIG_FILE" ]; then
    # Only "eval" lines that look like "VAR=VALUE".
    # This prevents execution of other commands.
    eval "$(grep -E '^[a-zA-Z_][a-zA-Z0-9_]*=' "$CONFIG_FILE")"

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
    if [ -z "$APP_BASE_DIR" ]; then
        echo "Error: APP_BASE_DIR is not set in deploy.conf." >&2
        exit 1
    fi
else
    echo "Error: Configuration file not found at $CONFIG_FILE" >&2
    exit 1
fi

# Set 'e' to exit on error and 'o pipefail' to ensure a pipeline's exit code
# is the status of the last command to exit with a non-zero status.
set -eo pipefail

# --- Derived Variables ---
RELEASES_DIR="$APP_BASE_DIR/releases"
OVERRIDE_DIR="$APP_BASE_DIR/override"
LIVE_LINK="$APP_BASE_DIR/live"
CURRENT_VERSION_FILE="$APP_BASE_DIR/current.txt"
# This file is created by an admin to manually prevent all deployments
MANUAL_LOCK_FILE="$APP_BASE_DIR/deploy.lock"
# This file is used by flock to prevent simultaneous (race condition) runs
AUTO_LOCK_FILE="$APP_BASE_DIR/deploy.mutex"

# --- 1. Check for Deployment Lock ---
# This file is created by an admin to manually pause all deployments.
if [ -f "$MANUAL_LOCK_FILE" ]; then
    echo "Deployment is MANUALLY locked (found $MANUAL_LOCK_FILE). Aborting."
    exit 0
fi

(
    flock -n -E 99 200
    echo "Automatic lock acquired on $AUTO_LOCK_FILE. Proceeding with deployment."

    # --- Deployment Header ---
    echo "======================================================================"
    echo "Deployment started at: $(date)"
    echo "======================================================================"

    # --- 2. Check for Authentication Token ---
    if [ ! -f "$TOKEN_PATH" ]; then
        echo "Authentication Error: GitHub token file not found at $TOKEN_PATH"
        exit 1
    fi
    GH_TOKEN=$(cat "$TOKEN_PATH")
    if [ -z "$GH_TOKEN" ]; then
        echo "Error: Token file is empty at $TOKEN_PATH" >&2
        exit 1
    fi

    mkdir -p "$RELEASES_DIR"

    # --- 3. Fetch Latest Release Info and Extract Tarball URL ---
    API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

    echo "Fetching latest release info from GitHub..."
    LATEST_RELEASE_INFO=$(curl -s -L \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $GH_TOKEN" \
        "$API_URL")

    TARBALL_URL=$(echo "$LATEST_RELEASE_INFO" | jq -r '.tarball_url')

    if [ -z "$TARBALL_URL" ] || [ "$TARBALL_URL" == "null" ]; then
        echo "Error: Could not find 'tarball_url' using jq. Aborting."
        echo "Dumping API response for debugging:" >&2
        echo "$LATEST_RELEASE_INFO" >&2
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
        # Add the new temp archive to the trap
        trap 'echo "Deployment failed. Cleaning up..."; rm -rf "$TMP_RELEASE_PATH"; rm -f "$TMP_ARCHIVE"; exit 1' EXIT SIGHUP SIGINT SIGTERM


        # Added --fail to curl to exit with an error on HTTP failures (like 404).
        curl -s -L --fail -o "$TMP_ARCHIVE" \
            -H "Authorization: Bearer $GH_TOKEN" \
            "$TARBALL_URL"

        # Use -m (or --touch) to set the modification time of extracted files to "now".
        # This ensures the new release directory is seen as the newest by ls -t.
        tar -xzmf "$TMP_ARCHIVE" -C "$TMP_RELEASE_PATH" --strip-components=1
        rm "$TMP_ARCHIVE"

        # Defense-in-depth: Check if the directory is empty after extraction.
        if [ -z "$(ls -A "$TMP_RELEASE_PATH")" ]; then
            echo "Error: The release directory is empty after extraction. Aborting."
            exit 1
        fi

        if [ -L "$LIVE_LINK" ] && [ -d "$(readlink -f "$LIVE_LINK")" ]; then
            RESOLVED_LIVE_PATH="$(readlink -f "$LIVE_LINK")"
            echo "Copying .ini configuration files from live release..."
            find "$RESOLVED_LIVE_PATH" -maxdepth 1 -name "*.ini" -exec cp {} "$TMP_RELEASE_PATH/" \;
        else
            echo "No previous live release found to copy .ini files from. Skipping."
        fi

        echo "Running composer install..."
        if (cd "$TMP_RELEASE_PATH" && composer install --no-dev --optimize-autoloader --no-progress); then
            echo "Composer install successful."
        else
            echo "Composer install failed. Aborting."
            exit 1
        fi

        # --- 5b. Apply Site-Specific Overrides ---
        if [ -d "$OVERRIDE_DIR" ] && [ -n "$(ls -A "$OVERRIDE_DIR")" ]; then
            echo "Override directory found with content. Applying site-specific overrides from $OVERRIDE_DIR..."
            # Use 'cp -a' to preserve permissions, symlinks, etc.
            # The '/.' copies the *contents* of the override dir (including hidden files)
            # into the new release path, overwriting as needed.
            # 'set -e' will catch any errors here and halt the script.
            cp -a "$OVERRIDE_DIR/." "$TMP_RELEASE_PATH/"
            echo "Overrides applied successfully."
        else
            echo "No override directory found at $OVERRIDE_DIR (or directory is empty). Skipping override step."
        fi


        # --- 5c. Run Database Migrations ---
        echo "Running database migrations for all tenants..."
        # We run this against the TMP path so if it fails, the live site is untouched
        if php "$TMP_RELEASE_PATH/adam" schema:migrate --all-tenants; then
            echo "Migrations completed successfully."
        else
            echo "Error: Database migrations failed! Continuing. This should be reported by ADAM."
        fi
        
        # All steps successful, now perform the atomic move.
        echo "Build successful. Moving to final destination."
        touch "$TMP_RELEASE_PATH"
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

    # --- 7b. Restart queue workers for each tenant ---
    echo "Restarting queue workers..."
    php "$LIVE_LINK/adam" queue:restart --all-tenants || echo "Warning: Queue worker restart encountered an error, but continuing deployment..."

    # --- 8. Clean up ---
    echo "Cleaning up old releases..."
    # $NEW_RELEASE_PATH was defined in Step 5 and is the full path
    # to the release we just activated. We use it to protect from cleanup.

    # List all, sort by time (newest first)
    # Filter out the one that is currently live (just in case)
    # Keep the top N releases (by adding 1 to KEEP_RELEASES)
    # Delete the rest
    ls -1dt "$RELEASES_DIR"/* \
        | grep -vF "$NEW_RELEASE_PATH" \
        | tail -n +$((KEEP_RELEASES + 1)) \
        | xargs -r rm -rf

    # --- 9. Validate Live Symlink ---
    echo "Validating live symlink..."
    # This checks if the link exists AND if the target it points to is a valid directory
    if [ -L "$LIVE_LINK" ] && [ -d "$LIVE_LINK" ]; then
        echo "Live symlink is valid and points to a directory."
    else
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
        echo "CRITICAL ERROR: Live symlink is broken or missing!" >&2
        echo "The symlink at $LIVE_LINK does not point to a valid directory." >&2
        echo "The site is likely DOWN. Manual intervention is required." >&2
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
        exit 1 # Exit with a failure
    fi

    echo "Deployment of version $LATEST_HASH successful!"
) 200>"$AUTO_LOCK_FILE"

# --- 1c. Handle Lock Exit Codes ---
# This code runs after the subshell ( ) block has finished.
FLOCK_EXIT_CODE=$?

if [ $FLOCK_EXIT_CODE -eq 0 ]; then
    # This means the ( ) block finished successfully
    echo "Deployment finished and automatic lock released."
    exit 0
elif [ $FLOCK_EXIT_CODE -eq 99 ]; then
    # This is the custom code from 'flock -E 99'
    echo "Deployment is already in progress (another instance holds lock on $AUTO_LOCK_FILE). Aborting." >&2
    exit 0 # Exit gracefully, this is not a true error.
else
    # This means the script *inside* the ( ) block failed
    # (due to 'set -e' or an 'exit 1')
    echo "Deployment FAILED with exit code $FLOCK_EXIT_CODE. Automatic lock released." >&2
    exit $FLOCK_EXIT_CODE
fi
