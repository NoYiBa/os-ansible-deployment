#!/usr/bin/env bash

# Copyright 2014, Rackspace US, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

## Shell Opts ----------------------------------------------------------------
set -e -u -v -x


## Vars ----------------------------------------------------------------------
export ADMIN_PASSWORD=${ADMIN_PASSWORD:-"secrete"}
export SERVICE_REGION=${SERVICE_REGION:-"RegionOne"}
export DEPLOY_SWIFT=${DEPLOY_SWIFT:-"yes"}
export PLAYBOOK_DIRECTORY_PARENT=${PLAYBOOK_DIRECTORY_PARENT:-"$(pwd)"}
export PUBLIC_INTERFACE=${PUBLIC_INTERFACE:-"eth0"}
export PUBLIC_ADDRESS=${PUBLIC_ADDRESS:-$(ip -o -4 addr show dev ${PUBLIC_INTERFACE} | awk -F '[ /]+' '/global/ {print $4}')}
export NOVA_VIRT_TYPE=${NOVA_VIRT_TYPE:-"qemu"}
export TEMPEST_FLAT_CIDR=${TEMPEST_FLAT_CIDR:-"172.29.248.0/22"}
export FLUSH_IPTABLES=${FLUSH_IPTABLES:-"yes"}


## Library Check -------------------------------------------------------------
info_block "Checking for required libraries." || source $(dirname ${0})/scripts-library.sh


## Main ----------------------------------------------------------------------
# Check that we are in the root path of the cloned repo
if [ ! -d "playbooks" ];then
    echo "Please execute the gate scripts from the root directory of the cloned source code."
    echo -e "Example: /opt/os-ansible-deployment/\n"
    exit_state 99
fi

# Ensure that the current kernel can support vxlan
if ! modprobe vxlan; then
  MINIMUM_KERNEL_VERSION=$(awk '/openstack_host_required_kernel/ {print $2}' playbooks/inventory/group_vars/all.yml)
  echo "A minimum kernel version of ${MINIMUM_KERNEL_VERSION} is required for vxlan support."
  echo "This build will not work without it."
  exit_fail
fi

info_block "Running AIO Setup"

# Set base DNS to google, ensuring consistent DNS in different environments
echo -e 'nameserver 8.8.8.8\nnameserver 8.8.4.4' | tee /etc/resolv.conf

# Update the package cache and install required packages
apt-get update
apt-get install -y python-dev \
                   python2.7 \
                   build-essential \
                   curl \
                   git-core \
                   ipython \
                   tmux \
                   vim \
                   vlan \
                   bridge-utils \
                   lvm2 \
                   xfsprogs \
                   linux-image-extra-$(uname -r)

# Flush all the iptables rules set by openstack-infra
if [ "${FLUSH_IPTABLES}" == "yes" ]; then
  # Flush all the iptables rules set by openstack-infra
  iptables -F
  iptables -X
  iptables -t nat -F
  iptables -t nat -X
  iptables -t mangle -F
  iptables -t mangle -X
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT ACCEPT
fi

# Ensure newline at end of file (missing on Rackspace public cloud Trusty image)
if ! cat -E /etc/ssh/sshd_config | tail -1 | grep -q "\$$"; then
  echo >> /etc/ssh/sshd_config
fi

# Ensure that sshd permits root login, or ansible won't be able to connect
if grep "^PermitRootLogin" /etc/ssh/sshd_config > /dev/null; then
  sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
else
  echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
fi

# Create /opt if it doesn't already exist
if [ ! -d "/opt" ];then
  mkdir /opt
fi

# Remove the pip directory if its found
if [ -d "${HOME}/.pip" ];then
  rm -rf "${HOME}/.pip"
fi

# Install pip
if [ ! "$(which pip)" ];then
    curl ${GET_PIP_URL} > /opt/get-pip.py
    python2 /opt/get-pip.py || python /opt/get-pip.py
fi

# Install requirements if there are any
if [ -f "requirements.txt" ];then
    pip2 install -r requirements.txt || pip install -r requirements.txt
fi

# Configure all disk space
configure_diskspace

# Create /etc/rc.local if it doesn't already exist
if [ ! -f "/etc/rc.local" ];then
  touch /etc/rc.local
  chmod +x /etc/rc.local
fi

# Make the system key used for bootstrapping self
if [ ! -d /root/.ssh ];then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
fi

pushd /root/.ssh/
  if [ ! -f "id_rsa" ];then
      key_create
  fi

  if [ ! -f "id_rsa.pub" ];then
    rm "id_rsa"
    key_create
  fi

  KEYENTRY=$(cat id_rsa.pub)
  if [ ! "$(grep \"$KEYENTRY\" authorized_keys)" ];then
      echo "$KEYENTRY" | tee -a authorized_keys
  fi
popd

# Make sure everything is mounted.
mount -a || true

# Build the loopback drive for swap to use
if [ ! "$(swapon -s | grep -v Filename)" ]; then
  loopback_create "/opt/swap.img" 1024M thick swap
  # Ensure swap will be used on the host
  if [ ! $(sysctl vm.swappiness | awk '{print $3}') == "10" ];then
    sysctl -w vm.swappiness=10 | tee -a /etc/sysctl.conf
  fi
  swapon -a
fi

# Build the loopback drive for cinder to use
CINDER="cinder.img"
if ! vgs cinder-volumes; then
  loopback_create "/opt/${CINDER}" 1000G thin rc
  CINDER_DEVICE=$(losetup -a | awk -F: "/${CINDER}/ {print \$1}")
  pvcreate ${CINDER_DEVICE}
  pvscan
  # Check for the volume group
  if ! vgs cinder-volumes; then
    vgcreate cinder-volumes ${CINDER_DEVICE}
  fi
  # Ensure that the cinder loopback is enabled after reboot
  if ! grep ${CINDER} /etc/rc.local && ! vgs cinder-volumes; then
    sed -i "\$i losetup \$(losetup -f) /opt/${CINDER}" /etc/rc.local
  fi
fi

# Enable swift deployment
if [ "${DEPLOY_SWIFT}" == "yes" ]; then
  # build the loopback drives for swift to use
  for SWIFT in swift1 swift2 swift3; do
    if ! grep "${SWIFT}" /proc/mounts > /dev/null; then
      loopback_create "/opt/${SWIFT}.img" 1000G thin none
      if ! grep "${SWIFT}.img" /etc/fstab > /dev/null; then
        echo "/opt/${SWIFT}.img /srv/${SWIFT}.img xfs loop,noatime,nodiratime,nobarrier,logbufs=8 0 0" >> /etc/fstab
      fi
      # Format the lo devices
      mkfs.xfs -f "/opt/${SWIFT}.img"
      mkdir -p "/srv/${SWIFT}.img"
      mount "/opt/${SWIFT}.img" "/srv/${SWIFT}.img"
    fi
  done
fi

# Copy the gate's repo to the expected location
pushd ${PLAYBOOK_DIRECTORY_PARENT}
  # Copy aio network config into place.
  mkdir -p /etc/network/interfaces.d/
  cp -R ${PLAYBOOK_DIRECTORY_PARENT}/etc/network/interfaces.d/aio_interfaces.cfg /etc/network/interfaces.d/
  # Remove an existing etc directory if already found
  if [ -d "/etc/openstack_deploy" ];then
    rm -rf "/etc/openstack_deploy"
  fi
  # Copy the base etc files
  cp -R ${PLAYBOOK_DIRECTORY_PARENT}/etc/openstack_deploy /etc/
  # Generate the passwords
  ${PLAYBOOK_DIRECTORY_PARENT}/scripts/pw-token-gen.py --file /etc/openstack_deploy/user_secrets.yml
popd

# change the generated passwords for the OpenStack (admin) and Kibana (kibana) accounts
sed -i "s/keystone_auth_admin_password:.*/keystone_auth_admin_password: ${ADMIN_PASSWORD}/" /etc/openstack_deploy/user_secrets.yml
sed -i "s/kibana_password:.*/kibana_password: ${ADMIN_PASSWORD}/" /etc/openstack_deploy/user_secrets.yml

ENV_VERSION="$(md5sum /etc/openstack_deploy/openstack_environment.yml | awk '{print $1}')"
sed -i "s/environment_version:.*/environment_version: ${ENV_VERSION}/" /etc/openstack_deploy/openstack_user_config.yml

sed -i "s/external_lb_vip_address:.*/external_lb_vip_address: ${PUBLIC_ADDRESS}/" /etc/openstack_deploy/openstack_user_config.yml

# Service region set
echo "keystone_service_region: ${SERVICE_REGION}" | tee -a /etc/openstack_deploy/user_variables.yml
echo "nova_virt_type: ${NOVA_VIRT_TYPE}" | tee -a /etc/openstack_deploy/user_variables.yml
echo "tempest_public_subnet_cidr: ${TEMPEST_FLAT_CIDR}" | tee -a /etc/openstack_deploy/user_variables.yml

if [ "${DEPLOY_SWIFT}" == "yes" ]; then
  # ensure that glance is configured to use swift
  sed -i "s/glance_default_store:.*/glance_default_store: swift/" /etc/openstack_deploy/user_variables.yml
  sed -i "s/glance_swift_store_auth_address:.*/glance_swift_store_auth_address: '{{ keystone_service_internalurl }}'/" /etc/openstack_deploy/user_secrets.yml
  sed -i "s/glance_swift_store_container:.*/glance_swift_store_container: glance_images/" /etc/openstack_deploy/user_secrets.yml
  sed -i "s/glance_swift_store_key:.*/glance_swift_store_key: '{{ keystone_auth_admin_password }}'/" /etc/openstack_deploy/user_secrets.yml
  sed -i "s/glance_swift_store_region:.*/glance_swift_store_region: ${SERVICE_REGION}/" /etc/openstack_deploy/user_secrets.yml
  sed -i "s/glance_swift_store_user:.*/glance_swift_store_user: '{{ keystone_admin_user_name }}:{{ keystone_admin_tenant_name }}'/" /etc/openstack_deploy/user_secrets.yml
fi

# Ensure the conf.d directory exists
if [ ! -d "/etc/openstack_deploy/conf.d" ];then
  mkdir -p "/etc/openstack_deploy/conf.d"
fi

# Ensure the network source is in place
if [ ! "$(grep -Rni '^source\ /etc/network/interfaces.d/\*.cfg' /etc/network/interfaces)" ]; then
    echo "source /etc/network/interfaces.d/*.cfg" | tee -a /etc/network/interfaces
fi

# Bring up the new interfaces
for i in br-storage br-vlan br-vxlan br-mgmt; do
    if grep $i /proc/net/dev > /dev/null;then
      /sbin/ifdown $i || true
    fi
    /sbin/ifup $i || true
done

set +x +v
info_block "The system has been prepared for an all-in-one build."
