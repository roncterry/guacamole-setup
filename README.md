# Overview
Scripts that automate the installation and configuration of Guacamole running in containers on Podman.

# USAGE

The `guacamole-setup.sh` script accepts two arguments: **install** (to install and configure Guacamole on the host) and **remove** (to remove Guacamole from the host).

***Installation Example:*** `guacamole-setup.sh install`

***Removal Example:*** `guacamole-setup.sh remove`

# Configuration Files

The `guacamole-setup.cfg` file in the main configuration file for `guacamole-setup.sh` script.

The `users_connections.cfg` file contains a list of users, connections and user to connection mappings that is sourced into the main configuration file when the script is executed. If you have different lab/demo environments with different users and/or connections you can have a separate `users_connections.cfg` file for each environment.

The `initdb_base.sql` file is the base SQL config file that will be used to initialize the PostgreSQL database when it is run the first time. That file will be copied into the persistent volume attached to the PostgreSQL container and then additional SQL code blocks will be appended to it based on the configurationint the other config files.

These three config files must be in the same directory as the `guacamole-setup.sh` script. If they are not, or their filenames do not match the ones specified at the top the of script, the script will attempt to download the default versions of the files from this Github repository.

# Requirements

## Hostnames and IP addresses

The machine where the `guacamole-steup.sh` script is being run is the machine Guacamole will be installed on. The `/etc/hosts` file on that machine must have an entry for the machine's IP address, FQDN and hostname and/or any IP address, FQDN and hostname that will be used to connect to Guacamole. This is particularly important for HTTPS connections due to the address/name used to connect must match the certificate.

The Gucamole machine must be able to reach the machines that connections will be made to via the network by the FQDNs/hostnames/IP addresses that will be used to make those connections. The IP address and FQDNs/hostnames can be added to the `CONNECTION_HOSTNAME_LIST` variable in the `users_connections.cfg` config file and the script will append them to the `/ect/hosts` file. If DNS resolution is already configured for those machines then that variable can be left blank.

## TLS/SSH/HTTPS

The script will generate a self signed certificate for the Guacamole proxy to use for HTTPS connections. You can edit the `TLS_*` variables in the `guacamole-setup.cfg` config file to specify the values matcing your location and organization that will be used when creating the CSR file for the certificate generation.

If you have your own certificate and key you can use those instead. In that case you must edit the `NGINX_TLS_CERT_FILE` and `NGINX_TLS_KEY_FILE` variables in the `guacamole-setup.cfg` config file to match the names of your certificate and key files and then place those files in the same directory as the `guacamole-setup.sh` script. When the script is run they will be copied into the persistent volume connected to the Guacamole proxy container.

## Users and Passwords

At the moment the procedure for generating new passwords for Guacamole login users has not been documented yet. It is a little bit involved. It will be added here at a later date. You can use the password hashes/salts in the examples in the config files for the time being to test.
