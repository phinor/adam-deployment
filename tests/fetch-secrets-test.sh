#!/bin/bash
# Tests for fetch-secrets.sh. Uses fake values and a stub curl only.

HERE=$(dirname "$(readlink -f "$0")")
SCRIPT="$HERE/../fetch-secrets.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/bash
# Stub curl: writes $STUB_FIXTURE to the -o file, or fails when STUB_FAIL=1.
out=""
[ -n "$STUB_ARGS_FILE" ] && printf '%s\n' "$@" > "$STUB_ARGS_FILE"
while [ $# -gt 0 ]; do
    if [ "$1" = "-o" ]; then out="$2"; shift; fi
    shift
done
[ "$STUB_FAIL" = "1" ] && exit 22
cat "$STUB_FIXTURE" > "$out"
STUB
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"

printf 'google_client_secret = "fake-g"\r\nentra_client_secret = "fake-e"\r\nslack_webhook_url = "https://example.invalid/fake"\r\n' > "$WORK/good.ini"
printf 'google_client_secret = "fake-g"\nentra_client_secret = ""\n' > "$WORK/bad.ini"
printf 'carried = "old"\n' > "$WORK/carried.ini"
WITH_ASSET='{"assets":[{"name":"other.txt","url":"https://example.invalid/x"},{"name":"secrets.ini","url":"https://example.invalid/a"}]}'
NO_ASSET='{"assets":[{"name":"other.txt","url":"https://example.invalid/x"}]}'

FAILURES=0
# run_case <name> <json> <fixture> <fail> <require> <carried:0|1> <want-exit> <want-file:good|carried|none>
run_case ()
{
    local name="$1" json="$2" fixture="$3" fail="$4" require="$5" carried="$6" want_exit="$7" want_file="$8"
    local dir="$WORK/case-$RANDOM"
    mkdir -p "$dir"
    [ "$carried" = "1" ] && cp "$WORK/carried.ini" "$dir/secrets.ini" && chmod 600 "$dir/secrets.ini"

    echo "$json" | STUB_FIXTURE="$fixture" STUB_FAIL="$fail" GH_TOKEN=fake-token REQUIRE_SECRETS="$require" \
        bash "$SCRIPT" "$dir" > "$WORK/out.txt" 2>&1
    local code=$?
    local ok=1

    [ "$code" = "$want_exit" ] || ok=0
    case "$want_file" in
        good)    cmp -s "$WORK/good.ini" "$dir/secrets.ini" || ok=0
                 [ "$(stat -c %a "$dir/secrets.ini" 2>/dev/null)" = "644" ] || ok=0 ;;
        carried) cmp -s "$WORK/carried.ini" "$dir/secrets.ini" || ok=0 ;;
        carried644) cmp -s "$WORK/carried.ini" "$dir/secrets.ini" || ok=0
                 [ "$(stat -c %a "$dir/secrets.ini" 2>/dev/null)" = "644" ] || ok=0 ;;
        none)    [ ! -e "$dir/secrets.ini" ] || ok=0 ;;
    esac
    # No temporary files left behind, and no secret values or token printed.
    [ "$(ls -A "$dir" | grep -vc '^secrets.ini$')" = "0" ] || ok=0
    if grep -qE 'fake-g|fake-e|example.invalid/fake|fake-token' "$WORK/out.txt"; then ok=0; fi

    if [ "$ok" = "1" ]; then echo "PASS: $name"; else echo "FAIL: $name (exit $code)"; sed 's/^/    /' "$WORK/out.txt"; FAILURES=$((FAILURES + 1)); fi
}

run_case "asset downloads and validates"           "$WITH_ASSET" "$WORK/good.ini" 0 1 0 0 good
run_case "asset replaces carried file"             "$WITH_ASSET" "$WORK/good.ini" 0 1 1 0 good
run_case "download fails, carried file untouched"  "$WITH_ASSET" "$WORK/good.ini" 1 0 1 1 carried
run_case "download fails, nothing carried"         "$WITH_ASSET" "$WORK/good.ini" 1 0 0 1 none
run_case "validation fails, carried file untouched" "$WITH_ASSET" "$WORK/bad.ini" 0 0 1 1 carried
run_case "validation fails, nothing carried"       "$WITH_ASSET" "$WORK/bad.ini" 0 0 0 1 none
run_case "no asset, carried file kept"             "$NO_ASSET" "$WORK/good.ini" 0 1 1 0 carried644
run_case "no asset, nothing carried, optional"     "$NO_ASSET" "$WORK/good.ini" 0 0 0 0 none
run_case "no asset, nothing carried, required"     "$NO_ASSET" "$WORK/good.ini" 0 1 0 1 none

# The download call must be bounded in time and send the asset and authorisation headers.
ARGS_DIR="$WORK/args-case"
mkdir -p "$ARGS_DIR"
echo "$WITH_ASSET" | STUB_ARGS_FILE="$WORK/curl-args.txt" STUB_FIXTURE="$WORK/good.ini" GH_TOKEN=fake-token REQUIRE_SECRETS=1 \
    bash "$SCRIPT" "$ARGS_DIR" > /dev/null 2>&1
args_ok=1
for want in "--connect-timeout" "20" "--max-time" "120" "Accept: application/octet-stream" "Authorization: Bearer fake-token"; do
    grep -qxF -- "$want" "$WORK/curl-args.txt" || { args_ok=0; echo "    curl was not given: $want" | sed 's/fake-token/<token>/'; }
done
if [ "$args_ok" = "1" ]; then echo "PASS: curl gets timeouts and headers"; else echo "FAIL: curl gets timeouts and headers"; FAILURES=$((FAILURES + 1)); fi

if [ "$FAILURES" -ne 0 ]; then echo "$FAILURES case(s) failed."; exit 1; fi
echo "All cases passed."
