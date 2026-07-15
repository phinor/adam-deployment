# FrankenPHP Migration Runbook (Apache/FPM → FrankenPHP)

**Status:** Draft / advisory runbook
**Scope:** Migrate the ADAM school-server **web tier** from Apache + PHP-FPM to
**FrankenPHP in classic (non-worker) mode**, running as a **native binary under
systemd** on the existing bare Ubuntu VMs.
**Companion doc:** `docs/frankenphp-migration-study.md` in `phinor/adam` (the
application-side analysis, including the worker-mode roadmap that this runbook
deliberately does *not* attempt).

---

## 1. Principle: only the web tier changes

The single most important framing for this migration:

> **Apache + PHP-FPM is replaced by FrankenPHP. The system PHP *CLI* stays.**

Everything ADAM runs on the command line — `deploy.sh`'s `php adam
schema:migrate`, `cache:clear`, `queue:restart`, and the per-tenant
`php cron.php --config=<domain>` cron jobs — uses the **system `php8.4-cli`**,
which is untouched. So:

- The **release model is unchanged**: `releases/<hash>` directories with an
  atomic `live` symlink swap.
- **`deploy.sh` changes in exactly one place** (the opcache-reset step).
- **Cron is unchanged.**
- Because we run FrankenPHP in **classic mode** (a fresh script execution per
  request, exactly like FPM), **none of the worker-mode state-leak issues** from
  the application study apply. This is a low-risk, mechanical migration.

What actually changes:

| Layer | Today | After |
|---|---|---|
| HTTP server | Apache `mpm_event` | FrankenPHP (embeds Caddy + PHP) |
| PHP web SAPI | `php8.4-fpm` (FastCGI over unix socket) | FrankenPHP embedded PHP |
| PHP CLI | `php8.4-cli` | **unchanged** |
| TLS | `certbot --apache` | **Caddy automatic HTTPS (ACME)** |
| Vhost | Apache `<VirtualHost>` per domain | Caddy site block per domain |
| Docroot | `/var/www/adam/live` + root `.htaccess` router | `/var/www/adam/live/public` + `php_server` |
| Opcache flush on deploy | `cachetool` over the FPM socket | `validate_timestamps` + `systemctl reload frankenphp` |
| Process mgmt | `systemctl … apache2`, `php8.4-fpm` | `systemctl … frankenphp` |

---

## 2. 🔴 The #1 prerequisite: PHP extension coverage

**This is the gate that decides whether the migration can proceed at all.**

ADAM's `composer.json` requires a broad set of PHP extensions:
`calendar, curl, dom, exif, fileinfo, ftp, gd, iconv, imap, json, ldap, libxml,
mbstring, mysqli, openssl, pdo, simplexml, sodium, zip, zlib, zend-opcache`.

The **default FrankenPHP static binary does not bundle `ldap` or `imap`**. In
ADAM both extensions are used **only by optional authentication backends** —
`ldap`/`ad` (directory login) via `ext-ldap`, and `pop3` (mail-server login) via
`ext-imap`. Nothing in ADAM's data, reporting, messaging, or PDF core touches
them. Running on a build that lacks them silently breaks those login methods
(not the whole app), in ways unit tests will not catch.

**Resolve before anything else, by one of:**

- **(a) Build FrankenPHP with the required extensions** — use the documented
  `xcaddy`/static-build flow and include every extension above. Pin the resulting
  binary and distribute it to the fleet.
- **(b) Link FrankenPHP against the system's ZTS PHP** so it loads the same
  extension `.so` files already installed for the CLI. This keeps **one** set of
  extensions for both web and CLI and is the least surprising long-term.
- **(c) Eliminate the dependency** — because `ldap`/`imap` are confined to a
  couple of auth backends, they can be replaced with pure-PHP libraries (or the
  backends retired), letting you ship the **stock** FrankenPHP binary with no
  custom build. See **§13** for the full feasibility analysis. This is a larger
  change than (a)/(b) but removes the constraint permanently.

**Acceptance check (run on the built binary before deploying it anywhere):**

```bash
frankenphp php-cli -v      # expect PHP 8.4.x (matching the CLI)
frankenphp php-cli -m      # MUST include: ldap imap gd intl exif ftp sodium \
                           #   zip calendar mysqli mbstring curl dom simplexml \
                           #   iconv fileinfo openssl pdo opcache
```

Do not proceed to §4 until this passes.

> Note: the repo's `docker/Dockerfile` (dev-only) uses the
> `serversideup/php:8.4-frankenphp` image and runs `install-php-extensions ldap
> ftp gd` on top of it — direct evidence that ldap/ftp/gd are **not** in the
> stock image and must be added explicitly. The bare-metal build must do the
> equivalent.

---

## 3. Target server layout

```
/usr/local/bin/frankenphp                 # the binary (built per §2)
/etc/frankenphp/Caddyfile                 # global config + `import sites/*.caddy`
/etc/frankenphp/sites/<domain>.caddy      # one per school (written by new_school.sh)
/etc/frankenphp/php.ini                   # web-tier php.ini overrides (was 99-adam-custom.ini)
/etc/systemd/system/frankenphp.service    # systemd unit
/var/www/adam/live -> releases/<hash>     # unchanged release symlink
/var/www/adam/live/public                 # new docroot (front controller)
```

### 3.1 Global Caddyfile — `/etc/frankenphp/Caddyfile`

```caddyfile
{
    # Automatic HTTPS: certs are issued/renewed via ACME. Set a real address so
    # Let's Encrypt can send expiry notices.
    email ops@adam.co.za

    frankenphp {
        num_threads {$FRANKENPHP_NUM_THREADS:16}   # classic-mode thread pool (see §7)
        # worker mode intentionally NOT configured — see the app study for that project
    }
}

# Per-school sites are added as separate files and imported here.
import /etc/frankenphp/sites/*.caddy
```

### 3.2 Web-tier php.ini — `/etc/frankenphp/php.ini`

Mirror the settings `install_web.sh` currently writes to
`/etc/php/8.4/fpm/conf.d/99-adam-custom.ini`, plus opcache:

```ini
max_input_vars = 5000
post_max_size = 1G
upload_max_filesize = 500M
max_file_uploads = 200
date.timezone = Africa/Johannesburg
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
display_errors = Off
memory_limit = 512M

; --- OPcache (see §6 for why validate_timestamps must be On) ---
opcache.enable = 1
opcache.memory_consumption = 256
opcache.validate_timestamps = 1
opcache.revalidate_freq = 2
```

FrankenPHP is pointed at this file via `PHP_INI_SCAN_DIR` (or `--php-ini`).
**Leave the CLI ini (`/etc/php/8.4/cli/conf.d/99-adam-custom.ini`) exactly as it
is** — cron and deploy depend on it.

### 3.3 systemd unit — `/etc/systemd/system/frankenphp.service`

```ini
[Unit]
Description=FrankenPHP (ADAM web tier)
After=network.target mysql.service

[Service]
Type=notify
User=www-data
Group=www-data
Environment=PHP_INI_SCAN_DIR=/etc/frankenphp
Environment=FRANKENPHP_NUM_THREADS=16
ExecStart=/usr/local/bin/frankenphp run --config /etc/frankenphp/Caddyfile
ExecReload=/usr/local/bin/frankenphp reload --config /etc/frankenphp/Caddyfile
Restart=on-failure
# Bind :80/:443 as the non-root www-data user:
AmbientCapabilities=CAP_NET_BIND_SERVICE
# Caddy needs to write ACME certs/state:
StateDirectory=frankenphp
Environment=XDG_DATA_HOME=/var/lib

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now frankenphp
```

Running as `www-data` matches the current `FPM_USER`, so all the existing
`chown www-data` on `pictures/`, `backup/`, `docrep/`, `temp/` and the config
files remain correct.

---

## 4. Changes to `serverconfig/install_web.sh` (provisioning)

**Remove** from the package install:

- `apache2`
- `php$PHP_VERSION-fpm`
- `python3-certbot-apache`

**Keep** `php$PHP_VERSION-cli` and **all** extension packages (they now serve the
CLI/cron only, but are still required): `-mysql -xml -curl -mbstring -zip -gd
-intl -ldap -imap`, and ensure the remaining composer-required extensions are
present (`-bcmath` is not required; `calendar`, `exif`, `fileinfo`, `ftp`,
`iconv`, `simplexml`, `sodium`, `zip`, `opcache` come from `php-cli`/common or
their own packages — verify with `php -m`).

**Add** the following (replacing `install_php_fpm`'s apache/fpm bits and all of
`switch_apache_version`):

1. Install the FrankenPHP binary built in §2 to `/usr/local/bin/frankenphp`
   (`chmod +x`). Do **not** use `curl https://frankenphp.dev/install.sh | sh`
   blindly — that fetches the stock static binary that lacks ldap/imap. Ship the
   §2 build.
2. Write `/etc/frankenphp/Caddyfile` (§3.1), `/etc/frankenphp/php.ini` (§3.2),
   `mkdir -p /etc/frankenphp/sites`, and the systemd unit (§3.3);
   `systemctl enable --now frankenphp`.
3. Keep `update_firewall_web` as-is (80/443 already opened; Caddy needs **80**
   reachable for the ACME HTTP-01 challenge and **443** for traffic).
4. Delete `configure_php()`'s `fpm` loop iteration — only the `cli` ini is now
   written under `/etc/php/8.4/`; the web ini lives at `/etc/frankenphp/php.ini`.

`install_mysql` and `install_composer` are unchanged.

---

## 5. Changes to `serverconfig/new_school.sh` (per-school onboarding)

Everything up to and including the **cron entry** is unchanged (DB creation,
directory structure, `config.$domain.ini`, and the `php cron.php --config=$domain`
crontab line all stay).

Replace **Step 7 (Apache Configuration)** and **Step 8 (Certbot)** with a Caddy
site file:

```bash
# --- Step 7: FrankenPHP site configuration ---
site_conf="/etc/frankenphp/sites/$domain.caddy"

cat > "$site_conf" <<EOF
$domain {
    root * /var/www/adam/live/public
    encode zstd gzip
    php_server
}
EOF

# Validate and reload (graceful; finishes in-flight requests)
if frankenphp validate --config /etc/frankenphp/Caddyfile; then
    systemctl reload frankenphp
    log "FrankenPHP reloaded with new site $domain."
else
    log "CRITICAL: Caddyfile invalid after adding $domain. Not reloading."
    rm -f "$site_conf"
    exit 1
fi

# --- Step 8: TLS ---
# No certbot. Caddy obtains and renews the certificate automatically via ACME on
# the first HTTPS request to $domain. Preconditions:
#   * DNS for $domain already resolves to this server, and
#   * port 80 is reachable (HTTP-01 challenge).
log "TLS will be provisioned automatically by Caddy on first request to $domain."
```

Key differences from the Apache block:

- **Docroot is `/var/www/adam/live/public`**, not `/var/www/adam/live`. This
  points Caddy straight at the front controller and drops the dependency on the
  project-root `.htaccess` rewrite. (`public/index.php` already bans
  `/public/index.php` as an inbound URI, confirming `public/` is the intended
  docroot.)
- **`php_server`** reproduces what `public/.htaccess` did: try the real file,
  else route to `index.php`.
- **Versioned assets still work with no extra config.** URLs like
  `/vABC123/theme/style.css` have no file on disk, so `php_server` falls through
  to `index.php`, where `includes/handle_static_content.php` strips the `/v.../`
  segment and serves the asset (with its ETag/`Cache-Control`). *(Optional later
  optimisation: a `rewrite` that drops `/v[0-9a-f]+/` followed by `file_server`,
  so Caddy serves statics directly and PHP is bypassed. Not required for cutover.)*
- `apache2ctl configtest` → `frankenphp validate`; `service apache2 reload` →
  `systemctl reload frankenphp`.

> This is the **static** per-school model (one Caddy site file per domain). For a
> fleet moving toward many/dynamic tenants, **§12** describes an on-demand-TLS
> alternative where `new_school.sh` writes **no** web-server config at all.

---

## 6. Changes to `deploy.sh` (release activation)

`deploy.sh` changes in **one place**: the opcache reset (current **Step 7**,
`sudo -u "$FPM_USER" /usr/local/bin/reset_opcache.sh`). That wrapper drives
`cachetool opcache:reset` over the **PHP-FPM unix socket** — which no longer
exists under FrankenPHP.

Replace it with a two-part strategy:

1. **Rely on unique release realpaths (primary).** Each release is extracted to a
   distinct absolute path (`/var/www/adam/releases/<hash>/…`). With
   `opcache.validate_timestamps = On` (set in §3.2), the new release's files are
   *new paths* to opcache, so after the atomic `live` symlink swap FrankenPHP
   compiles and serves them immediately — **no manual flush required.** Old
   cached entries simply age out of SHM.
2. **Graceful reload (secondary).** Still reload the service so any newly added
   per-school site files are picked up and to keep SHM tidy:

```bash
# --- 7. Reload the web server (replaces opcache reset) ---
echo "Reloading FrankenPHP..."
sudo systemctl reload frankenphp || echo "Warning: frankenphp reload failed, continuing..."
```

Also:

- **`deploy.conf`:** `FPM_USER` is no longer meaningful. Either drop it or rename
  it (e.g. `WEB_USER=www-data`) — it is now used, if at all, only for
  file-ownership sanity, not for the reload (which goes through `sudo systemctl`).
- **Everything else is unchanged**: release download, `.ini` copy, `composer
  install --no-dev --optimize-autoloader`, override application,
  `php adam schema:migrate --all-tenants`, the atomic `mv`/`ln -sfn` swap,
  `php adam cache:clear --all-tenants`, `php adam queue:restart --all-tenants`,
  old-release cleanup, and the live-symlink validation.

> **Why not just restart?** A `systemctl restart` clears opcache SHM outright but
> briefly drops in-flight connections. A `reload` is graceful but does not by
> itself clear SHM — which is exactly why we lean on `validate_timestamps` +
> unique realpaths for correctness and use `reload` for config pickup. On these
> low-traffic per-school servers a periodic `restart` (e.g. nightly) is also fine
> to reclaim SHM, but is not required for correctness.

---

## 7. Changes to `install.sh` and `reset_opcache.sh` (deploy bootstrap)

`install.sh`:

- **Drop** the cachetool download
  (`.../cachetool.phar -> /usr/local/bin/cachetool`) and the copy of
  `reset_opcache.sh` to `/usr/local/bin/`.
- **Replace** the sudoers file. Instead of allowing the deploy user to run the
  reset wrapper as `www-data`, allow it to reload/restart FrankenPHP as root:

  ```bash
  cat > /etc/sudoers.d/deploy-user-frankenphp <<EOF
  # Allow the deployment user to reload/restart the web server without a password
  $DEPLOY_USER ALL=(root) NOPASSWD: /usr/bin/systemctl reload frankenphp, /usr/bin/systemctl restart frankenphp
  EOF
  chmod 0440 /etc/sudoers.d/deploy-user-frankenphp
  ```

  (Confirm the `systemctl` path with `command -v systemctl` — it is `/usr/bin/systemctl`
  on current Ubuntu; older layouts use `/bin/systemctl`. Include both if unsure.)
- **Keep** `jq`, the log file + logrotate setup, and the `*/5` deploy cron.

`reset_opcache.sh`:

- **Retire it** (or rename to `reload_web.sh` containing just
  `exec sudo systemctl reload frankenphp`). The `find /var/run/php/*.sock` logic
  it depends on has no analogue under FrankenPHP.

---

## 8. Changes to `serverconfig/tune.sh` (follow-up, lower priority)

`tune.sh` tunes four things: MySQL, PHP-FPM `pm.*`, Apache `mpm_event`, and
opcache. After migration:

- **MySQL section:** unchanged.
- **OPcache section:** still applies (FrankenPHP uses the same Zend opcache) —
  but the target file is now `/etc/frankenphp/php.ini`, not the FPM `php.ini`.
- **PHP-FPM `pm.*` and Apache `mpm_event` sections:** obsolete for the web tier.
  Replace with a single FrankenPHP concurrency knob — `num_threads` in the
  Caddyfile global block (or the `FRANKENPHP_NUM_THREADS` env in the unit).
  Compute it from RAM/CPU much as the old `pm.max_children` was
  (roughly `min(RAM_for_PHP / avg_request_MB, a CPU-based ceiling)`); a sensible
  starting point is `4 × vCPU` and tune from there.
- **Restart target:** `systemctl restart frankenphp` instead of restarting fpm +
  apache.

This is a tuning convenience, not on the critical path — it can be updated in a
follow-up commit after the functional cutover.

---

## 9. Phased cutover (per server)

1. **Gate:** build/obtain the FrankenPHP binary with all required extensions and
   pass the §2 acceptance check. Do not proceed otherwise.
2. **Canary (no downtime):** on one server, run FrankenPHP on **alternate ports**
   alongside the live Apache and smoke-test against a test domain:
   - routing to `index.php`; a real static asset; a **`/v{hash}/` versioned asset**;
   - **login** across LDAP, passkey, and OAuth paths (exercises ldap/openssl/sodium);
   - a **file upload** near the limit (validates `post_max_size`/`upload_max_filesize`);
   - a **large download** (report PDF, backup zip) via `readfile`/`fpassthru`;
   - a **`flush()` progress-streaming** endpoint (e.g. a results import) — confirm
     bytes arrive incrementally; if Caddy buffers/compresses them, disable
     compression on that route;
   - **TLS auto-issue** for the test domain.
3. **Cut over:** `systemctl disable --now apache2` (frees 80/443) → move
   FrankenPHP to 80/443 → `systemctl restart frankenphp` → confirm Caddy issues
   certs for the live domains (DNS must already point here).
4. **Prove the deploy path:** bump/redeploy a release and confirm new code goes
   live after the reload with no stale opcache, and that `queue:restart` and cron
   still run.
5. **Fleet rollout:** repeat per server. Keep `apache2`/`php8.4-fpm` **installed
   but disabled** for a rollback window; remove them once stable.

**Rollback (within the window):** `systemctl disable --now frankenphp` →
`systemctl enable --now apache2 php8.4-fpm` → restore the certbot renewal if it
was removed. Because the release directories and the `live` symlink are untouched
by the web-tier swap, rollback is a service switch, not a code change.

---

## 10. Risks & watch-items

| # | Risk | Mitigation |
|---|---|---|
| 1 | **FrankenPHP build missing ldap/imap** (breaks login/mail) | §2 gate + `frankenphp php-cli -m` acceptance check before any deploy |
| 2 | `flush()`/`ob_flush()` progress streams buffered by Caddy | Test in canary; disable `encode`/buffering on streaming routes if needed |
| 3 | certbot removal → cert fails to issue | Ensure DNS resolves to the server and port 80 is open **before** first request |
| 4 | Stale opcode after a deploy | `opcache.validate_timestamps=On` + unique release realpaths + `reload` |
| 5 | Non-root bind to :80/:443 | `AmbientCapabilities=CAP_NET_BIND_SERVICE` in the unit |
| 6 | Multi-tenant on one host | Fine in **classic** mode (fresh per request). *Do not enable worker mode* without the app-side reset project (see the study). |
| 7 | File-based PHP sessions | Single-node only; used transiently for passkey/OAuth. Move to shared storage only if scaling horizontally. |
| 8 | `systemctl` path in sudoers differs across releases | Verify with `command -v systemctl`; list both `/usr/bin` and `/bin` if unsure |
| 9 | On-demand TLS cert-issuance abuse (§12) | Mandatory central `ask` endpoint gating strictly on real-tenant existence — see `docs/tls-ask-endpoint-spec.md` for controls |
| 10 | Bulk onboarding hits ACME rate limit (shared `*.adam.co.za`, §12) | Stagger onboarding / pre-warm certs / higher-limit ACME account |
| 11 | Central `ask` endpoint outage blocks new-domain issuance (§12) | Run it highly available; existing cached certs are unaffected |

---

## 11. End-state verification checklist

```bash
# Binary & extensions
frankenphp php-cli -v          # PHP 8.4.x
frankenphp php-cli -m          # ldap, imap, gd, intl, exif, ftp, sodium, zip, calendar, ...

# Service
systemctl status frankenphp
journalctl -u frankenphp -n 50 --no-pager

# HTTP + TLS + routing
curl -I https://<domain>/                       # 200, valid Let's Encrypt cert
curl -I https://<domain>/theme/<real-asset>.css # 200 + Cache-Control/ETag
curl -I https://<domain>/vDEADBEEF/theme/<asset>.css  # resolves via handle_static_content.php

# Deploy path
#  bump a release, wait for the */5 cron (or run ./deploy.sh), then confirm the
#  new version string is live and that `frankenphp reload` ran cleanly.

# Functional (manual)
#  - log in via LDAP / passkey / OAuth
#  - upload a large file
#  - download a report PDF and a backup zip
#  - run a streaming import and watch progress arrive incrementally
```

---

## 12. Optional evolution: dynamic multi-tenant hosting (on-demand TLS)

Sections 5 and 9 describe the *static* model that mirrors today's setup: each
school gets a Caddy site file (`/etc/frankenphp/sites/<domain>.caddy`) written by
`new_school.sh`, and Caddy provisions that domain's certificate. This works, but
it still requires a web-server config write + reload per school.

Caddy supports a **fully dynamic** alternative — **On-Demand TLS** — that fits
ADAM's multi-tenant model almost exactly. Instead of one site block per domain,
you run a **single catch-all site** that obtains each domain's certificate
**lazily, on the first HTTPS request**, gated by an authorisation endpoint. New
schools then need **no web-server change at all** — provisioning the tenant's
`config.<domain>.ini` (and DNS) is sufficient, and the site "just works" on first
hit.

This is a natural fit because ADAM **already** selects the tenant from
`HTTP_HOST`, and the fleet already has a central source of truth for which
tenants exist.

**The authorisation (`ask`) endpoint is hosted separately on the central
management server — not inside ADAM and not on the school servers.** It is
specified in full in a companion document,
[`docs/tls-ask-endpoint-spec.md`](./tls-ask-endpoint-spec.md); this section only
covers how the school-server Caddy config consumes it.

### 12.1 How it works

```caddyfile
{
    email ops@adam.co.za

    on_demand_tls {
        # Central authoriser on the management server. Caddy appends `&domain=`.
        # See docs/tls-ask-endpoint-spec.md. It MUST authorise only real tenants,
        # or you invite cert-issuance abuse.
        ask https://mgmt.adam.co.za/v1/tls-authorize?token={$TLS_ASK_TOKEN}
    }

    frankenphp {
        num_threads {$FRANKENPHP_NUM_THREADS:16}
    }
}

# Single catch-all site for every tenant domain.
https:// {
    tls {
        on_demand
    }
    root * /var/www/adam/live/public
    encode zstd gzip
    php_server
}
```

`TLS_ASK_TOKEN` is a fleet-wide shared secret injected via the systemd unit's
environment (Caddy cannot add auth headers to the `ask` request — see the spec
for why the token rides in the URL, plus the stronger source-IP/mTLS controls).

Request flow for a brand-new domain:
1. Client connects over TLS for `newschool.adam.co.za`.
2. Caddy has no cert → calls the **central** ask endpoint
   `GET https://mgmt.adam.co.za/v1/tls-authorize?token=…&domain=newschool.adam.co.za`.
3. The endpoint returns **200** iff that domain is a registered, active tenant →
   Caddy obtains a Let's Encrypt cert (first request blocks a few seconds), caches
   it, and serves. Any other domain gets a non-2xx and **no cert is issued**.

### 12.2 The `ask` (authorisation) endpoint — centralised, mandatory

Without a strict `ask` endpoint, anyone who points DNS at a school server can
force Caddy to attempt certificate issuance for arbitrary names and burn your ACME
rate limit. The endpoint must answer "**is `domain` a real, active ADAM
tenant?**" and nothing else.

It lives on the **central management server** because that is where the fleet's
tenant registry and onboarding/offboarding already live, and it keeps the concern
out of both ADAM and the school servers. The full contract — request/response
shape, the tenant-registry source of truth, the mandatory security controls (it
is network-exposed, not localhost), availability/failure modes, and a reference
implementation — is in
[`docs/tls-ask-endpoint-spec.md`](./tls-ask-endpoint-spec.md). Key points the
school-server side depends on:

- Onboarding must **register the tenant's domain(s) centrally before the first
  request**, so the first HTTPS hit authorises; offboarding removes them.
- The endpoint must be **highly available and fast** — it sits in the TLS
  issuance path for first-seen domains (see the spec's failure-mode analysis).

### 12.3 Impact on the deployment scripts

- **`new_school.sh`** no longer writes a Caddy site file, runs `certbot`, or
  reloads the web server. Its Step 7/8 collapse to: "**register the domain in the
  central registry**, ensure DNS points here; the first request provisions TLS
  automatically." Everything else (DB, dirs, `config.$domain.ini`, cron line) is
  unchanged. **Removing a school** deregisters it centrally (Caddy then stops
  renewing and the cert lapses) — again no web-server change.
- **`install_web.sh`** installs the single catch-all Caddyfile above (pointing at
  the central `ask` URL, with `TLS_ASK_TOKEN` in the unit environment) instead of
  the `import sites/*.caddy` model.
- **`deploy.sh`** no longer needs the reload-for-new-site rationale from §6 (there
  are no per-site files to pick up), though the opcache-correctness argument
  (validate_timestamps + unique realpaths) still stands.

### 12.4 Caveats

- **ACME rate limits are per registered domain.** All `*.adam.co.za` subdomains
  count against the same Let's Encrypt limit (~50 certs/week for the registered
  domain). On-demand issuance is fine at steady state, but a **bulk onboarding**
  of many `*.adam.co.za` schools at once could hit it. Mitigations: stagger
  onboarding, pre-warm certs (issue ahead of go-live by making one authorised
  request per new domain), or use a higher-limit ACME account. Custom vanity
  domains (`portal.myschool.co.za`) are separate registered domains and don't
  share the pool.
- **First-request latency** for a never-seen domain is a few seconds while the
  cert issues; subsequent requests are normal. Acceptable for onboarding.
- **New runtime dependency on the management server.** Every school server's TLS
  path for *first-seen* domains now depends on the central `ask` endpoint. If it
  is down, existing (cached) certs keep serving but new domains cannot be issued —
  hence the high-availability requirement in the spec.
- **Cert storage must persist** across restarts — the systemd unit's
  `StateDirectory`/`XDG_DATA_HOME` already covers this. If you ever run **multiple
  servers** for the same tenant set, point Caddy at a **shared storage backend**
  (e.g. a clustered storage module) so they don't each re-issue and so certs
  survive a node swap.
- **The ask endpoint is security-critical.** See the spec for the required
  controls; treat a permissive `tls-authorize` as a production incident.
- Still **classic mode** — on-demand TLS is orthogonal to worker mode and does not
  change the per-request execution model (see §14).

**When to adopt:** if the fleet is moving toward many tenants per host, or you
want school onboarding to be a pure data operation (no server touch), this is the
target architecture. If you stay at a small, static set of domains per server,
the §5 per-site model is simpler and equally correct — adopt on-demand TLS when
the dynamic-provisioning benefit outweighs the added ask-endpoint surface.

---

## 13. Optional: eliminate the `ldap`/`imap` extension dependency

The §2 extension gate exists because `ext-ldap` and `ext-imap` are missing from
the stock FrankenPHP binary. Both dependencies are **small, isolated, and
optional**, so a third path (§2 option **c**) is to remove them entirely and ship
the **stock** binary. This is also worthwhile on its own merits, independent of
FrankenPHP.

### 13.1 Exactly where the dependencies live

Both extensions are used **only by pluggable authentication backends**, selected
per user by login type in
`classes/ADAM/Security/Authentication/LoginModule::getLoginObject()`
(`ad` / `ldap` / `pop3` / `pass`). The `pass` (internal password), passkey, and
OAuth login paths use **neither** extension.

| Extension | Used by | Files | Config keys |
|---|---|---|---|
| `ext-imap` | `pop3` backend | `Pop3.php` → `Support/MailFetcher.php` (sole caller of `MailFetcher`) | `POP3Server`, `POP3ServerPort`, `pop3serverssl`, `pop3servertls`, `pop3suffix` |
| `ext-ldap` | `ldap` backend | `Authentication/Ldap.php` (direct `ldap_*`) | `auth_ldapserver`, `auth_ldapbasedn`, `auth_ldapprotocol`, `auth_ldapport`, `auth_ldapuserattribute`, `auth_ldapbinduser`, `auth_ldapbindpass`, `auth_ldapprotocolversion` |
| `ext-ldap` | `ad` backend | `Authentication/Ad.php` → bundled `lib/adLDAP.php` (75 `ldap_*` calls) | `auth_adcontroller`, `auth_adaccsuf`, `auth_adsecure` |

### 13.2 `ext-imap` — low effort

`MailFetcher` still carries old mail-*reading* methods (`getBody`, `deleteMail`,
`mailCount`, …), but the **only live usage** is `connect()` + `close()` from the
`Pop3` backend — i.e. pure **credential verification** ("can this user bind to the
mail server?"). Nothing reads mailbox contents.

- **Replace** with a pure-PHP IMAP/POP3 client (e.g. `webklex/php-imap`,
  socket-based, no `ext-imap`), or — since only a login check is needed — a small
  raw-socket POP3/IMAP `LOGIN` over `stream_socket_client()` with TLS. Delete the
  dead reading methods.
- **Extra motivation:** `ext-imap` binds to the UW **c-client** library, which has
  been unmaintained for years and is increasingly awkward to package — it is
  widely treated as legacy regardless of this migration.
- **Effort: Low.** One class, one caller.

### 13.3 `ext-ldap` — medium effort

- **Replace** both the direct `Ldap.php` calls and the bundled `adLDAP` library
  with **`FreeDSx/LDAP`** — a **pure-PHP** LDAP protocol implementation (no
  `ext-ldap`; supports simple bind, search, LDAPS/StartTLS). *(Symfony's Ldap
  component is not an option — it wraps `ext-ldap`.)*
- `Ldap.php`'s connect → bind → search → rebind-as-user flow maps directly onto
  FreeDSx. `Ad.php`'s only real operation is "bind as `user@suffix`", so it too
  becomes a thin FreeDSx bind — which lets you **retire the entire
  `lib/adLDAP.php`** legacy library (a nice simplification bonus).
- **Risk lives in testing, not code:** LDAPS/StartTLS + certificate leniency (the
  current code uses `novalidate-cert`-style behaviour), referrals, and AD quirks
  must be validated against a real directory per school.
- **Effort: Medium.**

### 13.4 The decision input you need first

**How many tenants actually use `ad` / `ldap` / `pop3`?** That is per-tenant DB
settings, not visible in the repo, and it sets the strategy:

- **Few/none** → cheapest path is to **deprecate and remove** those backends (a
  product decision); no replacement code, just drop the modules and the
  `getLoginObject()` cases. `pass`/passkey/OAuth remain.
- **Some rely on them** → reimplement with `FreeDSx` (LDAP/AD) and
  `webklex/php-imap` or a tiny socket client (POP3), preserving functionality
  while dropping both extensions.

### 13.5 Recommendation

Because the surface is tiny and fully contained in the auth layer, this is very
feasible and attractive: it removes the §2 gate (ship the stock binary), retires
the unmaintained c-client dependency, and lets you delete the old adLDAP library.
A sensible sequence: do the **`ext-imap` removal early** (low effort, clear legacy
win), and schedule the **`ext-ldap` → FreeDSx** work once the tenant-usage numbers
are known. Until then, §2 options (a)/(b) keep everything working, so this is an
*optimisation*, not a blocker.

---

## 14. What this runbook intentionally excludes

**Worker mode.** FrankenPHP worker mode (persistent PHP process across requests)
is a separate, larger project with application-code prerequisites — resettable
per-request state, the `register_shutdown_function` → explicit-finish rework, the
CSP-nonce fix, per-tenant isolation, etc. It is documented in
`docs/frankenphp-migration-study.md` in `phinor/adam`. This runbook targets
**classic mode only**, which delivers the FrankenPHP/Caddy operational benefits
(single binary, automatic HTTPS, HTTP/2-3, simpler config) with essentially no
application risk, and is the correct foundation to build worker mode on later.
</content>
