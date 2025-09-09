# ADAM Deployment Script

This is a set of shell scripts that is intended to run via cron to keep ADAM servers updated with the latest release.

## Setup

### Main Scripts

Copy the following files in this repository into a directory on your server. We will assume that you're using `/home/adamadmin/deploy`:
- `deploy.sh`
- `deploy.dist.conf`
- `reset_opcache.sh`

Ensure the two script files are executable:
```bash
chmod +x deploy_latest.sh
chmod +x reset_opcache.sh
```

Rename the `deploy.dist.conf` file and configure the deployment.
```bash
mv deploy.dist.conf deploy.conf
nano deploy.conf
```

### Authentication & Dependencies
#### Create GitHub Personal Access Token (PAT)

This script requires a GitHub PAT to download releases from a private repository.
1. Go to your GitHub **Settings > Developer Settings > Personal access tokens > Fine-grained tokens**
2. Click **Generate new token**
3. Give it a name (e.g. `adam-server1.adam.co.za`) and an expiration date.
4. Under **Repository access**, select the ADAM repository.
5. Under **Repository permiossions**, grant **Contents** `Read-only` access.
6. Generate the token and copy it.

#### Store the token on the server
Place the PAT you've just created in the file specified by `TOKEN_PATH` in your `deploy.conf` file.

```bash
# Replace with your actual token
echo "ghp_YourSecretTokenHere" > /root/.github_token

# Secure the token file
sudo chmod 600 /root/.github_token
```

#### Install `cachetool`

Install the `cachetool` program and verify that it is installed and working:

```bash
sudo curl -sL https://github.com/gordalina/cachetool/releases/latest/download/cachetool.phar -o /usr/local/bin/cachetool
sudo chmod +x /usr/local/bin/cachetool
cachetool --version
```

Create a `sudoers` rule to allow your user to run the OPcache reset script as the web server user (`www-data`) without a password. Always use `visudo`.
```bash
sudo visudo -f /etc/sudoers.d/deploy-user-cachetool
```

Add the following line, replacing `adamadmin` with the username that will run the cron job:
```
# Allow the deployment user to reset OPcache as www-data without a password
adamadmin ALL=(www-data) NOPASSWD: /usr/local/bin/reset_opcache.sh
```

#### Install the Opcache wrapper script

Copy the `reset_opcache.sh` file into the specified path and ensure its executable:
```bash
sudo cp reset_opcache.sh /usr/local/bin/reset_opcache.sh
sudo chmod +x /usr/local/bin/reset_opcache.sh
```

### Cron Job and Logging

#### Create a shared group

Create a new group called 'deployers' to manage write permissions to the log file.
```bash
sudo groupadd deployers
```

Add your user to this group:
```bash
sudo usermod -aG deployers adamadmin
```

Create an empty log file and change the ownership to ensure the `deployers` group has write permissions.
```bash
sudo touch /var/log/deployment.log
sudo chown root:deployers /var/log/deployment.log
sudo chmod g+w /var/log/deployment.log
```

Create a log-rotate rule for your deployment:
```bash
sudo nano /etc/logrotate.d/adam-deployment
```
Add the following contents to the file:
```
/var/log/deployment.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    create 0664 root deployers
}
```

Configure crontab to run the script. Remember to adjust usernames and locations of the script if they change.
```bash
(crontab -l 2>/dev/null | grep -q -F "/home/adamadmin/deploy/deploy_latest.sh") || (crontab -l 2>/dev/null; echo "*/5 * * * * /home/adamadmin/deploy/deploy_latest.sh >> /var/log/deployment.log 2>&1") | crontab -
```
