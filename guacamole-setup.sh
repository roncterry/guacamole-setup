#!/bin/bash
# This script will setup Guacamole on the host on which it is run.

##############################################################################
# Set Variables
##############################################################################

if echo ${*} | grep -q "configdir="
then
  CONFIG_DIR=$(echo ${*} | grep " configdir=.*" | cut =d = -f 2)/
fi

if [ -z ${CONFIG_DIR} ]
then
  CONFIG_DIR=${PWD}/
fi

MAIN_CONFIG_FILE=${CONFIG_DIR}guacamole-setup.cfg
USERS_CONNECTIONS_CONFIG_FILE=${CONFIG_DIR}users_connections.cfg
INITDB_BASE_FILE=${CONFIG_DIR}initdb_base.sql

DEFAULT_MAIN_CONFIG_FILE=
DEFAULT_USERS_CONNECTIONS_CONFIG_URL=
DEFAULT_INITDB_BASE_URL=

##############################################################################

GUACAMOLE_CONTAINER_LIST="guacdb guacd guacamole guacamole_proxy"

export EXTERNAL_NIC=$(ip route show | grep "^default" | awk '{ print $5 }')
export IP=$(ip addr show ${EXTERNAL_NIC} | grep "inet\b" | awk '{print $2}' | cut -d/ -f1)
#NAME=$(hostname)

##############################################################################
# Functions
##############################################################################

usage() {
  echo
  echo "USAGE: ${0} create_config_only|install|remove|start|stop|restart|rotate_certs [configdir=<CONFIG_DIR>]"
  echo
  echo "      create_config_only  -Only create the Guacamole Configuration"
  echo "      install             -Install and start Guacamole"
  echo "      remove              -Stop and remove Guacamole"
  echo "      start               -Start a stopped instance of Guacamole"
  echo "      stop                -Stop a running instance of Guacamole"
  echo "      restart             -Restart Guacamole"
  echo "      status              -Display the status of the Guacamole systemd services and containers"
  echo "      rotate_certs        -Regenerate and rotate reverse proxy certificates"
  echo
  echo "  If the configdir=<CONFIG_DIR> option is supplied, all config files will be"
  echo "  place into and referenced from that directory (where CONFIG_DIR is an"
  echo "  absolute path ending with a trailing \"/\" - i.e. /opt/guacamole/). If it is"
  echo "  not supplied the current working directory is used as the config directory."
  echo
  echo "  If configdir= is supplied it must be the last option on the command line."
  echo
}

wait_for() {
  local INTERVALS=31
  local WAIT_INTERVAL=5
  local COMMAND=${1}
  local MESSAGE=${2}
  local RESULT=1
  local COUNTER=1
  until (( ${RESULT} == 0 )) || (( ${COUNTER} == ${INTERVALS} ))
  do
    [[ (( ${COUNTER} > 1 )) ]] && sleep ${WAIT_INTERVAL}
    echo "${MESSAGE}: attempt ${COUNTER}..."
    ${COMMAND} &>/dev/null
    RESULT=$?
    COUNTER=$(( COUNTER + 1 ))
  done
  [[ (( ${RESULT} != 0 )) ]] && echo -e "Could not connect!"
}

source_in_config_files() {
  if [ -e ${MAIN_CONFIG_FILE} ]
  then
    echo
    echo "(Main config file found. Sourcing it ...)"
    source ${MAIN_CONFIG_FILE}
    GUACAMOLE_NETWORK="$(echo ${GUACAMOLE_NETWORK_LIST} | awk '{ print $1 }')"
    echo
  else
    echo
    echo "Main config file not found. Attempting to retrieve it ..."
    echo

    if ! [ -z ${DEFAULT_MAIN_CONFIG_FILE} ]
    then
      echo "COMMAND: curl ${DEFAULT_MAIN_CONFIG_URL} --output ${MAIN_CONFIG_FILE}"
      curl ${DEFAULT_MAIN_CONFIG_URL} --output ${MAIN_CONFIG_FILE}
      echo

      if [ -e ${MAIN_CONFIG_FILE} ]
      then
        source ${MAIN_CONFIG_FILE}
        GUACAMOLE_NETWORK="$(echo ${GUACAMOLE_NETWORK_LIST} | awk '{ print $1 }')"
      else
        echo
        echo "ERROR: Unable to retrieve the main config file. Exiting ..."
        echo
        exit 1
      fi
    else
      echo
      echo "ERROR: No default main config URL specified. Exiting ..."
      echo
      exit 1
    fi
  fi

  if [ -e ${USERS_CONNECTIONS_CONFIG_FILE} ]
  then
    echo
    echo "(Users and connections config file found. Sourcing it ...)"
    source ${USERS_CONNECTIONS_CONFIG_FILE}
    echo
  else
    echo
    echo "Users and Connections config file not found. Attempting to retrieve it ..."
    echo

    if ! [ -z ${DEFAULT_USERS_CONNECTIONS_CONFIG_FILE} ]
    then
      echo "COMMAND: curl ${DEFAULT_USERS_CONNECTIONS_CONFIG_URL} --output ${USERS_CONNECTIONS_CONFIG_FILE}"
      curl ${DEFAULT_USERS_CONNECTIONS_CONFIG_URL} --output ${USERS_CONNECTIONS_CONFIG_FILE}
      echo

      if [ -e ${USERS_CONNECTIONS_CONFIG_FILE} ]
      then
        source ${USERS_CONNECTIONS_CONFIG_FILE}
      else
        echo
        echo "ERROR: Unable to retrieve the users and connections config file. Exiting ..."
        echo
        exit 2
      fi
    else
      echo
      echo "ERROR: No default users and connections config URL specified. Exiting ..."
      echo
      exit 2
    fi
  fi
}

retrieve_base_initdb_file() {
  if [ -e ${INITDB_BASE_FILE} ]
  then
    echo
    echo "Base initdb file found. Continuing ..."
    echo
  else
    echo
    echo "Base initdb file not found. Attempting to retrieve it ..."
    echo

    if ! [ -z ${DEFAULT_INITDB_BASE_URL} ]
    then
      echo "COMMAND: curl ${DEFAULT_INITDB_BASE_URL} --output ${INITDB_BASE_FILE}"
      curl ${DEFAULT_INITDB_BASE_URL} --output ${INITDB_BASE_FILE}
      echo

      if [ -e ${INITDB_BASE_FILE} ]
      then
        echo
        echo "Base initdb file retrieved. Continuing ..."
        echo
      else
        echo
        echo "ERROR: Unable to retrieve the initdb base file. Exiting ..."
        echo
        exit 3
      fi
    else
      echo
      echo "ERROR: No initdb base file found. Exiting ..."
      echo
      exit 3
    fi
  fi
}

generate_base_initdb_file() {
  case ${GUACAMOLE_DBMS} in
    postgresql)
      echo "Generating base initdb.sql file for PostgreSQL ...)"
      echo "COMMAND: podman run --rm ${GUACAMOLE_CONTAINER_IMAGE} /opt/guacamole/bin/initdb.sh --postgresql > ${CONFIG_DIR}initdb.sql"
      echo
      podman run --rm ${GUACAMOLE_CONTAINER_IMAGE} /opt/guacamole/bin/initdb.sh --postgresql > ${CONFIG_DIR}initdb.sql
      echo
    ;;
    mariadb|mysql)
      echo "Generating base initdb.sql file for MariaDB ...)"
      echo "COMMAND: podman run --rm ${GUACAMOLE_CONTAINER_IMAGE} /opt/guacamole/bin/initdb.sh --mysql > ${CONFIG_DIR}initdb.sql"
      echo
      podman run --rm ${GUACAMOLE_CONTAINER_IMAGE} /opt/guacamole/bin/initdb.sh --mysql > ${CONFIG_DIR}initdb.sql
      echo
    ;;
  esac
}

generate_tls_certificate() {
  echo "======================================================================"
  echo "Generating TLS certificate and key ..."
  echo "======================================================================"
  echo
  
  if ! [ -e ${CONFIG_DIR}${NGINX_TLS_CERT_FILE} ]
  then
    echo "COMMAND: openssl req -x509 -newkey rsa:4096 -keyout ${CONFIG_DIR}key.pem -out ${CONFIG_DIR}cert.pem -sha256 -days ${TLS_DAYS} -nodes -subj \"/C=${TLS_C}/ST=${TLS_ST}/L=${TLS_L}/O=${TLS_O}/OU=${TLS_OU}/CN=${HOSTNAME}\" -addext \"subjectAltName=DNS:$(echo ${HOSTNAME}),DNS:*.$(echo ${HOSTNAME} | cut -d . -f 2,3,4,5,6),IP:${IP}\""
    openssl req -x509 -newkey rsa:4096 -keyout ${CONFIG_DIR}key.pem -out ${CONFIG_DIR}cert.pem -sha256 -days ${TLS_DAYS} -nodes -subj "/C=${TLS_C}/ST=${TLS_ST}/L=${TLS_L}/O=${TLS_O}/OU=${TLS_OU}/CN=${HOSTNAME}" -addext "subjectAltName=DNS:$(echo ${HOSTNAME}),DNS:*.$(echo ${HOSTNAME} | cut -d . -f 2,3,4,5,6),IP:${IP}"
  else
    echo "Using existing certificate files."
  fi
  echo
}

create_nginx_proxy_config() {
  echo "======================================================================"
  echo "Creating Guacamole NGINX Proxy config file ..."
  echo "======================================================================"
  echo

  if ! [ -e ${CONFIG_DIR}${NGINX_CONFIG_FILE} ]
  then
    case ${GUACAMOLE_WEBAPP_CONTEXT} in
      ROOT)
        echo "
server {
  listen ${NGINX_TLS_PORT} ssl;

  ssl_certificate /etc/nginx/conf.d/server.crt;
  ssl_certificate_key /etc/nginx/conf.d/server.key;
  location /guacamole/ {
    proxy_pass http://host.containers.internal:${GUACAMOLE_EXTERNAL_PORT}/;
    proxy_buffering off;
    proxy_http_version 1.1;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$http_connection;
  }
}" > ${CONFIG_DIR}${NGINX_CONFIG_FILE}
      ;;
      *)
        echo "
server {
  listen ${NGINX_TLS_PORT} ssl;

  ssl_certificate /etc/nginx/conf.d/server.crt;
  ssl_certificate_key /etc/nginx/conf.d/server.key;
  location /guacamole/ {
    proxy_pass http://host.containers.internal:${GUACAMOLE_EXTERNAL_PORT}/guacamole/;
    proxy_buffering off;
    proxy_http_version 1.1;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$http_connection;
  }
}" > ${CONFIG_DIR}${NGINX_CONFIG_FILE}
      ;;
    esac
  else
    echo "Using existing NGINX config file."
    echo
  fi
  cat ${CONFIG_DIR}${NGINX_CONFIG_FILE}
  echo
}

create_guacd_required_folders_and_files() {
  echo "COMMAND: sudo mkdir -m 775 -p ${PODMAN_DIR}/guacd/{drive,records}"
  sudo mkdir -m 775 -p ${PODMAN_DIR}/guacd/{drive,records}
  echo

  echo "COMMAND: sudo chown ${UID}:users -R ${PODMAN_DIR}/guacd"
  sudo chown ${UID}:users -R ${PODMAN_DIR}/guacd
  echo
}

create_guacamole_required_folders_and_files() {
  echo "COMMAND: sudo mkdir -m 775 -p ${PODMAN_DIR}/guacamole/home/.guacamole"
  sudo mkdir -m 775 -p ${PODMAN_DIR}/guacamole/home/.guacamole
  echo

  echo "COMMAND: sudo chown ${UID}:users -R ${PODMAN_DIR}/guacamole"
  sudo chown ${UID}:users -R ${PODMAN_DIR}/guacamole
  echo
}

create_postgress_required_folders_and_files() {
  echo "COMMAND: sudo mkdir -m 775 -p ${PODMAN_DIR}/postgresql/{data,init}"
  sudo mkdir -m 775 -p ${PODMAN_DIR}/postgresql/{data,init}
  echo

  echo "COMMAND: sudo cp ${INITDB_BASE_FILE} ${PODMAN_DIR}/postgresql/init/initdb.sql"
  sudo cp ${INITDB_BASE_FILE} ${PODMAN_DIR}/postgresql/init/initdb.sql
  echo

  echo "COMMAND: sudo chown ${UID}:users -R ${PODMAN_DIR}/postgresql"
  sudo chown ${UID}:users -R ${PODMAN_DIR}/postgresql
  echo
}

create_mariadb_required_folders_and_files() {
  echo "COMMAND: sudo mkdir -m 775 -p ${PODMAN_DIR}/mariadbd/{data,init}"
  sudo mkdir -m 775 -p ${PODMAN_DIR}/mariadb/{data,init}
  echo

  echo "COMMAND: sudo chown ${UID}:users -R ${PODMAN_DIR}/mariadb"
  sudo chown ${UID}:users -R ${PODMAN_DIR}/mariadb
  echo
}

create_guacamole_proxy_required_files_and_folders() {
  echo "COMMAND: sudo mkdir -m 775 -p ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d"
  sudo mkdir -m 775 -p ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d
  echo

  echo "COMMAND: sudo cp ${NGINX_CONFIG_FILE} ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d/default.conf"
  sudo cp ${NGINX_CONFIG_FILE} ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d/default.conf
  echo

  echo "COMMAND: sudo cp ${NGINX_TLS_CERT_FILE} ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d/server.crt"
  sudo cp ${NGINX_TLS_CERT_FILE} ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d/server.crt
  echo

  echo "COMMAND: sudo cp ${NGINX_TLS_KEY_FILE} ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d/server.key"
  sudo cp ${NGINX_TLS_KEY_FILE} ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d/server.key
  echo

  echo "COMMAND: sudo chown ${UID}:users -R ${PODMAN_DIR}"
  sudo chown ${UID}:users -R ${PODMAN_DIR}
  echo
}

copy_certificate_into_proxy_volume() {
  echo "======================================================================"
  echo "Copying certificates into Reverse Proxy ..."
  echo "======================================================================"
  echo
  
  echo "COMMAND: sudo cp ${CONFIG_DIR}${NGINX_TLS_CERT_FILE} ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d/server.crt"
  sudo cp ${CONFIG_DIR}${NGINX_TLS_CERT_FILE} ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d/server.crt
  echo

  echo "COMMAND: sudo cp ${CONFIG_DIR}${NGINX_TLS_KEY_FILE} ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d/server.key"
  sudo cp ${CONFIG_DIR}${NGINX_TLS_KEY_FILE} ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d/server.key
  echo
}

change_podman_dir_permissions_and_ownership() {
  echo "======================================================================"
  echo "Setting permissions and ownership on the Podman directory ..."
  echo "======================================================================"
  echo
  # Set the ownership on the folders
  echo "COMMAND: sudo chown ${UID}:users -R ${PODMAN_DIR}"
  sudo chown ${UID}:users -R ${PODMAN_DIR}
  echo
}

install_required_packages() {
  local INSTALL_PKG_LIST=

  echo "======================================================================"
  echo "Installing required packages ..."
  echo "======================================================================"
  echo

  source /etc/os-release

  case ${ID} in
    opensuse-leap|opensuse-tumbleweed|sles|sled) 
      for REQUIRED_PKG in ${REQUIRED_PKG_LIST}
      do
        if ! rpm -qa | grep -q "^${REQUIRED_PKG}"
        then
          INSTALL_PKG_LIST="${INSTALL_PKG_LIST} ${REQUIRED_PKG}"
        fi
      done

      if ! [ -z ${INSTALL_PKG_LIST} ]
      then
        echo "COMMAND: sudo zypper ref"
        sudo zypper ref
        echo
 
        echo "COMMAND: sudo zypper install -y ${INSTALL_PKG_LIST}"
        sudo zypper install -y ${INSTALL_PKG_LIST}
        echo
      else
        echo "(All required packages are already installed)"
        echo
      fi
    ;;
  esac
}

update_hosts_file() {
  echo "======================================================================"
  echo "Updating /etc/hosts file ..."
  echo "======================================================================"
  echo

  #if ! grep -q "^${IP}" /etc/hosts
  #then
  #  echo "COMMAND: echo ${IP}   $(hostname -f) ${HOSTNAME} | sudo tee -a /etc/hosts"
  #  echo ${IP}   $(hostname -f) ${HOSTNAME} | sudo tee -a /etc/hosts
  #  echo
  #else
  #  echo "The local host is already in the /etc/hosts file."
  #  echo
  #fi

  for HOST_ENTRY in ${CONNECTION_HOSTNAME_LIST}
  do
    local CONNECTION_HOSTNAME=$(echo ${HOST_ENTRY} | cut -d , -f 1)
    local IP_ADDR=$(echo ${HOST_ENTRY} | cut -d , -f 2)

    if ! grep -q "^${IP_ADDR}" /etc/hosts
    then
      echo "COMMAND: echo ${IP_ADDR}   ${CONNECTION_HOSTNAME} | sudo tee -a /etc/hosts":
      echo ${IP_ADDR}   ${CONNECTION_HOSTNAME} | sudo tee -a /etc/hosts
      echo
    else
      echo "The host '${CONNECTION_HOSTNAME}' is already in the /etc/hosts file."
      echo
    fi
  done
}

configure_host_for_podman() {
  echo "======================================================================"
  echo "Creating required configuration for Podman ..."
  echo "======================================================================"
  echo

  # FIXME: -Add some inteligence to list just port numbers, 
  #        -Autobuild GUACAMOLE_PROXY_EXPOSED_PORTS_STRING variable from the 
  #         list of ports, 
  #        -Determine the lowest port and if too low change the 
  #         net.ipv4.ip_unprivileged_port_start value

  export GUACAMOLE_PROXY_EXPOSED_PORTS_STRING="-p 443:443 -p 80:80 -p ${NGINX_TLS_PORT}:${NGINX_TLS_PORT}"
  local SYSCTL_IP_UNPRIVILEGED_PORT_START=80

  echo "-Checking current net.ipv4.ip_unprivileged_port_start value ..."

  if ! sudo sysctl -a | grep -q "net.ipv4.ip_unprivileged_port_start = ${SYSCTL_IP_UNPRIVILEGED_PORT_START}"
  then
    echo "(not set as needed, setting ...)"
    echo "COMMAND: sudo sysctl net.ipv4.ip_unprivileged_port_start=${SYSCTL_IP_UNPRIVILEGED_PORT_START}"
    sudo sysctl net.ipv4.ip_unprivileged_port_start=${SYSCTL_IP_UNPRIVILEGED_PORT_START}

    if ! grep "net.ipv4.ip_unprivileged_port_start=${SYSCTL_IP_UNPRIVILEGED_PORT_START}" /etc/sysctl.d/*
    then
      echo "(making change persistent ...)"
      echo "COMMAND: sudo echo \"net.ipv4.ip_unprivileged_port_start=${SYSCTL_IP_UNPRIVILEGED_PORT_START}\" >> /etc/sysctl.d/80-gucamole_proxy.conf"
      sudo echo "net.ipv4.ip_unprivileged_port_start=${SYSCTL_IP_UNPRIVILEGED_PORT_START}" >> /etc/sysctl.d/80-gucamole_proxy.conf
    fi
  else
    echo "(set correctly, continuing ...)"
  fi

  # Make sure subuids and subgids are setup
  echo "-Setting subuids/subgids ..."
  echo "COMMAND: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 ${USER}"
  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 ${USER}
  echo
  
  # Activate the changes
  echo "COMMAND: podman system migrate"
  podman system migrate
  echo

  # Create the Guacamole Network(s)
  echo "-Creating required podman network(s) ..."
  for NETWORK in ${GUACAMOLE_NETWORK_LIST}
  do
    echo "COMMAND: podman network create ${NETWORK}"
    podman network create ${NETWORK}
  done
  echo
}

enable_required_systemd_services() {
  echo "======================================================================"
  echo "Enabling/starting required services ..."
  echo "======================================================================"
  echo

  for REQUIRED_SERVICE in ${REQUIRED_SERVICES_LIST}
  do
    echo "COMMAND: sudo systemctl enable --now ${REQUIRED_SERVICE}"
    sudo systemctl enable --now ${REQUIRED_SERVICE}
    echo
  done
}

enable_configure_firewall() {
  echo "======================================================================"
  echo "Making required firewall configurations ..."
  echo "======================================================================"
  echo

  if ! systemctl is-enabled firewalld.service | grep -q enabled
  then
    echo "COMMAND: sudo systemctl enable --now firewalld.service"
    sudo systemctl enable --now firewalld.service
    echo
  fi

  for REQUIRED_FIREWALL_PORT in ${REQUIRED_FIREWALL_PORTS_LIST}
  do
    if ! sudo firewall-cmd --list-all | grep " .ports: " | grep -q ${REQUIRED_FIREWALL_PORT}
    then
      echo "COMMAND: sudo firewall-cmd --add-port=${REQUIRED_FIREWALL_PORT} --permanent"
      sudo firewall-cmd --add-port=${REQUIRED_FIREWALL_PORT} --permanent
      echo
    fi
  done

  for REQUIRED_FIREWALL_SERVICE in ${REQUIRED_FIREWALL_SERVICES_LIST}
  do
    if ! sudo firewall-cmd --list-all | grep " .ports: " | grep -q ${REQUIRED_FIREWALL_SERVICE}
    then
      echo "COMMAND: sudo firewall-cmd --add-service=${REQUIRED_FIREWALL_SERVICE} --permanent"
      sudo firewall-cmd --add-service=${REQUIRED_FIREWALL_SERVICE} --permanent
      echo
    fi
  done

  echo "COMMAND: sudo firewall-cmd --reload"
  sudo firewall-cmd --reload
  echo
}

####  Begin: Add Config to MariaDB  ############################################

set_guacadmin_password() {
  local MARIADB_ROOT_PASSWORD=${GUACDB_PASSWORD}
  local MARIADB_DATABASE=${GUACDB_NAME}

  echo "[Guacadmin User]"
  echo "GUACADMIN_PASSWORD=${GUACADMIN_PASSWORD}"

  cat << EOFGUACADMIN > ${CONFIG_DIR}config-guacadmin.sql
USE guacamole_db;
SET @admin_password = '${GUACADMIN_PASSWORD}';
SET @admin_salt = UNHEX(SHA2(UUID(), 256));
SET @admin_hash = UNHEX(SHA2(CONCAT(@admin_password, HEX(@admin_salt)), 256));
UPDATE guacamole_user
 SET
  password_salt = @admin_salt,
  password_hash = @admin_hash,
  password_date = CURRENT_TIMESTAMP
 WHERE
  user_id = (SELECT entity_id FROM guacamole_entity WHERE name = 'guacadmin' AND type = 'USER');
EOFGUACADMIN

  echo
  case ${GUACAMOLE_DBMS} in
    mariadb|mysql)
      echo "COMMAND: podman cp ${CONFIG_DIR}config-guacadmin.sql guacdb:/config-guacadmin.sql"
      podman cp ${CONFIG_DIR}config-guacadmin.sql guacdb:/config-guacadmin.sql
      echo
  
      echo "COMMAND: podman exec -it guacdb bash -c \"mariadb -u root -p${GUACDB_PASSWORD} ${MARIADB_DATABASE} < /config-guacadmin.sql\""
      podman exec -it guacdb bash -c "mariadb -u root -p${GUACDB_PASSWORD} ${MARIADB_DATABASE} < /config-guacadmin.sql"
    ;;
  esac
  echo
  echo "----------"
}

create_guacamole_users() {
  local MARIADB_ROOT_PASSWORD=${GUACDB_PASSWORD}
  local MARIADB_DATABASE=${GUACDB_NAME}
  
  for GUAC_USER in ${GUAC_USER_LIST}
  do
    local GUAC_USER_NAME="$(echo ${GUAC_USER} | cut -d , -f 1)"
    local GUAC_USER_PASSWD="$(echo ${GUAC_USER} | cut -d , -f 2)"

    echo "[User]"
    echo "GUAC_USER_NAME=${GUAC_USER_NAME}"
    echo "GUAC_USER_PASSWD=${GUAC_USER_PASSWD}"
    echo "GUAC_USER_DEF_FILE=${CONFIG_DIR}config-user-${GUAC_USER_NAME}.sql"
  
    cat << EOFUSER > ${CONFIG_DIR}config-user-${GUAC_USER_NAME}.sql
USE guacamole_db;
SET @new_username = '${GUAC_USER_NAME}';
SET @new_password = '${GUAC_USER_PASSWD}';
INSERT INTO guacamole_entity (name, type) VALUES (@new_username, 'USER');
SET @user_entity_id = LAST_INSERT_ID();
SET @password_salt = UNHEX(SHA2(UUID(), 256));
SET @password_hash = UNHEX(SHA2(CONCAT(@new_password, HEX(@password_salt)), 256));
INSERT INTO guacamole_user (entity_id, password_salt, password_hash, password_date)
 VALUES (@user_entity_id, @password_salt, @password_hash, CURRENT_TIMESTAMP);
EOFUSER

    echo
    case ${GUACAMOLE_DBMS} in
      mariadb|mysql)
        echo "COMMAND: podman cp ${CONFIG_DIR}config-user-${GUAC_USER_NAME}.sql guacdb:/config-user-${GUAC_USER_NAME}.sql"
        podman cp ${CONFIG_DIR}config-user-${GUAC_USER_NAME}.sql guacdb:/config-user-${GUAC_USER_NAME}.sql
        echo
  
        echo "COMMAND: podman exec -it guacdb bash -c \"mariadb -u root -p${GUACDB_PASSWORD} ${MARIADB_DATABASE} < /config-user-${GUAC_USER_NAME}.sql\""
        podman exec -it guacdb bash -c "mariadb -u root -p${GUACDB_PASSWORD} ${MARIADB_DATABASE} < /config-user-${GUAC_USER_NAME}.sql"
      ;;
    esac
    echo
    echo "----------"
  done
}

create_rdp_connections() {
  local MARIADB_ROOT_PASSWORD=${GUACDB_PASSWORD}
  local MARIADB_DATABASE=${GUACDB_NAME}
  
  for RDP_CONNECTION in ${RDP_CONNECTION_LIST}
  do
    local RDP_CONNECTION_NAME="$(echo ${RDP_CONNECTION} | cut -d , -f 1)"
    local RDP_CONNECTION_HOST="$(echo ${RDP_CONNECTION} | cut -d , -f 2)"
    local RDP_CONNECTION_USERNAME="$(echo ${RDP_CONNECTION} | cut -d , -f 3)"
    local RDP_CONNECTION_PASSWORD="$(echo ${RDP_CONNECTION} | cut -d , -f 4)"
    
    echo "[RDP Connection]"
    echo "RDP_CONNECTION_NAME=${RDP_CONNECTION_NAME}"
    echo "RDP_CONNECTION_HOST=${RDP_CONNECTION_HOST}"
    echo "RDP_CONNECTION_USERNAME=${RDP_CONNECTION_USERNAME}"
    echo "RDP_CONNECTION_PASSWORD=${RDP_CONNECTION_PASSWORD}"
    echo "RDP_CONNECTION_DEF_FILE=${CONFIG_DIR}config-connection-rdp-${RDP_CONNECTION_NAME}.sql"
  
    cat << EOFCONNECTIONRDP > ${CONFIG_DIR}config-connection-rdp-${RDP_CONNECTION_NAME}.sql
USE guacamole_db;
SET @connection_name = '${RDP_CONNECTION_NAME}';
SET @protocol = 'rdp';
SET @hostname = '${RDP_CONNECTION_HOST}';
SET @port = '3389';
SET @username = '${RDP_CONNECTION_USERNAME}';
SET @password = '${RDP_CONNECTION_PASSWORD}';
INSERT INTO guacamole_connection (connection_name, protocol) VALUES (@connection_name, @protocol);
SET @connection_entity_id = LAST_INSERT_ID();
INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
 VALUES
  (@connection_entity_id, 'hostname', @hostname),
  (@connection_entity_id, 'port', @port),
  (@connection_entity_id, 'username', @username),
  (@connection_entity_id, 'password', @password),
  (@connection_entity_id, 'ignore-cert', 'true');
EOFCONNECTIONRDP

    echo
    case ${GUACAMOLE_DBMS} in
      mariadb|mysql)
        echo "COMMAND: podman cp ${CONFIG_DIR}config-connection-rdp-${RDP_CONNECTION_NAME}.sql guacdb:/config-connection-rdp-${RDP_CONNECTION_NAME}.sql"
        podman cp ${CONFIG_DIR}config-connection-rdp-${RDP_CONNECTION_NAME}.sql guacdb:/config-connection-rdp-${RDP_CONNECTION_NAME}.sql
        echo
  
        echo "COMMAND: podman exec -it guacdb bash -c \"mariadb -u root -p${GUACDB_PASSWORD} ${MARIADB_DATABASE} < /config-connection-rdp-${RDP_CONNECTION_NAME}.sql\""
        podman exec -it guacdb bash -c "mariadb -u root -p${GUACDB_PASSWORD} ${MARIADB_DATABASE} < /config-connection-rdp-${RDP_CONNECTION_NAME}.sql"
      ;;
    esac
    echo
    echo "----------"
  done
}

create_ssh_connections() {
  local MARIADB_ROOT_PASSWORD=${GUACDB_PASSWORD}
  local MARIADB_DATABASE=${GUACDB_NAME}
  
  for SSH_CONNECTION in ${SSH_CONNECTION_LIST}
  do
    local SSH_CONNECTION_NAME="$(echo ${SSH_CONNECTION} | cut -d , -f 1)"
    local SSH_CONNECTION_HOST="$(echo ${SSH_CONNECTION} | cut -d , -f 2)"
    local SSH_CONNECTION_USERNAME="$(echo ${SSH_CONNECTION} | cut -d , -f 3)"
    local SSH_CONNECTION_PASSWORD="$(echo ${SSH_CONNECTION} | cut -d , -f 4)"
    
    echo "[SSH Connection]"
    echo "SSH_CONNECTION_NAME=${SSH_CONNECTION_NAME}"
    echo "SSH_CONNECTION_HOST=${SSH_CONNECTION_HOST}"
    echo "SSH_CONNECTION_USERNAME=${SSH_CONNECTION_USERNAME}"
    echo "SSH_CONNECTION_PASSWORD=${SSH_CONNECTION_PASSWORD}"
    echo "SSH_CONNECTION_DEF_FILE=${CONFIG_DIR}config-connection-ssh-${SSH_CONNECTION_NAME}.sql"
    
  cat << EOFCONNECTIONSSH > ${CONFIG_DIR}config-connection-ssh-${SSH_CONNECTION_NAME}.sql
USE guacamole_db;
SET @connection_name = '${SSH_CONNECTION_NAME}';
SET @protocol = 'ssh';
SET @hostname = '${SSH_CONNECTION_HOST}';
SET @port = '22';
SET @username = '${SSH_CONNECTION_USERNAME}';
SET @password = '${SSH_CONNECTION_PASSWORD}';
INSERT INTO guacamole_connection (connection_name, protocol) VALUES (@connection_name, @protocol);
SET @connection_entity_id = LAST_INSERT_ID();
INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
 VALUES
  (@connection_entity_id, 'hostname', @hostname),
  (@connection_entity_id, 'port', @port),
  (@connection_entity_id, 'username', @username),
  (@connection_entity_id, 'password', @password),
  (@connection_entity_id, 'enable-sftp', 'true');
EOFCONNECTIONSSH

    echo
    case ${GUACAMOLE_DBMS} in
      mariadb|mysql)
        echo "COMMAND: podman cp ${CONFIG_DIR}config-connection-ssh-${SSH_CONNECTION_NAME}.sql guacdb:/config-connection-ssh-${SSH_CONNECTION_NAME}.sql"
        podman cp ${CONFIG_DIR}config-connection-ssh-${SSH_CONNECTION_NAME}.sql guacdb:/config-connection-ssh-${SSH_CONNECTION_NAME}.sql
        echo
  
        echo "COMMAND: podman exec -it guacdb bash -c \"mariadb -u root -p${GUACDB_PASSWORD} ${MARIADB_DATABASE} < /config-connection-ssh-${SSH_CONNECTION_NAME}.sql\""
        podman exec -it guacdb bash -c "mariadb -u root -p${GUACDB_PASSWORD} ${MARIADB_DATABASE} < /config-connection-ssh-${SSH_CONNECTION_NAME}.sql"
      ;;
    esac
    echo
    echo "----------"
  done
}

create_user_to_connection_mappings() {
  for USER_CONNECTION_MAPPING in ${USER_CONNECTION_MAPPING_LIST}
  do
    local USER_ENTITY=$(echo ${USER_CONNECTION_MAPPING} | cut -d , -f 1)
    local CONNECTION_ENTITY=$(echo ${USER_CONNECTION_MAPPING} | cut -d , -f 2)

    echo "[User to Connection Mapping]"
    echo "CONNECTION_MAPPING: ${USER_ENTITY}->${CONNECTION_ENTITY}"
    echo "CONNECTION_MAPPING_DEF_FILE=${CONFIG_DIR}config-connection-mapping-${USER_ENTITY}-${CONNECTION_ENTITY}.sql"
  
  cat << EOFCONNECTIONMAPPING > ${CONFIG_DIR}config-connection-mapping-${USER_ENTITY}-${CONNECTION_ENTITY}.sql
USE guacamole_db;
SET @user_entity_id = (
  SELECT entity_id
  FROM guacamole_entity
  WHERE name = '${USER_ENTITY}'
  AND type = 'USER');
SET @connection_entity_id = (
  SELECT connection_id
  FROM guacamole_connection
  WHERE connection_name = '${CONNECTION_ENTITY}');
INSERT INTO guacamole_connection_permission (entity_id, connection_id, permission)
 VALUES (@user_entity_id, @connection_entity_id, 'READ');
EOFCONNECTIONMAPPING

    echo
    case ${GUACAMOLE_DBMS} in
      mariadb|mysql)
        echo "COMMAND: podman cp ${CONFIG_DIR}config-connection-mapping-${USER_ENTITY}-${CONNECTION_ENTITY}.sql guacdb:/config-connection-mapping-${USER_ENTITY}-${CONNECTION_ENTITY}.sql"
        podman cp ${CONFIG_DIR}config-connection-mapping-${USER_ENTITY}-${CONNECTION_ENTITY}.sql guacdb:/config-connection-mapping-${USER_ENTITY}-${CONNECTION_ENTITY}.sql
        echo
  
        echo "COMMAND: podman exec -it guacdb bash -c \"mariadb -u root -p${GUACDB_PASSWORD} ${MARIADB_DATABASE} < /config-connection-mapping-${USER_ENTITY}-${CONNECTION_ENTITY}.sql\""
        podman exec -it guacdb bash -c "mariadb -u root -p${GUACDB_PASSWORD} ${MARIADB_DATABASE} < /config-connection-mapping-${USER_ENTITY}-${CONNECTION_ENTITY}.sql"
      ;;
    esac
    echo
    echo "----------"
  done
}

clear_guacamole_histories() {
  cat << EOF > ${CONFIG_DIR}config-clear-history.sql
USE guacamole_db;
DELETE FROM guacamole_connection_history;
DELETE FROM guacamole_user_history;
EOF

  echo
  case ${GUACAMOLE_DBMS} in
    mariadb|mysql)
      echo "COMMAND: podman cp ${CONFIG_DIR}config-clear-history.sql guacdb:/config-clear-history.sql"
      podman cp ${CONFIG_DIR}config-clear-history.sql guacdb:/config-clear-history.sql
      echo
  
      echo "COMMAND: podman exec -it guacdb bash -c \"mariadb -u root -p${GUACDB_PASSWORD} ${MARIADB_DATABASE} < /config-clear-history.sql\""
      podman exec -it guacdb bash -c "mariadb -u root -p${GUACDB_PASSWORD} ${MARIADB_DATABASE} < /config-clear-history.sql"
    ;;
  esac
  echo
}

configure_guacamole_database() {
  echo "Configuring the Guacamole Database ..."
  echo

  echo "COMMAND: podman cp ${CONFIG_DIR}config.sql guacdb:/config.sql"
  podman cp ${CONFIG_DIR}config.sql guacdb:/config.sql
  echo

  case ${GUACAMOLE_DBMS} in
    mariadb|mysql)
      echo "COMMAND: podman exec -it guacdb bash -c \"mariadb -u root -p${GUACDB_PASSWORD} ${MARIADB_DATABASE} < /config.sql\""
      podman exec -it guacdb bash -c "mariadb -u root -p${GUACDB_PASSWORD} ${MARIADB_DATABASE} < /config.sql"
      echo
      echo "COMMAND: podman exec guacdb bash -c 'rm $HOME/.mariadb_history'"
      podman exec guacdb bash -c 'rm $HOME/.mariadb_history'
    ;;
  esac
}

#
#
####  End: Add Config to MariaDB  ##############################################

####  Begin: Launch Container Functions  #######################################
#
#

launch_guacdb_container_mariadb() {
  local MARIADB_ROOT_PASSWORD=${GUACDB_PASSWORD}
  local MARIADB_DATABASE=${GUACDB_NAME}
  local MARIADB_USER=${GUACDB_USER}
  local MARIADB_PASSWORD=${GUACDB_PASSWORD}

  echo "[guacdb (mariadb)]"
  echo "COMMAND: podman run -d --name guacdb \
    -v ${PODMAN_DIR}/mariadb/data:/var/lib/mysql \
    -v /etc/localtime:/etc/localtime:ro \
    -e MARIADB_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD} \
    -e MARIADB_DATABASE=${MARIADB_DATABASE} \
    -e MARIADB_USER=${MARIADB_USER} \
    -e MARIADB_PASSWORD=${MARIADB_PASSWORD} \
    --network=${GUACAMOLE_NETWORK} \
    ${MARIADB_CONTAINER_IMAGE}"
  echo
  podman run -d --name guacdb \
    -v ${PODMAN_DIR}/mariadb/data:/var/lib/mysql \
    -v /etc/localtime:/etc/localtime:ro \
    -e MARIADB_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD} \
    -e MARIADB_DATABASE=${MARIADB_DATABASE} \
    -e MARIADB_USER=${MARIADB_USER} \
    -e MARIADB_PASSWORD=${MARIADB_PASSWORD} \
    --network=${GUACAMOLE_NETWORK} \
    ${MARIADB_CONTAINER_IMAGE}
  echo

  wait_for "podman exec guacdb mariadb-admin -h localhost -u root -p${MARIADB_ROOT_PASSWORD} ping" "Trying to connect to the database"
  sleep 5
  echo

  echo "Initializing the Guacamole database ..."
  echo

  echo "COMMAND: podman cp initdb.sql guacdb:/initdb.sql"
  podman cp initdb.sql guacdb:/initdb.sql
  echo

  echo "COMMAND: podman exec -it guacdb bash -c \"mariadb -u root -p${MARIADB_ROOT_PASSWORD} ${MARIADB_DATABASE} < /initdb.sql\""
  podman exec -it guacdb bash -c "mariadb -u root -p${MARIADB_ROOT_PASSWORD} ${MARIADB_DATABASE} < /initdb.sql"
  echo
}

launch_guacdb_container_postgresql() {
  echo "[guacdb (postgresql)]"
  echo "COMMAND: podman run -d --name guacdb \
    -v ${PODMAN_DIR}/postgresql/init:/docker-entrypoint-initdb.d \
    -v ${PODMAN_DIR}/postgresql/data:/var/lib/postgresql/data \
    -v /etc/localtime:/etc/localtime:ro \
    -e POSTGRES_USER=${GUACDB_USER} \
    -e POSTGRES_PASSWORD=${GUACDB_PASSWORD} \
    -e POSTGRES_DB=${GUACDB_NAME} \
    --network=${GUACAMOLE_NETWORK} \
    ${POSTGRESQL_CONTAINER_IMAGE}"
  echo
  podman run -d --name guacdb \
    -v ${PODMAN_DIR}/postgresql/init:/docker-entrypoint-initdb.d \
    -v ${PODMAN_DIR}/postgresql/data:/var/lib/postgresql/data \
    -v /etc/localtime:/etc/localtime:ro \
    -e POSTGRES_USER=${GUACDB_USER} \
    -e POSTGRES_PASSWORD=${GUACDB_ROOT_PASSWORD} \
    -e POSTGRES_DB=${GUACDB_NAME} \
    --network=${GUACAMOLE_NETWORK} \
    ${POSTGRESQL_CONTAINER_IMAGE}
  echo
}

launch_guacd_container() {
  echo "[guacd]"
  echo "COMMAND: podman run -d --name guacd \
    -v /etc/localtime:/etc/localtime:ro \
    -v ${PODMAN_DIR}/guacd/records:/record \
    -v ${PODMAN_DIR}/guacd/drive:/drive \
    --network=${GUACAMOLE_NETWORK} \
    ${GUACD_CONTAINER_IMAGE}"
  echo
  podman run -d --name guacd \
    -v /etc/localtime:/etc/localtime:ro \
    -v ${PODMAN_DIR}/guacd/records:/record \
    -v ${PODMAN_DIR}/guacd/drive:/drive \
    --network=${GUACAMOLE_NETWORK} \
    ${GUACD_CONTAINER_IMAGE}
  echo
}

launch_guacamole_container_with_postgresql() {
  echo "[guacamole]"
  case ${GUACAMOLE_WEBAPP_CONTEXT} in
    ROOT)
      echo "COMMAND: podman run -d --name guacamole \
        -e GUACD_HOSTNAME=guacd \
        -e GUACD_PORT=4822 \
        -e WEBAPP_CONTEXT=ROOT \
        -e RECORDING_ENABLED=true \
        -e REMOTE_IP_VALVE_ENABLED=true \
        -e POSTGRESQL_HOSTNAME=guacdb \
        -e POSTGRESQL_DATABASE=${GUACDB_NAME} \
        -e POSTGRESQL_USER=${GUACDB_USER} \
        -e POSTGRESQL_PASSWORD=${GUACDB_ROOT_PASSWORD} \
        -v /etc/localtime:/etc/localtime:ro \
        -v ${PODMAN_DIR}/guacamole/home:/etc/guacamole \
        -p ${GUACAMOLE_EXTERNAL_PORT}:${GUACAMOLE_INTERNAL_PORT} \
        --requires=guacd,guacd \
        --network=${GUACAMOLE_NETWORK} \
        ${GUACAMOLE_CONTAINER_IMAGE}"
      echo
      podman run -d --name guacamole \
        -e GUACD_HOSTNAME=guacd \
        -e GUACD_PORT=4822 \
        -e WEBAPP_CONTEXT=ROOT \
        -e RECORDING_ENABLED=true \
        -e REMOTE_IP_VALVE_ENABLED=true \
        -e POSTGRESQL_HOSTNAME=guacdb \
        -e POSTGRESQL_DATABASE=${GUACDB_NAME} \
        -e POSTGRESQL_USER=${GUACDB_USER} \
        -e POSTGRESQL_PASSWORD=${GUACDB_ROOT_PASSWORD} \
        -v /etc/localtime:/etc/localtime:ro \
        -v ${PODMAN_DIR}/guacamole/home:/etc/guacamole \
        -p ${GUACAMOLE_EXTERNAL_PORT}:${GUACAMOLE_INTERNAL_PORT} \
        --requires=guacd,guacd \
        --network=${GUACAMOLE_NETWORK} \
        ${GUACAMOLE_CONTAINER_IMAGE}
      echo
    ;;
    *)
      echo "COMMAND: podman run -d --name guacamole \
        -e GUACD_HOSTNAME=guacd \
        -e GUACD_PORT=4822 \
        -e RECORDING_ENABLED=true \
        -e REMOTE_IP_VALVE_ENABLED=true \
        -e POSTGRESQL_HOSTNAME=guacdb \
        -e POSTGRESQL_DATABASE=${GUACDB_NAME} \
        -e POSTGRESQL_USER=${GUACDB_USER} \
        -e POSTGRESQL_PASSWORD=${GUACDB_ROOT_PASSWORD} \
        -v /etc/localtime:/etc/localtime:ro \
        -v ${PODMAN_DIR}/guacamole/home:/etc/guacamole \
        -p ${GUACAMOLE_EXTERNAL_PORT}:${GUACAMOLE_INTERNAL_PORT} \
        --requires=guacd,guacd \
        --network=${GUACAMOLE_NETWORK} \
        ${GUACAMOLE_CONTAINER_IMAGE}"
      echo
      podman run -d --name guacamole \
        -e GUACD_HOSTNAME=guacd \
        -e GUACD_PORT=4822 \
        -e RECORDING_ENABLED=true \
        -e REMOTE_IP_VALVE_ENABLED=true \
        -e POSTGRESQL_HOSTNAME=guacdb \
        -e POSTGRESQL_DATABASE=${GUACDB_NAME} \
        -e POSTGRESQL_USER=${GUACDB_USER} \
        -e POSTGRESQL_PASSWORD=${GUACDB_ROOT_PASSWORD} \
        -v /etc/localtime:/etc/localtime:ro \
        -v ${PODMAN_DIR}/guacamole/home:/etc/guacamole \
        -p ${GUACAMOLE_EXTERNAL_PORT}:${GUACAMOLE_INTERNAL_PORT} \
        --requires=guacd,guacd \
        --network=${GUACAMOLE_NETWORK} \
        ${GUACAMOLE_CONTAINER_IMAGE}
      echo
    ;;
  esac
}

launch_guacamole_container_with_mariadb() {
  echo "[guacamole]"
  case ${GUACAMOLE_WEBAPP_CONTEXT} in
    ROOT)
      echo "COMMAND: podman run -d --name guacamole \
        -e GUACD_HOSTNAME=guacd \
        -e GUACD_PORT=4822 \
        -e WEBAPP_CONTEXT=ROOT \
        -e RECORDING_ENABLED=true \
        -e REMOTE_IP_VALVE_ENABLED=true \
        -e MYSQL_ENABLED=true \
        -e MYSQL_HOSTNAME=guacdb \
        -e MYSQL_DATABASE=${GUACDB_NAME} \
        -e MYSQL_USERNAME=${GUACDB_USER} \
        -e MYSQL_PASSWORD=${GUACDB_PASSWORD} \
        -v /etc/localtime:/etc/localtime:ro \
        -v ${PODMAN_DIR}/guacamole/home:/etc/guacamole \
        -p ${GUACAMOLE_EXTERNAL_PORT}:${GUACAMOLE_INTERNAL_PORT} \
        --requires=guacd,guacd \
        --network=${GUACAMOLE_NETWORK} \
        ${GUACAMOLE_CONTAINER_IMAGE}"
      echo
      podman run -d --name guacamole \
        -e GUACD_HOSTNAME=guacd \
        -e GUACD_PORT=4822 \
        -e WEBAPP_CONTEXT=ROOT \
        -e RECORDING_ENABLED=true \
        -e REMOTE_IP_VALVE_ENABLED=true \
        -e MYSQL_ENABLED=true \
        -e MYSQL_HOSTNAME=guacdb \
        -e MYSQL_DATABASE=${GUACDB_NAME} \
        -e MYSQL_USERNAME=${GUACDB_USER} \
        -e MYSQL_PASSWORD=${GUACDB_PASSWORD} \
        -v /etc/localtime:/etc/localtime:ro \
        -v ${PODMAN_DIR}/guacamole/home:/etc/guacamole \
        -p ${GUACAMOLE_EXTERNAL_PORT}:${GUACAMOLE_INTERNAL_PORT} \
        --requires=guacd,guacd \
        --network=${GUACAMOLE_NETWORK} \
        ${GUACAMOLE_CONTAINER_IMAGE}
      echo
    ;;
    *)
      echo "COMMAND: podman run -d --name guacamole \
        -e GUACD_HOSTNAME=guacd \
        -e GUACD_PORT=4822 \
        -e RECORDING_ENABLED=true \
        -e REMOTE_IP_VALVE_ENABLED=true \
        -e MYSQL_ENABLED=true \
        -e MYSQL_HOSTNAME=guacdb \
        -e MYSQL_DATABASE=${GUACDB_NAME} \
        -e MYSQL_USERNAME=${GUACDB_USER} \
        -e MYSQL_PASSWORD=${GUACDB_PASSWORD} \
        -v /etc/localtime:/etc/localtime:ro \
        -v ${PODMAN_DIR}/guacamole/home:/etc/guacamole \
        -p ${GUACAMOLE_EXTERNAL_PORT}:${GUACAMOLE_INTERNAL_PORT} \
        --requires=guacd,guacd \
        --network=${GUACAMOLE_NETWORK} \
        ${GUACAMOLE_CONTAINER_IMAGE}"
      echo
      podman run -d --name guacamole \
        -e GUACD_HOSTNAME=guacd \
        -e GUACD_PORT=4822 \
        -e RECORDING_ENABLED=true \
        -e REMOTE_IP_VALVE_ENABLED=true \
        -e MYSQL_ENABLED=true \
        -e MYSQL_HOSTNAME=guacdb \
        -e MYSQL_DATABASE=${GUACDB_NAME} \
        -e MYSQL_USERNAME=${GUACDB_USER} \
        -e MYSQL_PASSWORD=${GUACDB_PASSWORD} \
        -v /etc/localtime:/etc/localtime:ro \
        -v ${PODMAN_DIR}/guacamole/home:/etc/guacamole \
        -p ${GUACAMOLE_EXTERNAL_PORT}:${GUACAMOLE_INTERNAL_PORT} \
        --requires=guacd,guacd \
        --network=${GUACAMOLE_NETWORK} \
        ${GUACAMOLE_CONTAINER_IMAGE}
      echo
    ;;
  esac
}

launch_guacamole_proxy_container() {
  echo "[guacamole_proxy]"
  echo "COMMAND: podman run -d --name guacamole_proxy \
    -v ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d:/etc/nginx/conf.d \
    --requires=guacamole \
    ${GUACAMOLE_PROXY_EXPOSED_PORTS_STRING} \
    --network=${GUACAMOLE_NETWORK} \
    ${NGINX_CONTAINER_IMAGE}"
  echo
  podman run -d --name guacamole_proxy \
    -v ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d:/etc/nginx/conf.d \
    --requires=guacamole \
    ${GUACAMOLE_PROXY_EXPOSED_PORTS_STRING} \
    --network=${GUACAMOLE_NETWORK} \
    ${NGINX_CONTAINER_IMAGE}
    #-p ${NGINX_TLS_PORT}:${NGINX_TLS_PORT} -p 443:443 -p 80:80 \
  echo
}

#
#
####  End: Launch Container Functions  ########################################

enable_guacamole_systemd_services() {
  echo "======================================================================"
  echo "Enabling Systemd services ..."
  echo "======================================================================"
  echo

  # Make sure linger is enabled for the user ${USER} so that we can have the containers start at bootup
  echo "COMMAND: loginctl enable-linger ${USER}"
  loginctl enable-linger ${USER}
  echo

  echo "COMMAND: loginctl show-user ${USER}"
  loginctl show-user ${USER}
  echo

  # Create the folder for the container service files
  echo "COMMAND: mkdir -p ~/.config/systemd/user"  
  mkdir -p ~/.config/systemd/user
  echo

  echo "COMMAND: cd ~/.config/systemd/user"
  cd ~/.config/systemd/user
  echo

  # Create the container service files
  echo "COMMAND: podman generate systemd --files --name guacdb > /dev/null 2>&1"
  podman generate systemd --files --name guacdb > /dev/null 2>&1
  echo

  echo "COMMAND: podman generate systemd --files --name guacd > /dev/null 2>&1"
  podman generate systemd --files --name guacd > /dev/null 2>&1
  echo

  echo "COMMAND: podman generate systemd --files --name guacamole > /dev/null 2>&1"
  podman generate systemd --files --name guacamole > /dev/null 2>&1
  echo

  echo "COMMAND: podman generate systemd --files --name guacamole_proxy > /dev/null 2>&1"
  podman generate systemd --files --name guacamole_proxy > /dev/null 2>&1
  echo

  echo "COMMAND: cd ~"
  cd ~
  echo

  # Reload systemctl user daemon so that the newly created service files are seen by systemd
  echo "COMMAND: systemctl --user daemon-reload > /dev/null 2>&1"
  systemctl --user daemon-reload > /dev/null 2>&1
  echo

  # Enable the container service files so that containers will start at boot
  echo "COMMAND: systemctl --user enable container-guacdb.service > /dev/null 2>&1"
  systemctl --user enable container-guacdb.service > /dev/null 2>&1
  echo

  echo "COMMAND: systemctl --user enable container-guacd.service > /dev/null 2>&1"
  systemctl --user enable container-guacd.service > /dev/null 2>&1
  echo

  echo "COMMAND: systemctl --user enable container-guacamole.service > /dev/null 2>&1"
  systemctl --user enable container-guacamole.service > /dev/null 2>&1
  echo

  echo "COMMAND: systemctl --user enable container-guacamole_proxy.service > /dev/null 2>&1"
  systemctl --user enable container-guacamole_proxy.service > /dev/null 2>&1
  echo
}

show_status_of_containers() {
  local PODMAN_SERVICE_LIST="container-guacdb.service container-guacd.service container-guacamole.service container-guacamole_proxy.service"

  for PODMAN_SERVICE in ${PODMAN_SERVICE_LIST}
  do
    echo "====================================================================="
    echo "Service: ${PODMAN_SERVICE}"
    echo "====================================================================="
    echo "COMMAND: systemctl --user status ${PODMAN_SERVICE}"
    echo "---------------------------------------------------------------------"
    systemctl --user status ${PODMAN_SERVICE}
    echo
  done
  
  echo "====================================================================="
  echo "COMMAND: podman ps"
  echo "---------------------------------------------------------------------"
  podman ps
  echo
}

###############################################################################
# Do It Functions
###############################################################################

create_guacamole_config_only() {
  echo "######################################################################"
  echo "               Generating Guacamole Configuration"
  echo "######################################################################"
  echo

  source_in_config_files
  install_required_packages
  generate_base_initdb_file
  generate_tls_certificate
  create_nginx_proxy_config

  create_guacd_required_folders_and_files
  create_guacamole_required_folders_and_files
  case ${GUACAMOLE_DBMS} in
    postgresql)
      create_postgress_required_folders_and_files
    ;;
    mariadb|myqsl)
      create_mariadb_required_folders_and_files
    ;;
  esac
  create_guacamole_proxy_required_files_and_folders
  copy_certificate_into_proxy_volume
  change_podman_dir_permissions_and_ownership

  set_guacadmin_password
  create_rdp_connections
  create_ssh_connections
  create_guacamole_users
  create_user_to_connection_mappings
  clear_guacamole_histories
  echo
  echo
  echo "######################################################################"
  echo "    Guacamole configuration has been generated under ${PODMAN_DIR}"
  echo "      -Containers have not been downloaded or started"
  echo "######################################################################"
  echo
}

rotate_reverse_proxy_certificate() {
  echo "######################################################################"
  echo "           Rotating Guacamole Reverse Proxy Certificates"
  echo "######################################################################"
  echo

  source_in_config_files

  echo "COMMAND: rm ${CONFIG_DIR}cert.pem"
  rm ${CONFIG_DIR}cert.pem
  echo

  echo "COMMAND: rm ${CONFIG_DIR}key.pem"
  rm ${CONFIG_DIR}key.pem
  echo

  echo "COMMAND: rm ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d/server.crt"
  rm ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d/server.crt
  echo

  echo "COMMAND: rm ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d/server.key"
  rm ${PODMAN_DIR}/guacamole_proxy/etc/nginx/conf.d/server.key
  echo
  generate_tls_certificate
  copy_certificate_into_proxy_volume
  change_podman_dir_permissions_and_ownership

  echo "COMMAND: podman container stop guacamole_proxy"
  podman container stop guacamole_proxy
  
  echo "COMMAND: podman container start guacamole_proxy"
  podman container start guacamole_proxy
    
  echo
  echo
  echo "######################################################################"
  echo "           Reverse Proxy certificates have been rotated"
  echo "######################################################################"
  echo
}
  
install_guacamole() {
  echo "######################################################################"
  echo "              Installing and Configuring Guacamole"
  echo "######################################################################"
  echo

  #----  Retrieve/create config and required folders  ----#
  source_in_config_files
  generate_base_initdb_file
  generate_tls_certificate
  create_nginx_proxy_config
  create_guacd_required_folders_and_files
  create_guacamole_required_folders_and_files
  case ${GUACAMOLE_DBMS} in
    postgresql)
      create_postgress_required_folders_and_files
    ;;
    mariadb|myqsl)
      create_mariadb_required_folders_and_files
    ;;
  esac
  create_guacamole_proxy_required_files_and_folders
  copy_certificate_into_proxy_volume
  change_podman_dir_permissions_and_ownership

  #----  Configure the host system  ----#
  install_required_packages
  update_hosts_file
  configure_host_for_podman
  enable_required_systemd_services
  case ${FIREWALL_ENABLED} in
    true|TRUE|True|T|Yes|yes|y|Y)
      enable_configure_firewall
    ;;
  esac

  echo "======================================================================"
  echo "Starting containers ..."
  echo "======================================================================"
  echo
  #----  Launch/Configure Database Container  ----#
  case ${GUACAMOLE_DBMS} in
    postgresql)
      launch_guacdb_container_postgresql
    ;;
    mariadb|myqsl)
      launch_guacdb_container_mariadb
    ;;
  esac

  echo "---------------------------------------------------------------------"
  echo "Creating Users and Connections"
  echo "---------------------------------------------------------------------"
  set_guacadmin_password
  create_rdp_connections
  create_ssh_connections
  create_guacamole_users
  create_user_to_connection_mappings
  clear_guacamole_histories

  #configure_guacamole_database
  echo "---------------------------------------------------------------------"

  #----  Launch Guacamole Containers  ----#
  launch_guacd_container
  case ${GUACAMOLE_DBMS} in
    postgresql)
      launch_guacamole_container_with_postgresql
    ;;
    mariadb|myqsl)
      launch_guacamole_container_with_mariadb
    ;;
  esac

  #----  Launch Reverse Proxy Container  ----#
  launch_guacamole_proxy_container

  #----  Systemd services  ----#
  enable_guacamole_systemd_services

  show_status_of_containers

  echo
  echo
  echo "######################################################################"
  echo "     Guacamole is successfully configured, installed and running"
  echo "######################################################################"
  echo
}

remove_guacamole() {
  echo "######################################################################"
  echo "                        Removing Guacamole"
  echo "######################################################################"
  echo

  source_in_config_files

  echo "========================================================================"
  echo "Stopping and removing Podman containers, networks, etc. ..."
  echo "========================================================================"
  echo

  # Stop all Guacamole containers
  for GUACAMOLE_CONTAINER in ${GUACAMOLE_CONTAINER_LIST}
  do
    echo "COMMAND: podman stop ${GUACAMOLE_CONTAINER}"
    podman stop ${GUACAMOLE_CONTAINER}
    echo
 
    # Remove all of the Guacamole containers
    echo "COMMAND: podman rm ${GUACAMOLE_CONTAINER}"
    podman rm ${GUACAMOLE_CONTAINER}
    echo
  done

  # Remove all of the artifacts
  echo "COMMAND: podman system prune -af"
  podman system prune -af
  echo

  echo "========================================================================"
  echo "Disabling Systemd services ..."
  echo "========================================================================"
  echo

  echo "COMMAND: systemctl --user disable container-guacdb.service > /dev/null 2>&1"
  systemctl --user disable container-guacdb.service > /dev/null 2>&1
  echo

  echo "COMMAND: systemctl --user disable container-guacd.service > /dev/null 2>&1"
  systemctl --user disable container-guacd.service > /dev/null 2>&1
  echo

  echo "COMMAND: systemctl --user disable container-guacamole.service > /dev/null 2>&1"
  systemctl --user disable container-guacamole.service > /dev/null 2>&1
  echo

  # FIXME: Does this need to be more specific about which user unit files are
  #        removed so that other potential user unit files are preserved?
  echo "COMMAND: sudo rm -rf ~/.config/systemd/user"
  sudo rm -rf ~/.config/systemd/user
  echo

  echo "COMMAND: systemctl --user daemon-reload > /dev/null 2>&1"
  systemctl --user daemon-reload > /dev/null 2>&1
  echo

  echo "========================================================================"
  echo "Removing Podman folders ..."
  echo "========================================================================"
  echo

  echo "COMMAND: sudo rm -rf ${PODMAN_DIR}"
  sudo rm -rf ${PODMAN_DIR}
  echo

  echo
  echo "######################################################################"
  echo "                   Guacamole has been removed"
  echo "######################################################################"
  echo
}

stop_guacamole() {
  echo "========================================================================"
  echo "Stopping Podman Containers and Networks..."
  echo "========================================================================"
  echo

  for CONTAINER in ${GUACAMOLE_CONTAINER_LIST}
  do
    echo "COMMAND: podman container stop ${CONTAINER}"
    podman container stop ${CONTAINER}
  done
    echo

  for NETWORK in ${GUACAMOLE_NETWORK_LIST}
  do
    echo "COMMAND: podman network rm ${NETWORK}"
    podman network rm ${NETWORK}
  done
  echo
}

start_guacamole() {
  echo "========================================================================"
  echo "Starting Podman Containers and Networks..."
  echo "========================================================================"
  echo

  for NETWORK in ${GUACAMOLE_NETWORK_LIST}
  do
    echo "COMMAND: podman network create ${NETWORK}"
    podman network create ${NETWORK}
  done
  echo

  for CONTAINER in ${GUACAMOLE_CONTAINER_LIST}
  do
    echo "COMMAND: podman container start ${CONTAINER}"
    podman container start ${CONTAINER}
  done
  echo
}
  
status_guacamole() {
  echo
  show_status_of_containers
}

##############################################################################
# Main Code Body
##############################################################################

case ${1} in
  create_config_only)
    #CREATE_CONFIG_ONLY=true
    create_guacamole_config_only
  ;;
  install)
    install_guacamole
  ;;
  remove|uninstall)
    remove_guacamole
  ;;
  stop)
    stop_guacamole
  ;;
  start)
    start_guacamole
  ;;
  restart)
    stop_guacamole
    start_guacamole
  ;;
  status)
    status_guacamole
  ;;
  rotate_certs|rotate_cert)
    rotate_reverse_proxy_certificate
  ;;
  *)
    usage
    exit
  ;;
esac
