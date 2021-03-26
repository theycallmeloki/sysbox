#!/bin/bash

load ../helpers/run
load ../helpers/docker
load ../helpers/systemd
load ../helpers/fs

#
# Sysbox Installer Test Helper Functions
# (for tests using bats)
#

export test_dir="/tmp/installer/"
export test_image="busybox"
export test_container="$test_image"

export VERSION=$(egrep -m 1 "\[|\]" CHANGELOG.md | cut -d"[" -f2 | cut -d"]" -f1)
export IMAGE_BASE_DISTRO=$(lsb_release -ds | cut -d' ' -f1 | tr '[:upper:]' '[:lower:]')
export IMAGE_BASE_RELEASE=$(lsb_release -cs)
export IMAGE_FILE_PATH="image/deb/debbuild/${IMAGE_BASE_DISTRO}-${IMAGE_BASE_RELEASE}"
export IMAGE_FILE_NAME="sysbox_${VERSION}-0.${IMAGE_BASE_DISTRO}-${IMAGE_BASE_RELEASE}_amd64.deb"

# Installation / Uninstallation output string.
export installation_output=""
export uninstallation_output=""

# Dockerd default configuration dir/file.
export dockerCfgDir="/etc/docker"
export dockerCfgFile="${dockerCfgDir}/daemon.json"

# Debconf files to hold desired pkg configuration.
export auto_dockerd_restart="${test_dir}/auto_dockerd_restart.debconf"
export manual_dockerd_restart="${test_dir}/manual_dockerd_restart.debconf"

#
# Auxiliary routines.
#

function install_init() {

  run mkdir -p "$test_dir"
  [ "$status" -eq 0 ]

  run rm -rf "$test_dir/*"
  [ "$status" -eq 0 ]

  # Wipe all pre-existing containers and restart dockerd from a clean slate.
  run sh -c "docker stop \$(docker ps -a -q) || true"
  [ "$status" -eq 0 ]
  run sh -c "docker container prune -f"
  [ "$status" -eq 0 ]
  run sh -c "systemctl restart docker"
  [ "$status" -eq 0 ]

  # Create debconf file to set "automatic_dockerd_restart" mode.
  cat > "${auto_dockerd_restart}" <<EOF
sysbox	sysbox/docker_userns_autoconfig	boolean	true
EOF

  # Create debconf file to set "manual_dockerd_restart" mode.
  cat > "${manual_dockerd_restart}" <<EOF
sysbox	sysbox/docker_userns_autoconfig	boolean	false
EOF
}

function docker_return_defaults() {

  run sh -c "rm -rf ${dockerCfgFile} && systemctl restart docker"
  [ "$status" -eq 0 ]
}

function kernel_headers_install() {

  run sh -c "sudo apt-get update && sudo apt-get install -y linux-headers-$(uname -r)"
  [ "$status" -eq 0 ]
}

function kernel_headers_uninstall() {

  run sh -c "sudo apt purge -y linux-headers-$(uname -r)"
  [ "$status" -eq 0 ]
}

function install_sysbox() {

  run sudo DEBIAN_FRONTEND=noninteractive dpkg -i ${IMAGE_FILE_PATH}/${IMAGE_FILE_NAME}
  installation_output="${output}"
  [ "$status" -eq 0 ]

  # Some wiggle-room for processes to initialize.
  sleep 3
}

function uninstall_sysbox() {
  local purge

  if [[ $1 = "purge" ]]; then
    purge="--purge"
  fi

  run sudo DEBIAN_FRONTEND=noninteractive dpkg ${purge} sysbox
  uninstallation_output="${output}"
  [ "$status" -eq 0 ]
}

function install_verify() {

  run sudo dpkg -s sysbox
  [ "$status" -eq 0 ]

  run sh -c "sudo systemctl status sysbox | egrep -q \"active \(exited\)\""
  [ "$status" -eq 0 ]

  run sh -c "sudo systemctl status sysbox-mgr | egrep -q \"active \(running\)\""
  [ "$status" -eq 0 ]

  run sh -c "sudo systemctl status sysbox-fs | egrep -q \"active \(running\)\""
  [ "$status" -eq 0 ]

  run command -v sysbox-mgr
  [ "$status" -eq 0 ]

  run command -v sysbox-fs
  [ "$status" -eq 0 ]

  run command -v sysbox-runc
  [ "$status" -eq 0 ]
}

function uninstall_verify() {

  run sudo dpkg -s sysbox
  [ "$status" -ne 0 ]

  run sh -c "sudo systemctl status sysbox | egrep -q \"active \(exited\)\""
  [ "$status" -ne 0 ]

  run sh -c "sudo systemctl status sysbox-mgr | egrep -q \"active \(running\)\""
  [ "$status" -ne 0 ]

  run sh -c "sudo systemctl status sysbox-fs | egrep -q \"active \(running\)\""
  [ "$status" -ne 0 ]

  run command -v sysbox-mgr
  [ "$status" -ne 0 ]

  run command -v sysbox-fs
  [ "$status" -ne 0 ]

  run command -v sysbox-runc
  [ "$status" -ne 0 ]
}

function verify_docker_config_sysbox_runtime_presence() {

  # Verify that sysbox runtime has been properly configured.
  run sh -c "jq --exit-status 'has(\"runtimes\")' ${dockerCfgFile} &&
             jq '.runtimes | has(\"sysbox-runc\")' ${dockerCfgFile}"
  [ "$status" -eq 0 ]

  # Also, ensure that no duplicated sysbox-runc entries exist in config.
  run sh -c "egrep ' +\"sysbox-runc\": {' ${dockerCfgFile} | wc -l | egrep -q 1"
  [ "$status" -eq 0 ]
}

function verify_docker_config_sysbox_runtime_absence() {

  # Verify that sysbox runtime entry has been eliminated from docker config.
  run sh -c "jq --exit-status 'has(\"runtimes\")' ${dockerCfgFile} &&
             jq --exit-status '.runtimes | has(\"sysbox-runc\")' ${dockerCfgFile}"
  [ "$status" -ne 0 ]
}

function verify_docker_sysbox_runtime_presence() {

  run sh -c "docker info | egrep -q \"Runtimes:.*sysbox-runc\""
  [ "$status" -eq 0 ]
}

function verify_docker_sysbox_runtime_absence() {

  run sh -c "docker info | egrep -q \"Runtimes:.*sysbox-runc\""
  [ "$status" -ne 0 ]
}

function verify_shiftfs_mode() {

  run sh -c "docker info 2>&1 | egrep -q \"^  userns$\""
  [ "$status" -ne 0 ]
}

function verify_userns_mode() {

  # Docker's userns mode.
  run sh -c "docker info 2>&1 | egrep -q \"^  userns$\""
  [ "$status" -eq 0 ]


  # Only one 'userns' entry can exist at any given point.
  #
  # Example:     "userns-remap": "sysbox",
  #run sh -c "egrep ' +\"userns-remap\": \".*\"' ${dockerCfgFile} | wc -l | egrep -q 1"
  #[ "$status" -eq 0 ]
}

function config_automatic_restart() {
  local on=$1

  if [ ${on} = "false" ]; then
    sudo debconf-set-selections "${manual_dockerd_restart}"
    return
  fi

  sudo debconf-set-selections "${auto_dockerd_restart}"
}

function enable_shiftfs() {

  modprobe shiftfs
}

function disable_shiftfs() {

  # run sh -c "lsmod | egrep -q \"shiftfs\""
  # [ "$status" -eq 0 ]

  run modprobe -r shiftfs
  [ "$status" -eq 0 ]

  run sh -c "lsmod | egrep -q \"shiftfs\""
  [ "$status" -eq 1 ]
}


