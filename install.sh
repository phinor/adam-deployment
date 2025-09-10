#!/bin/bash
# This script automates the full setup for the ADAM deployment system.

# Exit immediately if any command fails
set -e

# --- Helper Functions for Colored Output ---
info() { echo -e "\033[34m[INFO]\033[0m $1"; }
success() { echo -e "\033[32m[SUCCESS]\033[0m $1"; }
error() { echo -e "\033[31m[ERROR]\033[0m $1"; } >&2
prompt() { read -p "$(echo -e "\033[33m[PROMPT]\033[0m $1: ")"; }

# --- 1. Check for Root and Gather Information ---
if [ "$EUID" -ne 0 ]; then
  error "This script must be run as root. Please use 'sudo ./install.sh'"
  exit 1
fi

info "Starting ADAM Deployment Setup..."

DEFAULT_USER=${SUDO_USER:-$(whoami)}
prompt "Enter the username that will run the cron job (e.g., $DEFAULT_USER)"
DEPLOY_USER=${REPLY:-$DEFAULT_USER}

prompt "Enter the full path to the deployment scripts directory (e.g., /home/$DEPLOY_USER/deploy)"
DEPLOY_DIR=${REPLY:-/home/$DEPLOY_USER/deploy}

prompt "Enter your GitHub repository in 'owner/repo' format (e.g., phinor/adam)"
GITHUB_REPO=${REPLY:-phinor/adam}

prompt "Enter the application's base directory (e.g., /var/www/adam)"
APP_BASE_DIR=${REPLY:-/var/www/adam}

prompt "Enter your GitHub Personal Access Token (PAT)"
GITHUB_TOKEN=${REPLY}

# --- 2. Place Scripts and Create Configuration ---
info "Placing scripts and creating configuration..."
mkdir -p "$DEPLOY_DIR"
cp deploy.sh "$DEPLOY_DIR/"
cp reset_opcache.sh "$DEPLOY_DIR/"
cp deploy.dist.conf "$DEPLOY_DIR/deploy.conf"

# Update the deploy.conf file with user-provided values
sed -i "s|GITHUB_REPO=.*|GITHUB_REPO=\"$GITHUB_REPO\"|" "$DEPLOY_DIR/deploy.conf"
sed -i "s|TOKEN_PATH=.*|TOKEN_PATH=\"/home/$DEPLOY_USER/.github_token\"|" "$DEPLOY_DIR/deploy.conf"
sed -i "s|APP_BASE_DIR=.*|APP_BASE_DIR=\"$APP_BASE_DIR\"|" "$DEPLOY_DIR/deploy.conf"

# Store the PAT securely
TOKEN_FILE="/home/$DEPLOY_USER/.github_token"
echo "$GITHUB_TOKEN" > "$TOKEN_FILE"
chown "$DEPLOY_USER:$DEPLOY_USER" "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
success "Configuration created at $DEPLOY_DIR/deploy.conf"

# --- 3. Set Permissions and Install Dependencies ---
info "Setting script permissions and installing cachetool..."
chmod +x "$DEPLOY_DIR/deploy.sh"
chmod +x "$DEPLOY_DIR/reset_opcache.sh"

info "Creating deploy directory and setting ownership"
mkdir -p $APP_BASE_DIR
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$APP_BASE_DIR"

info "Setting ownership on script files"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_DIR"

curl -sL https://github.com/gordalina/cachetool/releases/latest/download/cachetool.phar -o /usr/local/bin/cachetool
chmod +x /usr/local/bin/cachetool
success "cachetool installed."

# Copy wrapper script to a system path
cp "$DEPLOY_DIR/reset_opcache.sh" /usr/local/bin/reset_opcache.sh
chmod +x /usr/local/bin/reset_opcache.sh
success "OPcache reset wrapper installed."

# install JQ
apt update
apt install jq
success "JQ has been installed"

# --- 4. Configure Sudo and Logging ---
info "Configuring passwordless sudo for cachetool..."
cat << EOF > /etc/sudoers.d/deploy-user-cachetool
# Allow the deployment user to reset OPcache as www-data without a password
$DEPLOY_USER ALL=(www-data) NOPASSWD: /usr/local/bin/reset_opcache.sh
EOF
chmod 0440 /etc/sudoers.d/deploy-user-cachetool
success "Sudoers rule created."

info "Configuring log file and rotation..."
groupadd -f deployers
usermod -aG deployers "$DEPLOY_USER"

touch /var/log/deployment.log
chown "root:deployers" /var/log/deployment.log
chmod g+w /var/log/deployment.log

cat << EOF > /etc/logrotate.d/adam-deployment
/var/log/deployment.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    create 0664 root deployers
}
EOF
success "Log file and rotation configured."

# --- 5. Schedule the Cron Job ---
info "Scheduling the cron job for user '$DEPLOY_USER'..."
CRON_COMMAND="*/5 * * * * $DEPLOY_DIR/deploy.sh >> /var/log/deployment.log 2>&1"
CRON_JOB_EXISTS=$(crontab -u "$DEPLOY_USER" -l 2>/dev/null | grep -F "$DEPLOY_DIR/deploy.sh" || true)

if [ -n "$CRON_JOB_EXISTS" ]; then
    info "Cron job already exists. Skipping."
else
    (crontab -u "$DEPLOY_USER" -l 2>/dev/null || true; echo "$CRON_COMMAND") | crontab -u "$DEPLOY_USER" -
    success "Cron job created."
fi

echo ""
success "ADAM Deployment setup is complete!"
info "Please log out and log back in for group changes to take effect for user '$DEPLOY_USER'."