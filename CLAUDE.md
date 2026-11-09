# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ADAM Deployment System — a set of Bash scripts that automate deployment of the ADAM school management application. A cron job runs `deploy.sh` every 5 minutes, pulling the latest GitHub release and performing atomic symlink-based deployments.

## Repository Structure

- **`deploy.sh`** — Main deployment orchestrator (cron-driven). Fetches latest GitHub release, downloads tarball, runs `composer install`, performs atomic symlink swap, resets OPcache, cleans old releases.
- **`install.sh`** — One-time setup wizard. Prompts for config values, creates `deploy.conf`, installs dependencies (jq, cachetool), sets up the cron job.
- **`deploy.conf`** / **`deploy.dist.conf`** — Runtime config (gitignored) and its template. Key vars: `GITHUB_REPO`, `TOKEN_PATH`, `APP_BASE_DIR`, `KEEP_RELEASES`, `FPM_USER`.
- **`sync-configs.sh`** — Keeps school configuration files (`config.ini`, `config.<host>.ini`) in `$APP_BASE_DIR/configs` and links them into a release. Collects ordinary files from the live release first (they are newer than the shared copy), and removes links whose file has gone. Safe to re-run; also the repair command for `live`.
- **`reset_opcache.sh`** — Dynamically finds the PHP-FPM socket and clears OPcache via cachetool.
- **`install-composer.sh`** / **`install-wkhtmltopdf.sh`** — Dependency installers with checksum validation.
- **`serverconfig/`** — Modular server setup scripts:
  - `install_base.sh` — OS hardening (users, SSH, UFW firewall, fail2ban)
  - `install_web.sh` — LAMP stack (Apache, PHP 8.4-FPM, MySQL, Composer)
  - `new_school.sh` — Per-school ADAM instance (directories, vhost, database, SSL). Writes the configuration into `configs/` and links it into `live`, holding `deploy.mutex` while it does
  - `tune.sh` — Auto-tunes MySQL/PHP-FPM based on detected RAM/CPU. Modes: `report`, `apply`, `revert`.

## Deployment Architecture

```
Cron (*/5) → git pull → deploy.sh
  1. Load deploy.conf
  2. Check locks (deploy.lock = manual pause, deploy.mutex = flock race guard)
  3. Fetch latest release from GitHub API
  4. Compare commit hash with current.txt → skip if unchanged
  5. Download tarball → extract to releases/tmp-{hash}-{ts}/
  6. Copy non-configuration .ini files (secrets.ini) from previous release, run composer install, apply override/ files,
     link school configurations from configs/ (sync-configs.sh), run migrations
  7. Atomic move to releases/{hash}/, refresh configuration links, symlink live → releases/{hash}/
  8. Reset OPcache, update current.txt
  9. Prune old releases beyond KEEP_RELEASES
```

Runtime directory layout at `$APP_BASE_DIR`:
```
live/          → symlink to current release
releases/     → versioned release directories (by commit hash)
override/      → site-specific file overrides copied into each release
configs/       → school configuration files, linked into each release (never inside releases/: pruning would delete it)
current.txt    → active commit hash
deploy.mutex   → flock file
deploy.lock    → touch to pause deployments
```

## Common Commands

```bash
# Manual deployment
./deploy.sh

# Server setup (run as root, in order)
sudo ./serverconfig/install_base.sh
sudo ./serverconfig/install_web.sh

# Add a new school instance
sudo ./serverconfig/new_school.sh

# Performance tuning
./serverconfig/tune.sh report        # dry-run
sudo ./serverconfig/tune.sh apply    # apply with backups
sudo ./serverconfig/tune.sh revert   # restore from backups

# Lock/unlock deployments
touch $APP_BASE_DIR/deploy.lock
rm $APP_BASE_DIR/deploy.lock
```

## Key Technical Details

- All scripts are Bash. No build system, linter, or test framework.
- Deployment uses `flock` for atomic locking (exit code 99 = already running).
- GitHub API authentication via PAT stored at `$TOKEN_PATH` (file permissions 600).
- PHP-FPM socket path is discovered dynamically, not hardcoded.
- `tune.sh` reads ADAM application config files to detect local vs remote database and adjusts MySQL buffer pool allocation accordingly.
- Timezone default is `Africa/Johannesburg`.
