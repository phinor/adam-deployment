#!/bin/bash
#
# Download the shared secrets asset (secrets.ini) of a release into a release folder.
#
# Usage:  <release JSON on stdin> | GH_TOKEN=... REQUIRE_SECRETS=0|1 fetch-secrets.sh <target-dir>
#
# Exits 0 only when <target-dir>/secrets.ini is valid, or when the release has no
# such asset and REQUIRE_SECRETS=0. Never prints the token or any secret value.

set -eo pipefail

TARGET_DIR="$1"
if [ -z "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR" ]; then
    echo "Usage: fetch-secrets.sh <target-dir> (release JSON on stdin)" >&2
    exit 1
fi

TARGET_FILE="$TARGET_DIR/secrets.ini"
RELEASE_JSON=$(cat)

ASSET_URL=$(echo "$RELEASE_JSON" | jq -r '[.assets[]? | select(.name == "secrets.ini") | .url][0] // empty')

if [ -z "$ASSET_URL" ]; then
    if [ -f "$TARGET_FILE" ]; then
        chmod 644 "$TARGET_FILE"
        echo "Warning: this release has no secrets.ini asset. Keeping the secrets.ini carried from the live release." >&2
        exit 0
    fi
    if [ "$REQUIRE_SECRETS" = "1" ]; then
        echo "Error: this release has no secrets.ini asset and no secrets.ini is carried over." >&2
        exit 1
    fi
    echo "Warning: this release has no secrets.ini asset and no secrets.ini is carried over. Continuing." >&2
    exit 0
fi

# Temporary file in the target directory so the final mv is atomic.
TMP_FILE=$(mktemp "$TARGET_DIR/.secrets.ini.XXXXXX")
trap 'rm -f "$TMP_FILE"' EXIT

if ! curl -sS -L --fail --connect-timeout 20 --max-time 120 -H "Accept: application/octet-stream" -H "Authorization: Bearer $GH_TOKEN" \
    -o "$TMP_FILE" "$ASSET_URL"; then
    echo "Error: could not download the secrets.ini asset." >&2
    exit 1
fi

# Validate: all three keys present and non-blank. Prints key names only.
if ! php -r '
    $values = @parse_ini_file($argv[1], false, INI_SCANNER_RAW);
    if ($values === false) { fwrite(STDERR, "secrets.ini could not be parsed\n"); exit(1); }
    $bad = [];
    foreach (["google_client_secret", "entra_client_secret", "slack_webhook_url"] as $key) {
        if (!isset($values[$key]) || !is_string($values[$key]) || trim($values[$key], " \t\"\x27") === "") { $bad[] = $key; }
    }
    if ($bad) { fwrite(STDERR, "secrets.ini is missing or blank: " . implode(", ", $bad) . "\n"); exit(1); }
' -- "$TMP_FILE"; then
    echo "Error: the downloaded secrets.ini failed validation." >&2
    exit 1
fi

chmod 644 "$TMP_FILE"
mv -f "$TMP_FILE" "$TARGET_FILE"
echo "Shared secrets installed."
