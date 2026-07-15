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

The **default FrankenPHP static binary does not bundle `ldap` or `imap`** (ADAM
uses LDAP for authentication and IMAP for mail). Running on a build that lacks
them will break login and messaging in ways that unit tests will not catch.

**Resolve before anything else, by one of:**

- **(a) Build FrankenPHP with the required extensions** — use the documented
  `xcaddy`/static-build flow and include every extension above. Pin the resulting
  binary and distribute it to the fleet.
- **(b) Link FrankenPHP against the system's ZTS PHP** so it loads the same
  extension `.so` files already installed for the CLI. This keeps **one** set of
  extensions for both web and CLI and is the least surprising long-term.

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

## 12. What this runbook intentionally excludes

**Worker mode.** FrankenPHP worker mode (persistent PHP process across requests)
is a separate, larger project with application-code prerequisites — resettable
per-request state, the `register_shutdown_function` → explicit-finish rework, the
CSP-nonce fix, per-tenant isolation, etc. It is documented in
`docs/frankenphp-migration-study.md` in `phinor/adam`. This runbook targets
**classic mode only**, which delivers the FrankenPHP/Caddy operational benefits
(single binary, automatic HTTPS, HTTP/2-3, simpler config) with essentially no
application risk, and is the correct foundation to build worker mode on later.
</content>
