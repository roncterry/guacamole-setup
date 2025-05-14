#!/bin/bash
# This script will setup Guacamole on the host on which it is run.

##############################################################################
# Set Variables
##############################################################################

MAIN_CONFIG_FILE=guacamole-setup.cfg
USERS_CONNECTIONS_CONFIG_FILE=users_connections.cfg
INITDB_BASE_FILE=initdb_base.sql

DEFAULT_MAIN_CONFIG_FILE=https://raw.githubusercontent.com/roncterry/guacamole-setup/refs/heads/main/guacamole-setup.cfg
DEFAULT_USERS_CONNECTIONS_CONFIG_URL=https://raw.githubusercontent.com/roncterry/guacamole-setup/refs/heads/main/users_connections.cfg
DEFAULT_INITDB_BASE_URL=https://raw.githubusercontent.com/roncterry/guacamole-setup/refs/heads/main/initdb_base.sql

##############################################################################

export EXTERNAL_NIC=$(ip route show | grep "^default" | awk '{ print $5 }')
export IP=$(ip addr show ${EXTERNAL_NIC} | grep "inet\b" | awk '{print $2}' | cut -d/ -f1)
#NAME=$(hostname)

##############################################################################
# Functions
##############################################################################

usage() {
  echo
  echo "USAGE: ${0} install|remove"
  echo
}

retrieve_config_files() {
  if [ -e ${MAIN_CONFIG_FILE} ]
  then
    source ${MAIN_CONFIG_FILE}
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
    source ${USERS_CONNECTIONS_CONFIG_FILE}
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

create_required_folders_and_files() {
  echo "======================================================================"
  echo "Creating required folders and files ..."
  echo "======================================================================"
  echo

  echo "COMMAND: sudo mkdir -m 775 -p ${PODMAN_DIR}/guac/home/.guacamole"
  sudo mkdir -m 775 -p ${PODMAN_DIR}/guac/home/.guacamole
  echo

  echo "COMMAND: sudo mkdir -m 775 -p ${PODMAN_DIR}/postgresql/{data,init}"
  sudo mkdir -m 775 -p ${PODMAN_DIR}/postgresql/{data,init}
  echo

  echo "COMMAND: sudo cp ${INITDB_BASE_FILE} ${PODMAN_DIR}/postgresql/init/initdb.sql"
  sudo cp ${INITDB_BASE_FILE} ${PODMAN_DIR}/postgresql/init/initdb.sql
  echo

  echo "COMMAND: sudo mkdir -m 775 -p ${PODMAN_DIR}/guacd/{drive,records}"
  sudo mkdir -m 775 -p ${PODMAN_DIR}/guacd/{drive,records}
  echo

  # Set the ownership on the folders
  echo "COMMAND: sudo chown ${UID}:users -R ${PODMAN_DIR}"
  sudo chown ${UID}:users -R ${PODMAN_DIR}
  echo
}

install_packages() {
  echo "======================================================================"
  echo "Installing required packages ..."
  echo "======================================================================"
  echo

  source /etc/os-release

  case ${ID} in
    opensuse-leap|opensuse-tumbleweed|sles|sled) 
      echo "COMMAND: sudo zypper ref"
      sudo zypper ref
      echo

      echo "COMMAND: sudo zypper in -y ${PKG_LIST}"
      sudo zypper in -y ${PKG_LIST}
      echo
    ;;
  esac
}

update_hosts_file() {
  echo "======================================================================"
  echo "Updating /etc/hosts file ..."
  echo "======================================================================"
  echo

  for HOST_ENTRY in ${CONNECTION_HOSTNAME_LIST}
  do
    local CONNECTION_HOSTNAME=$(echo ${HOST_ENTRY} | cut -d , -f 1)
    local IP_ADDR=$(echo ${HOST_ENTRY} | cut -d , -f 2)

    if ! grep -q "^${IP_ADDR}" /etc/hosts
    then
      echo "COMMAND: echo ${IP_ADDR}  ${HOSTNAME} | sudo tee -a /etc/hosts":
      echo ${IP_ADDR}  ${CONNECTION_HOST} | sudo tee -a /etc/hosts
      echo
    fi
  done
}

configure_for_podman() {
  echo "======================================================================"
  echo "Creating required configuration for Podman ..."
  echo "======================================================================"
  echo

  # Make sure subuids and subgids are setup
  echo "COMMAND: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 ${USER}"
  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 ${USER}
  echo
  
  # Activate the changes
  echo "COMMAND: podman system migrate"
  podman system migrate
  echo

  # Create the Guacamole Network
  echo "COMMAND: podman network create guacamole"
  podman network create guacamole
  echo
}

enable_systemd_services() {
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

  # Make sure the firewall is enabled and started, then we open the correct ports in the firewall for guac
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

  echo "COMMAND: sudo firewall-cmd --reload"
  sudo firewall-cmd --reload
  echo
}

add_guacadmin_user() {
  echo "======================================================================"
  echo "Adding guacadmin user to initdb.sql file ..."
  echo "======================================================================"
  echo

  echo "" >> ${PODMAN_DIR}/postgresql/init/initdb.sql
  echo "-- GUACAMOLE ADMIN USER" >> ${PODMAN_DIR}/postgresql/init/initdb.sql

  local GUACADMIN_USERNAME=$(echo ${GUACADMIN_USER} | cut -d , -f 1)
  local GUACADMIN_PASSWORD_HASH=$(echo ${GUACADMIN_USER} | cut -d , -f 2)
  local GUACADMIN_PASSWORD_SALT=$(echo ${GUACADMIN_USER} | cut -d , -f 3)
  local GUACADMIN_PASSWORD_PLAINTEXT=$(echo ${GUACADMIN_USER} | cut -d , -f 4)

  echo "----------------------------------------------"
  echo "  Guacamole Admin Username: ${GUACADMIN_USERNAME}"
  echo "  Guacamole Admin Password: ${GUACADMIN_PASSWORD_PLAINTEXT}"
  echo


  echo "
-- Create default user ${GUACADMIN_USERNAME} 
INSERT INTO guacamole_entity (name, type) VALUES ('${GUACADMIN_USERNAME}', 'USER');
INSERT INTO guacamole_user (entity_id, password_hash, password_salt, password_date)
SELECT
    entity_id,
    decode('${GUACADMIN_PASSWORD_HASH}', 'hex'),  -- '${GUACADMIN_PASSWORD_PLAINTEXT}'
    decode('${GUACADMIN_PASSWORD_SALT}', 'hex'),
    CURRENT_TIMESTAMP
FROM guacamole_entity WHERE name = '${GUACADMIN_USERNAME}' AND guacamole_entity.type = 'USER';

-- Grant this user all system permissions
INSERT INTO guacamole_system_permission (entity_id, permission)
SELECT entity_id, permission::guacamole_system_permission_type
FROM (
    VALUES
        ('${GUACADMIN_USERNAME}', 'CREATE_CONNECTION'),
        ('${GUACADMIN_USERNAME}', 'CREATE_CONNECTION_GROUP'),
        ('${GUACADMIN_USERNAME}', 'CREATE_SHARING_PROFILE'),
        ('${GUACADMIN_USERNAME}', 'CREATE_USER'),
        ('${GUACADMIN_USERNAME}', 'CREATE_USER_GROUP'),
        ('${GUACADMIN_USERNAME}', 'ADMINISTER')
) permissions (username, permission)
JOIN guacamole_entity ON permissions.username = guacamole_entity.name AND guacamole_entity.type = 'USER';

-- Grant admin permission to read/update/administer self
INSERT INTO guacamole_user_permission (entity_id, affected_user_id, permission)
SELECT guacamole_entity.entity_id, guacamole_user.user_id, permission::guacamole_object_permission_type
FROM (
    VALUES
        ('${GUACADMIN_USERNAME}', '${GUACADMIN_USERNAME}', 'READ'),
        ('${GUACADMIN_USERNAME}', '${GUACADMIN_USERNAME}', 'UPDATE'),
        ('${GUACADMIN_USERNAME}', '${GUACADMIN_USERNAME}', 'ADMINISTER')
) permissions (username, affected_username, permission)
JOIN guacamole_entity          ON permissions.username = guacamole_entity.name AND guacamole_entity.type = 'USER'
JOIN guacamole_entity affected ON permissions.affected_username = affected.name AND guacamole_entity.type = 'USER'
JOIN guacamole_user            ON guacamole_user.entity_id = affected.entity_id;

  " >> ${PODMAN_DIR}/postgresql/init/initdb.sql
  echo "" >> ${PODMAN_DIR}/postgresql/init/initdb.sql
}

add_guacamole_users() {
  echo "======================================================================"
  echo "Adding Guacamole users to initdb.sql file ..."
  echo "======================================================================"
  echo

  echo "" >> ${PODMAN_DIR}/postgresql/init/initdb.sql
  echo "-- GUACAMOLE USERS GO AFTER THIS LINE" >> ${PODMAN_DIR}/postgresql/init/initdb.sql

  for GUAC_USER in ${GUAC_USER_LIST}
  do
    local GUACUSER_USERID=$(echo ${GUAC_USER} | cut -d , -f 1)
    local GUACUSER_USERNAME=$(echo ${GUAC_USER} | cut -d , -f 2)
    local GUACUSER_PASSWORD_HASH=$(echo ${GUAC_USER} | cut -d , -f 3)
    local GUACUSER_PASSWORD_SALT=$(echo ${GUAC_USER} | cut -d , -f 4)
    local GUACUSER_PASSWORD_PLAINTEXT=$(echo ${GUAC_USER} | cut -d , -f 5)

    echo "----------------------------------------------"
    echo "  Guacamole User ID: ${GUACUSER_USERID}"
    echo "  Username:          ${GUACUSER_USERNAME}"
    echo "  Password:          ${GUACUSER_PASSWORD_PLAINTEXT}"
    echo

    echo "
-- Create default user ${GUACUSER_USERNAME}
INSERT INTO guacamole_entity (name, type) VALUES ('${GUACUSER_USERNAME}', 'USER');
INSERT INTO guacamole_user (entity_id, password_hash, password_salt, password_date)
SELECT
    entity_id,
    decode('${GUACUSER_PASSWORD_HASH}', 'hex'),  -- '${GUACUSER_PASSWORD_PLAINTEXT}'
    decode('${GUACUSER_PASSWORD_SALT}', 'hex'),
    CURRENT_TIMESTAMP
FROM guacamole_entity WHERE name = '${GUACUSER_USERNAME}' AND guacamole_entity.type = 'USER';

-- Grant read permission to read/update/administer self
INSERT INTO guacamole_user_permission (entity_id, affected_user_id, permission)
SELECT guacamole_entity.entity_id, guacamole_user.user_id, permission::guacamole_object_permission_type
FROM (
    VALUES
        ('${GUACUSER_USERNAME}', '${GUACUSER_USERNAME}', 'READ')
) permissions (username, affected_username, permission)
JOIN guacamole_entity          ON permissions.username = guacamole_entity.name AND guacamole_entity.type = 'USER'
JOIN guacamole_entity affected ON permissions.affected_username = affected.name AND guacamole_entity.type = 'USER'
JOIN guacamole_user            ON guacamole_user.entity_id = affected.entity_id;

  " >> ${PODMAN_DIR}/postgresql/init/initdb.sql

  done
  echo "" >> ${PODMAN_DIR}/postgresql/init/initdb.sql

}

add_connections() {
  echo "======================================================================"
  echo "Adding connections to initdb.sql file ..."
  echo "======================================================================"
  echo

  echo "" >> ${PODMAN_DIR}/postgresql/init/initdb.sql
  echo "-- CONNECTIONS GO AFTER THIS LINE" >> ${PODMAN_DIR}/postgresql/init/initdb.sql

  for CONNECTION in ${GUAC_CONNECTION_LIST}
  do
    local CONNECTION_ID=$(echo ${CONNECTION} | cut -d , -f 1)
    local CONNECTION_NAME=$(echo ${CONNECTION} | cut -d , -f 2)
    local CONNECTION_PROTOCOL=$(echo ${CONNECTION} | cut -d , -f 3)
    local CONNECTION_HOST=$(echo ${CONNECTION} | cut -d , -f 4)
    local CONNECTION_PORT=$(echo ${CONNECTION} | cut -d , -f 5)
    local CONNECTION_USERNAME=$(echo ${CONNECTION} | cut -d , -f 6)
    local CONNECTION_PASSWORD=$(echo ${CONNECTION} | cut -d , -f 7)

    echo "----------------------------------------------"
    echo "  Connection ID:   ${CONNECTION_ID}"
    echo "  Connection Name: ${CONNECTION_NAME}"
    echo "  Protocol:        ${CONNECTION_PROTOCOL}"
    echo "  Host:            ${CONNECTION_HOST}"
    echo "  Port:            ${CONNECTION_PORT}"
    echo "  Username:        ${CONNECTION_USERNAME}"
    echo "  Password:        ${CONNECTION_PASSWORD}"
    echo

    echo "
-- CONNECTION: ${CONNECTION_NAME}
INSERT INTO guacamole_connection (connection_name, protocol) VALUES ('${CONNECTION_NAME}', '${CONNECTION_PROTOCOL}');

-- Determine the connection_id
SELECT * FROM guacamole_connection WHERE connection_name = '${CONNECTION_NAME}' AND parent_id IS NULL;

-- Add parameters to the new connection
INSERT INTO guacamole_connection_parameter VALUES (${CONNECTION_ID}, 'hostname', '${CONNECTION_HOST}');
INSERT INTO guacamole_connection_parameter VALUES (${CONNECTION_ID}, 'port', '${CONNECTION_PORT}');
INSERT INTO guacamole_connection_parameter VALUES (${CONNECTION_ID}, 'username', '${CONNECTION_USERNAME}');
INSERT INTO guacamole_connection_parameter VALUES (${CONNECTION_ID}, 'password', '${CONNECTION_PASSWORD}');
    " >> ${PODMAN_DIR}/postgresql/init/initdb.sql
  done
  echo "" >> ${PODMAN_DIR}/postgresql/init/initdb.sql
}

add_user_connection_mappings() {
  echo "======================================================================"
  echo "Adding user to connection mappings to initdb.sql file ..."
  echo "======================================================================"
  echo

  echo "" >> ${PODMAN_DIR}/postgresql/init/initdb.sql
  echo "-- USER TO CONNECTION MAPS GO AFTER THIS LINE" >> ${PODMAN_DIR}/postgresql/init/initdb.sql

  for USER_CONNECTION_MAPPING in ${USER_CONNECTION_MAPPING_LIST}
  do
    local CONNECTION_USER=$(echo ${USER_CONNECTION_MAPPING} | cut -d , -f 1)
    local CONNECTION_NAME=$(echo ${USER_CONNECTION_MAPPING} | cut -d , -f 2)

    for GUACUSER in ${GUAC_USER_LIST}
    do
      if echo ${GUACUSER} | grep -q ${CONNECTION_USER}
      then
        CONNECTION_USERID=$(echo ${GUACUSER} | cut -d , -f 1)
      fi
    done
    
    for CONNECTION in ${GUAC_CONNECTION_LIST}
    do
      if echo ${CONNECTION} | grep -q ${CONNECTION_NAME}
      then
        CONNECTION_ID=$(echo ${CONNECTION} | cut -d , -f 1)
      fi
    done

    echo "${CONNECTION_USER}(${CONNECTION_USERID}) --> ${CONNECTION_NAME}(${CONNECTION_ID})"

    echo "
INSERT INTO guacamole_connection_permission VALUES (${CONNECTION_USERID}, '${CONNECTION_ID}', 'READ');
    " >> ${PODMAN_DIR}/postgresql/init/initdb.sql
    echo

  done
  echo "" >> ${PODMAN_DIR}/postgresql/init/initdb.sql
}

start_containers() {
  echo "======================================================================"
  echo "Starting containers ..."
  echo "======================================================================"
  echo

  echo "[postgresql]"
  # Start the required containers starting with postgresql
  podman run -d --name postgresql \
    -v ${PODMAN_DIR}/postgresql/init:/docker-entrypoint-initdb.d \
    -v ${PODMAN_DIR}/postgresql/data:/var/lib/postgresql/data \
    -v /etc/localtime:/etc/localtime:ro \
    -e POSTGRES_USER=guacamole \
    -e POSTGRES_PASSWORD=${GUACDB_PASSWORD} \
    -e POSTGRES_DB=guacamole_db \
    --network=guacamole \
    docker.io/library/postgres:16-alpine
  echo

  echo "[guacd]"
  # followed by the Guacamole listener daemon
  podman run -d --name guacd \
    -v /etc/localtime:/etc/localtime:ro \
    -v ${PODMAN_DIR}/guacd/records:/record \
    -v ${PODMAN_DIR}/guacd/drive:/drive \
    --network=guacamole \
    docker.io/guacamole/guacd
  echo

  echo "[guacamole]"
  # now for the Guacamole container
  podman run -d --name guacamole \
    -e POSTGRESQL_HOSTNAME=postgresql \
    -e POSTGRESQL_DATABASE=guacamole_db \
    -e POSTGRESQL_USER=guacamole \
    -e POSTGRESQL_PASSWORD=${GUACDB_PASSWORD} \
    -e GUACD_PORT_4822_TCP_ADDR=guacd \
    -e GUACD_PORT_4822_TCP_PORT=4822 \
    -e GUACD_HOSTNAME=guacd \
    -v ${PODMAN_DIR}/guac/home:/etc/guacamole \
    --requires=guacd,postgresql \
    -p 8080:8080 \
    --network=guacamole \
    docker.io/guacamole/guacamole
  echo
}

enabled_systemd_services() {
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
  echo "COMMAND: podman generate systemd --files --name postgresql > /dev/null 2>&1"
  podman generate systemd --files --name postgresql > /dev/null 2>&1
  echo

  echo "COMMAND: podman generate systemd --files --name guacd > /dev/null 2>&1"
  podman generate systemd --files --name guacd > /dev/null 2>&1
  echo

  echo "COMMAND: podman generate systemd --files --name guacamole > /dev/null 2>&1"
  podman generate systemd --files --name guacamole > /dev/null 2>&1
  echo

  echo "COMMAND: cd ~"
  cd ~
  echo

  # Reload systemctl user daemon so that the newly created service files are seen by systemd
  echo "COMMAND: systemctl --user daemon-reload > /dev/null 2>&1"
  systemctl --user daemon-reload > /dev/null 2>&1
  echo

  # Enable the container service files so that containers will start at boot
  echo "COMMAND: systemctl --user enable container-postgresql.service > /dev/null 2>&1"
  systemctl --user enable container-postgresql.service > /dev/null 2>&1
  echo

  echo "COMMAND: systemctl --user enable container-guacd.service > /dev/null 2>&1"
  systemctl --user enable container-guacd.service > /dev/null 2>&1
  echo

  echo "COMMAND: systemctl --user enable container-guacamole.service > /dev/null 2>&1"
  systemctl --user enable container-guacamole.service > /dev/null 2>&1
  echo
}

###############################################################################

install_guacamole() {
  echo "######################################################################"
  echo "              Installing and Configuring Guacamole"
  echo "######################################################################"
  echo

  retrieve_config_files
  retrieve_base_initdb_file
  create_required_folders_and_files

  install_packages
  update_hosts_file
  configure_for_podman
  enable_systemd_services
  enable_configure_firewall

  add_guacadmin_user
  add_guacamole_users
  add_connections
  add_user_connection_mappings

  start_containers
  enabled_systemd_services

  echo
  echo
  echo "######################################################################"
  echo "             Guacamole has been successfully configured"
  echo "######################################################################"
  echo
}

remove_guacamole() {
  echo "######################################################################"
  echo "                        Removing Guacamole"
  echo "######################################################################"
  echo

  retrieve_config_files

  echo "========================================================================"
  echo "Stopping and removing Podman containers, networks, etc. ..."
  echo "========================================================================"
  echo

  # Stop all containers
  echo "COMMAND: podman stop -a"
  podman stop -a
  echo

  # Remove all of the containers
  echo "COMMAND: podman rm -a"
  podman rm -a
  echo

  # Remove all of the artifacts
  echo "COMMAND: podman system prune -af"
  podman system prune -af
  echo

  echo "========================================================================"
  echo "Disabling Systemd services ..."
  echo "========================================================================"
  echo

  echo "COMMAND: systemctl --user disable container-postgresql.service > /dev/null 2>&1"
  systemctl --user disable container-postgresql.service > /dev/null 2>&1
  echo

  echo "COMMAND: systemctl --user disable container-guacd.service > /dev/null 2>&1"
  systemctl --user disable container-guacd.service > /dev/null 2>&1
  echo

  echo "COMMAND: systemctl --user disable container-guacamole.service > /dev/null 2>&1"
  systemctl --user disable container-guacamole.service > /dev/null 2>&1
  echo

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


##############################################################################
# Main Code Body
##############################################################################

case ${1} in
  install)
    install_guacamole
  ;;
  remove)
    remove_guacamole
  ;;
  *)
    usage
    exit
  ;;
esac
