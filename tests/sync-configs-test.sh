#!/bin/bash
# Tests for sync-configs.sh. Works in a temporary folder only.

HERE=$(dirname "$(readlink -f "$0")")
SCRIPT="$HERE/../sync-configs.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The test user's own group stands in for www-data.
export CONFIGS_GROUP
CONFIGS_GROUP=$(id -gn)

FAILURES=0
fail () { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
pass () { echo "ok:   $1"; }

# check <description> <command...>: passes when the command succeeds.
check ()
{
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

is_link_to () { [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]; }
holds () { [ "$(cat "$1")" = "$2" ]; }

# new_case: fresh base folder with configs/, releases/old (live) and releases/new.
new_case ()
{
    BASE="$WORK/case-$RANDOM$RANDOM"
    CONFIGS="$BASE/configs"
    LIVE="$BASE/releases/old"
    NEW="$BASE/releases/new"
    mkdir -p "$LIVE" "$NEW"
}

run_sync () { bash "$SCRIPT" "$@" > "$BASE/out.txt" 2>&1; }

# --- 1. First run: ordinary files in live are collected, linked; other .ini files are left alone ---
new_case
echo "default" > "$LIVE/config.ini"
echo "school-a" > "$LIVE/config.a.adam.co.za.ini"
echo "secret" > "$LIVE/secrets.ini"
echo "dist" > "$LIVE/config.ini.dist"
run_sync "$CONFIGS" "$NEW" "$LIVE"
check "first run exits 0" [ $? -eq 0 ]
check "first run creates the configs folder" [ -d "$CONFIGS" ]
check "configs folder is mode 2750" [ "$(stat -c %a "$CONFIGS")" = "2750" ]
check "config.ini collected" holds "$CONFIGS/config.ini" "default"
check "config.<host>.ini collected" holds "$CONFIGS/config.a.adam.co.za.ini" "school-a"
check "secrets.ini not collected" [ ! -e "$CONFIGS/secrets.ini" ]
check "config.ini.dist not collected" [ ! -e "$CONFIGS/config.ini.dist" ]
check "config.ini linked into new release" is_link_to "$NEW/config.ini" "$CONFIGS/config.ini"
check "config.<host>.ini linked into new release" is_link_to "$NEW/config.a.adam.co.za.ini" "$CONFIGS/config.a.adam.co.za.ini"
check "secrets.ini not linked" [ ! -e "$NEW/secrets.ini" ]
check "live release left untouched" [ ! -L "$LIVE/config.ini" ]
check "no temporary files left" [ -z "$(find "$CONFIGS" "$NEW" -name '*.tmp.*' -o -name '.*.link.*')" ]

# --- 2. Second run: live holds links; nothing is replaced ---
CONFIGS2="$CONFIGS"
LIVE2="$NEW"
NEW2="$BASE/releases/newer"
mkdir -p "$NEW2"
run_sync "$CONFIGS2" "$NEW2" "$LIVE2"
check "links in live are not collected (no replaced/ folder)" [ ! -d "$CONFIGS2/replaced" ]
check "second release linked" is_link_to "$NEW2/config.a.adam.co.za.ini" "$CONFIGS2/config.a.adam.co.za.ini"

# --- 3. An edit that broke the link (sed -i) wins, and the old shared copy is kept ---
sed -i 's/school-a/school-a-edited/' "$LIVE2/config.a.adam.co.za.ini"
check "sed -i turned the link into an ordinary file" [ ! -L "$LIVE2/config.a.adam.co.za.ini" ]
NEW3="$BASE/releases/third"
mkdir -p "$NEW3"
run_sync "$CONFIGS2" "$NEW3" "$LIVE2"
check "edited file replaces the shared copy" holds "$CONFIGS2/config.a.adam.co.za.ini" "school-a-edited"
check "previous shared copy kept in replaced/" \
    holds "$(find "$CONFIGS2/replaced" -name 'config.a.adam.co.za.ini.*' | head -n 1)" "school-a"
check "replacement reported" grep -q "Replacing" "$BASE/out.txt"
check "new release links to the edited file" is_link_to "$NEW3/config.a.adam.co.za.ini" "$CONFIGS2/config.a.adam.co.za.ini"

# --- 4. An ordinary file identical to the shared copy is not backed up again ---
backups_before=$(find "$CONFIGS2/replaced" -type f | wc -l)
run_sync "$CONFIGS2" "$NEW3" "$LIVE2"
check "identical ordinary file makes no new backup" [ "$(find "$CONFIGS2/replaced" -type f | wc -l)" -eq "$backups_before" ]

# --- 5. A link whose file has gone is removed ---
new_case
mkdir -p "$CONFIGS"
echo "default" > "$CONFIGS/config.ini"
ln -s "$CONFIGS/config.gone.ini" "$NEW/config.gone.ini"
run_sync "$CONFIGS" "$NEW" ""
check "broken link removed" [ ! -L "$NEW/config.gone.ini" ]
check "removal reported" grep -q "Removed" "$BASE/out.txt"

# --- 6. An ordinary file in the release with a shared counterpart becomes a link ---
new_case
mkdir -p "$CONFIGS"
echo "shared" > "$CONFIGS/config.b.ini"
echo "from-override" > "$NEW/config.b.ini"
run_sync "$CONFIGS" "$NEW" ""
check "ordinary file in release replaced by link" is_link_to "$NEW/config.b.ini" "$CONFIGS/config.b.ini"

# --- 7. An ordinary file in the release without a shared counterpart is kept, with a warning ---
new_case
mkdir -p "$CONFIGS"
echo "only-here" > "$NEW/config.c.ini"
run_sync "$CONFIGS" "$NEW" ""
check "unshared ordinary file kept" holds "$NEW/config.c.ini" "only-here"
check "unshared ordinary file reported" grep -q "is an ordinary file" "$BASE/out.txt"
check "empty configs folder reported" grep -q "holds no configuration files" "$BASE/out.txt"

# --- 8. No live release (first deployment on a new server) ---
new_case
run_sync "$CONFIGS" "$NEW" ""
check "runs without a live release" [ $? -eq 0 ]
check "configs folder created without a live release" [ -d "$CONFIGS" ]

# --- 9. Running against the live release itself (the repair command) ---
new_case
echo "default" > "$LIVE/config.ini"
run_sync "$CONFIGS" "$LIVE" "$LIVE"
check "repair run converts live's ordinary file to a link" is_link_to "$LIVE/config.ini" "$CONFIGS/config.ini"
check "repair run keeps the content" holds "$LIVE/config.ini" "default"
run_sync "$CONFIGS" "$LIVE" "$LIVE"
check "second repair run changes nothing" [ ! -d "$CONFIGS/replaced" ]

# --- 10. A group that cannot be set falls back to a readable folder ---
new_case
CONFIGS_GROUP="no-such-group-$RANDOM" run_sync "$CONFIGS" "$NEW" ""
check "unknown group falls back to mode 755" [ "$(stat -c %a "$CONFIGS")" = "755" ]
check "fallback reported" grep -q "world-readable" "$BASE/out.txt"

# --- 11. Wrong usage ---
new_case
bash "$SCRIPT" "$CONFIGS" > /dev/null 2>&1
check "one argument is refused" [ $? -eq 2 ]
bash "$SCRIPT" "$CONFIGS" "$BASE/missing" > /dev/null 2>&1
check "missing release folder is refused" [ $? -eq 1 ]

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "All tests passed."
else
    echo "$FAILURES test(s) failed."
    exit 1
fi
