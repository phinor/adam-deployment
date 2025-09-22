# ADAM Deployment Script

This is a set of shell scripts that is intended to run via cron to keep ADAM servers updated with the latest release.

In each installation, the script looks at the most recent update and installs it. It does not attempt to install
intermediate updates if a server is missing any. Generally, this is fine and expected, but there have been cases where
one update specifically undoes something done in a previous update which might have dependency failures.

## Installation

1. If the server currently hosts ADAM, make sure that it's web dir is not `/var/www/adam`. Move it if it is: `sudo mv /var/www/adam /var/www/adam-old`
2. Get the local user's (this should not be a privileged user) public ssh key with `cat ~/.ssh/id*.pub`. If no SSH key,
generate an SSH key with `ssh-keygen`. Rerun the `cat ~/.ssh/id*.pub` command once done.
3. Add the public key to this repository's deploy keys: https://github.com/phinor/adam-deployment/settings/keys
4. Run the following command while logged in as the deployment user: `cd ~ && git clone git@github.com:phinor/adam-deployment.git deploy`
5. If ssh is blocked on the firewall, try this: `cd ~ && git clone https://github.com/phinor/adam-deployment.git deploy`
7. Run `cd ~/deploy && sudo install.sh` command to set up the deployment script. Most defaults are fine to accept. Don't forget to paste
   in a Github PAT. Generate the PAT here: https://github.com/settings/personal-access-tokens
8. Wait for the installed `cron` script to run on */5.
9. Verify that a release folder has been created and that a `live` symbolic link exists within the deployment folder.
10. Copy all `*.ini` files from existing installation to this release folder.
11. Verify site still works.

## Maintenance

### New GitHub Personal Access Token

If the token expires or is invalidated, create a new one and update the value in `/home/<user>/.github_token`.

### Locking a release

To lock a release and prevent the script from updating to newer versions, create a lock file `deploy.lock` in the
deployment folder. Note that this file will block deployments indefinitely and the lock will need to be removed manually
which can be done simply by removing the lock file.
