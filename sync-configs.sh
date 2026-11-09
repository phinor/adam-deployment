#!/bin/bash
# Keeps ADAM's school configuration files in one shared folder, outside every release, and links
# them into a release.
#
# Usage: sync-configs.sh <configs-dir> <release-dir> [<live-release-dir>]
#
# A configuration file is config.ini or config.<host>.ini. Other .ini files (secrets.ini) belong to
# the release and are not touched.
#
#   1. Collect: an ordinary file (not a link) in the live release is copied into <configs-dir>. Once
#      a server has been converted the live release holds only links, so an ordinary file there was
#      written after the shared copy: by a script, or by an edit (sed -i, mv) that replaced the
#      link. It therefore replaces the shared copy, which is kept in <configs-dir>/replaced/.
#   2. Link: every configuration file in <configs-dir> is linked into <release-dir>, replacing
#      whatever has that name there.
#   3. Tidy: a link in <release-dir> whose file has gone is removed. ADAM would otherwise still list
#      that school for --all-tenants and, finding no file, run the command against config.ini.
#
# Running it again changes nothing, so it is also the repair command for a live release:
#   sync-configs.sh /var/www/adam/configs /var/www/adam/live /var/www/adam/live
#
# CONFIGS_GROUP (default www-data) is the group given read access to a newly created <configs-dir>.

set -eo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "Usage: $0 <configs-dir> <release-dir> [<live-release-dir>]" >&2
    exit 2
fi

CONFIGS_DIR="$1"
RELEASE_DIR="$2"
LIVE_DIR="${3:-}"
CONFIGS_GROUP="${CONFIGS_GROUP:-www-data}"

if [ ! -d "$RELEASE_DIR" ]; then
    echo "Error: release directory $RELEASE_DIR does not exist." >&2
    exit 1
fi

# --- Shared folder ---
if [ ! -d "$CONFIGS_DIR" ]; then
    echo "Creating the shared configuration folder $CONFIGS_DIR."
    mkdir -p "$CONFIGS_DIR"
    # The files hold database passwords: readable by the owner (the deploy user) and the web
    # server's group only. The setgid bit gives files created here that group too. Without the
    # group the web server could not read the folder at all, so fall back to world-readable.
    if chgrp "$CONFIGS_GROUP" "$CONFIGS_DIR" 2>/dev/null; then
        chmod 2750 "$CONFIGS_DIR"
    else
        chmod 755 "$CONFIGS_DIR"
        echo "Warning: could not give $CONFIGS_DIR the group '$CONFIGS_GROUP'; it is world-readable." \
             "Run: sudo chgrp $CONFIGS_GROUP $CONFIGS_DIR && sudo chmod 2750 $CONFIGS_DIR" >&2
    fi
fi

# --- 1. Collect ordinary files from the live release ---
if [ -n "$LIVE_DIR" ] && [ -d "$LIVE_DIR" ]; then
    for file in "$LIVE_DIR"/config.ini "$LIVE_DIR"/config.*.ini; do
        if [ ! -f "$file" ] || [ -L "$file" ]; then
            continue
        fi

        name=$(basename "$file")
        target="$CONFIGS_DIR/$name"

        if [ -e "$target" ]; then
            if cmp -s "$file" "$target"; then
                continue
            fi
            mkdir -p "$CONFIGS_DIR/replaced"
            backup="$CONFIGS_DIR/replaced/$name.$(date +%Y%m%d-%H%M%S)"
            cp -p "$target" "$backup"
            echo "Replacing $target with the newer ordinary file $file (previous copy kept as $backup)."
        else
            echo "Copying $file into $CONFIGS_DIR."
        fi

        # Write beside the target and rename, so a reader never sees a half-written file. The
        # temporary name does not end in .ini, so nothing mistakes it for a configuration file.
        cp -p "$file" "$target.tmp.$$"
        mv -f "$target.tmp.$$" "$target"
    done
fi

# --- 2. Link every shared file into the release ---
linked=0
for file in "$CONFIGS_DIR"/config.ini "$CONFIGS_DIR"/config.*.ini; do
    if [ ! -f "$file" ]; then
        continue
    fi

    name=$(basename "$file")
    # Create the link under a temporary name and rename it over the old entry, so the name always
    # resolves even when this runs against the live release.
    tmp_link="$RELEASE_DIR/.$name.link.$$"
    ln -sfn "$file" "$tmp_link"
    mv -fT "$tmp_link" "$RELEASE_DIR/$name"
    linked=$((linked + 1))
done

# --- 3. Tidy the release ---
for entry in "$RELEASE_DIR"/config.ini "$RELEASE_DIR"/config.*.ini; do
    if [ -L "$entry" ] && [ ! -e "$entry" ]; then
        rm -f "$entry"
        echo "Removed $entry: it linked to a configuration file that no longer exists."
    elif [ -f "$entry" ] && [ ! -L "$entry" ]; then
        echo "Warning: $entry is an ordinary file, not a link into $CONFIGS_DIR." \
             "The next deployment copies it there and links it." >&2
    fi
done

if [ "$linked" -eq 0 ]; then
    echo "Warning: $CONFIGS_DIR holds no configuration files, so no school is configured in this release." >&2
else
    echo "Linked $linked configuration file(s) from $CONFIGS_DIR into $RELEASE_DIR."
fi
