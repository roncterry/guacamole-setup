# Overview
Scripts that automate the installation and configuration of Guacamole running in containers on Podman.

# USAGE

The `guacamole-setup.sh` script accepts five arguments: **install** (to install and configure Guacamole on the host), **remove** (to remove Guacamole from the host), **start** (to start an already installed/configured but stopped Guacamole instance), **stop** (stop a running Guacamole instance), **restart** (restart an already installed/configured Guacamole instance), **create_config_only** (only create the Podman container volumes and container configuration but do not install and start containers) and **rotate_cert** (rotate the reverse proxy certificate).

***Installation Example:*** `guacamole-setup.sh install`

***Removal Example:*** `guacamole-setup.sh remove`

***start Example:*** `guacamole-setup.sh start`

***stop Example:*** `guacamole-setup.sh stop`

***restart Example:*** `guacamole-setup.sh restart`

***Config Only Example:*** `guacamole-setup.sh create_config_only`

***Certificate rotation Example:*** `guacamole-setup.sh rotate_cert`


# Configuration Files

The `guacamole-setup.cfg` file in the main configuration file for `guacamole-setup.sh` script.

The `users_connections.cfg` file contains a list of users, connections and user to connection mappings that is sourced into the main configuration file when the script is executed. If you have different lab/demo environments with different users and/or connections you can have a separate `users_connections.cfg` file for each environment.

The `initdb_base.sql` file is the base SQL config file that will be used to initialize the PostgreSQL database when it is run the first time. That file will be copied into the persistent volume attached to the PostgreSQL container and then additional SQL code blocks will be appended to it based on the configurationint the other config files.

These three config files must be in the same directory as the `guacamole-setup.sh` script. If they are not, or their filenames do not match the ones specified at the top the of script, the script will attempt to download the default versions of the files from this Github repository.

## Reverse Proxy Certificate

If you have an existing x.509 certificate and key that you want to use with the reverse proxy, place them in the same directory as the `guacamole-setup.sh` script and name them `server.crt` and `server.key`. If those files exist in that directory they will be used, if they do not exist then a self-signed certificate valid for 365 days will be generated when the `guacamole-setup.sh` script is run. 

To rotate the certificate either: 

  A) To regenerate a self-signed certificate - delete the `server.crt` and `server.key` files 

  B) To use your own new certificate - replace the `server.cert` and `server.key` files with your new certificate and key 

When the files have been delete or replaced, run `guacamole-setup.sh rotate_cert` to rotate the certificate and restart the reverse_proxy container.

# Requirements

## Hostnames and IP addresses

The machine where the `guacamole-steup.sh` script is being run is the machine Guacamole will be installed on. The `/etc/hosts` file on that machine must have an entry for the machine's IP address, FQDN and hostname and/or any IP address, FQDN and hostname that will be used to connect to Guacamole. This is particularly important for HTTPS connections due to the address/name used to connect must match the certificate.

The Gucamole machine must be able to reach the machines that connections will be made to via the network by the FQDNs/hostnames/IP addresses that will be used to make those connections. The IP address and FQDNs/hostnames can be added to the `CONNECTION_HOSTNAME_LIST` variable in the `users_connections.cfg` config file and the script will append them to the `/ect/hosts` file. If DNS resolution is already configured for those machines then that variable can be left blank.

## TLS/SSH/HTTPS

The script will generate a self signed certificate for the Guacamole proxy to use for HTTPS connections. You can edit the `TLS_*` variables in the `guacamole-setup.cfg` config file to specify the values matcing your location and organization that will be used when creating the CSR file for the certificate generation.

If you have your own certificate and key you can use those instead. In that case you must edit the `NGINX_TLS_CERT_FILE` and `NGINX_TLS_KEY_FILE` variables in the `guacamole-setup.cfg` config file to match the names of your certificate and key files and then place those files in the same directory as the `guacamole-setup.sh` script. When the script is run they will be copied into the persistent volume connected to the Guacamole proxy container.

## Users and Passwords

At the moment the procedure for generating new passwords for Guacamole login users has not been documented yet. It is a little bit involved. It will be added here at a later date. You can use the password hashes/salts in the examples in the config files for the time being to test.

# Connection

Once the Guacamole containers are running you access Guacamole at the following URLs:

`https://<IP_OR_HOSTNAME>:8443/guacamole`

`http://<IP_OR_HOSTNAMNE>:8080/guacamole`

