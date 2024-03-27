#!/bin/bash

# Passbolt backup recovery script
# based on the migration guide for Debian 12:
# https://www.passbolt.com/docs/hosting/migrate/server/ce/debian/

# ! not a universal script
# ! unhandled edge cases
# ! no checks and verifications
# created for a specific usecase where passbolt runs in a Proxmox LXC under root user

set -e
# set -x

DIR_BACKUP="/root/unpacked_backup"
USR="root"

# variables specific to recovery
WEBUSER="www-data"
#PASSBOLT_DB_USER= #root / passboltadmin
#PASSBOLT_DB= # passboltdb
#PASSBOLT_DB_PWD=

# Check if variables aren't empty
if [ -z "$PASSBOLT_DB_USER" ] || [ -z "$PASSBOLT_DB" ] || [ -z "$PASSBOLT_DB_PWD" ]; then
    echo "Error: PASSBOLT_DB_USER or PASSBOLT_DB_PWD or PASSBOLT_DB is empty."
    echo "Specify them either as env variables or in the script."
    exit 1
fi

# Check argument count
if [ ! "$#" -eq 1 ]; then
    echo "Usage: $0 backup_file"
    exit 1
else
    # argument provided, check if it's a file
    if [ ! -f $1 ]; then
        echo "File $1 not found"
        exit 2
    fi
fi

# Check if the system is running Debian 12
if ! grep -q "Debian" /etc/os-release || ! grep -q "ID=\"12" /etc/os-release; then
    echo "Error: This script is intended to run on Debian 12."
    exit 3
else
    echo "Debian 12 detected. Starting Passbolt recovery..."
fi

print_header() {
    echo -e "\n\n\n\n---------------- $1\n\n"
}

# Passbolt recovery steps

# Step -1. ensure everything is up to date
apt update && apt upgrade -y
apt install -y sudo

# Step 0. Extract the backup into a folder limited to $USR only
print_header "0. Extracting archive"
mkdir -p "$DIR_BACKUP"
chown "$USR":"$USR" "$DIR_BACKUP"
chmod 600 "$DIR_BACKUP"
tar -zxvf "$1" --directory="$DIR_BACKUP"

# Step 1. Restore Passbolt configuration file and ensure rights and ownership are correct:
print_header "1. Restoring Passbolt configs and permissions"
mv "$DIR_BACKUP"/passbolt.php /etc/passbolt
chown "$WEBUSER":"$WEBUSER" /etc/passbolt/passbolt.php
chmod 440 /etc/passbolt/passbolt.php

# Step 2. Restore GPG public and private keys and ensure rights and ownership are correct:
print_header "2. Restoring GPG keys and permissions"
mv "$DIR_BACKUP"/serverkey.asc /etc/passbolt/gpg
mv "$DIR_BACKUP"/serverkey_private.asc /etc/passbolt/gpg
chown "$WEBUSER":"$WEBUSER" /etc/passbolt/gpg/serverkey_private.asc
chown "$WEBUSER":"$WEBUSER" /etc/passbolt/gpg/serverkey.asc
chmod 440 /etc/passbolt/gpg/serverkey.asc
chmod 440 /etc/passbolt/gpg/serverkey_private.asc

# Step 3 - avatar extraction ... skipped, versions <3.2 not supported
print_header "3. skipped, versions <3.2 not supported"

# Step 4 - mysql -u PASSBOLT_DATABASE_USER -p PASSBOLT_DATABASE < passbolt-backup.sql
# assumes single .sql file in the directory
print_header "4. restoring MySQL database"
mysql -u "$PASSBOLT_DB_USER" -p"$PASSBOLT_DB_PWD" "$PASSBOLT_DB" <"$DIR_BACKUP"/*.sql

# Step 5. Import the server key
print_header "5. importing server key"
su -s /bin/bash -c "gpg --home /var/lib/passbolt/.gnupg --import /etc/passbolt/gpg/serverkey_private.asc" www-data

# Step 6. Migrate passbolt to the latest version
print_header "6. passbolt migration to newest version"
sudo -H -u www-data /bin/bash -c "/usr/share/php/passbolt/bin/cake passbolt migrate"

# Step 7. Health check
print_header "7. passbolt healthcheck"
sudo -H -u www-data /bin/bash -c "/usr/share/php/passbolt/bin/cake passbolt healthcheck"

print_header "Passbolt recovery completed successfully."

ip=$(ip -o -4 address show scope global | awk '{print $4}' | cut -d'/' -f1)
echo "Test the instance on https://$ip"
