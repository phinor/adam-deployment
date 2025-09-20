# ADAM Deployment Script

This is a set of shell scripts that is intended to run via cron to keep ADAM servers updated with the latest release.

In each installation, the script looks at the most recent update and installs it. It does not attempt to install
intermediate updates if a server is missing any. Generally, this is fine and expected, but there have been cases where
one update specifically undoes something done in a previous update which might have dependency failures.

## Installation

1. Copy the contents of this repository to a temporary folder on your server.
2. Run the `install_composer.sh` command to install composer
3. Run the `install.sh` command to set up the deployment script. Most defaults are fine to accept. Don't forget to paste
   in a Github PAT.
4. Manually run `deploy.sh` from the installation folder, or wait for the installed `cron` script to run.
5. Verify that a release folder has been created and that a `live` symbolic link exists within the deployment folder.
6. Copy all `*.ini` files from existing installation to this release folder.
7. Reconfigure site to point to the `live` folder.
8. Reset the opcache.
9. Verify site still works.

## Maintenance

### New GitHub Personal Access Token

If the token expires or is invalidated, create a new one and update the value in `/home/<user>/.github_token`.

### Locking a release

To lock a release and prevent the script from updating to newer versions, create a lock file `deploy.lock` in the
deployment folder. Note that this file will block deployments indefinitely and the lock will need to be removed manually
which can be done simply by removing the lock file.
