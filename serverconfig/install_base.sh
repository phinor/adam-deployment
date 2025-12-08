#!/bin/bash
set -e

# --- Configuration ---
LOGFILE="/var/log/adam_base_install.log"
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# --- Helper Functions ---
log() {
    echo "[$TIMESTAMP] $1" | tee -a "$LOGFILE"
}

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "❌ This script must be run as root."
        exit 1
    fi
}

# --- Main Script ---
clear
echo "ADAM Server: Base OS Setup"
echo "=========================="
check_root

# 1. Gather Input
read -p "Enter new sudo username (e.g., adamadmin): " username
read -p "Enter public SSH key string (ssh-rsa ...): " sshpublic
read -p "Enter custom SSH port [e.g. 2222]: " sshport
read -p "Disable password login for SSH? (Keys only) [y/N]: " ssh_keys_only
echo

log "Starting Base Installation..."

# 2. System Updates & Tools
log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qy >> "$LOGFILE" 2>&1
apt-get upgrade -qy >> "$LOGFILE" 2>&1
apt-get install -qy software-properties-common curl wget unzip p7zip-full nano fail2ban ufw git >> "$LOGFILE" 2>&1

# 3. Timezone
log "Setting Timezone..."
ln -fs /usr/share/zoneinfo/Africa/Johannesburg /etc/localtime
dpkg-reconfigure -f noninteractive tzdata >> "$LOGFILE" 2>&1

# 4. User Setup
log "Creating user $username..."
if id "$username" &>/dev/null; then
    log "User already exists. Skipping."
else
    adduser --disabled-password --gecos "" "$username" >> "$LOGFILE" 2>&1
    echo "Set password for $username:"
    passwd "$username"
    usermod -aG sudo "$username"
fi

# 5. SSH Configuration
log "Configuring SSH..."
mkdir -p "/home/$username/.ssh"
echo "$sshpublic" > "/home/$username/.ssh/authorized_keys"
chmod 600 "/home/$username/.ssh/authorized_keys"
chown -R "$username:$username" "/home/$username/.ssh"

# Backup and Modify SSH Config
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "$SSHD_CONFIG.bak"

# Apply Port
sed -i "s/^#\?Port .*/Port $sshport/" "$SSHD_CONFIG"

# Apply Security Settings
if [[ $ssh_keys_only =~ ^[Yy] ]]; then
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
    sed -i 's/^#\?UsePAM.*/UsePAM no/' "$SSHD_CONFIG"
fi

# 6. Firewall (UFW)
log "Configuring Firewall..."
ufw --force reset >> "$LOGFILE" 2>&1
ufw default deny incoming
ufw default allow outgoing
ufw allow "$sshport"/tcp comment 'SSH Custom Port'
echo "y" | ufw enable >> "$LOGFILE" 2>&1

# 7. Restart SSH
log "Restarting SSH service..."
systemctl daemon-reload
systemctl restart ssh.socket

echo
echo "✅ Base setup complete!"
echo "SSH is now on port $sshport."
echo "You can now run install_web.sh to set up the stack."
echo "REBOOT recommended."
