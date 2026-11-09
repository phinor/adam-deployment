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
7. Run `cd ~/deploy && sudo ./install.sh` command to set up the deployment script. Most defaults are fine to accept. Don't forget to paste
   in a Github PAT. Generate the PAT here: https://github.com/settings/personal-access-tokens
8. Wait for the installed `cron` script to run on */5.
9. Verify that a release folder has been created and that a `live` symbolic link exists within the deployment folder.
10. Copy the school configuration files (`config.ini`, `config.*.ini`) from the existing installation into the live
    release folder. The next deployment moves them into the shared `configs` folder (see below) and replaces them with
    links. Copy any other `*.ini` files (such as `secrets.ini`) into the live release folder as well.
11. Verify site still works.

## Maintenance

### School configuration files

Each school's configuration (`config.<host>.ini`, and the default `config.ini`) is kept in `<APP_BASE_DIR>/configs`,
outside every release. Each release holds a link to each file, made by `sync-configs.sh` during deployment. A
rollback therefore keeps the current configuration, and a deployment never loses one.

- **Edit the file in `configs`**, not through the link in `live`. `sed -i`, `mv` and `rsync` replace a link with an
  ordinary file. ADAM reads that file at once, and the next deployment copies it into `configs` (keeping the
  replaced copy in `configs/replaced/`) and links it again. A rollback before that deployment would lose the edit.
- **Add a school** with `serverconfig/new_school.sh`. It writes the file into `configs` and links it into `live`.
- **Remove a school** by deleting both `configs/config.<host>.ini` and the link `live/config.<host>.ini`. A link left
  behind makes ADAM run that school's `--all-tenants` commands against the default `config.ini`; the next deployment
  removes it.
- **Repair the links** in the live release at any time:
  `./sync-configs.sh <APP_BASE_DIR>/configs <APP_BASE_DIR>/live <APP_BASE_DIR>/live`
- The folder is created owned by the deploy user, group `www-data`, mode `2750`. The files hold database passwords.

### New GitHub Personal Access Token

If the token expires or is invalidated, create a new one and update the value in `/home/<user>/.github_token`.

### Locking a release

To lock a release and prevent the script from updating to newer versions, create a lock file `deploy.lock` in the
deployment folder. Note that this file will block deployments indefinitely and the lock will need to be removed manually
which can be done simply by removing the lock file.
