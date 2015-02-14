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
set -e -u


## Vars ----------------------------------------------------------------------
export PLAYBOOK_DIRECTORY_PARENT=${PLAYBOOK_DIRECTORY_PARENT:-"$(pwd)"}


## Library Check -------------------------------------------------------------
info_block "Checking for required libraries." || source $(dirname ${0})/scripts-library.sh


function ansible_runner() {
  ansible hosts -m shell -a "$@" --forks 10
}


## Main ----------------------------------------------------------------------
info_block "Running Teardown"

# Check that we are in the root path of the cloned repo
if [ ! -d "playbooks" ];then
  echo "Please execute the gate scripts from the root directory of the cloned source code."
  echo -e "Example: /opt/os-ansible-deployment/\n"
  exit_state 99
fi

pushd ${PLAYBOOK_DIRECTORY_PARENT}/playbooks
  KNOWN_HOSTS=$(ansible hosts --list-hosts) || true
  if [ -z "${KNOWN_HOSTS}" ];then
    ANSIBLE_DESTROY_HOSTS="localhost"
  else
    ANSIBLE_DESTROY_HOSTS="hosts"
  fi
  # Create the destroy play
  cat > /tmp/destroy_play.yml <<EOF
- name: Destruction of openstack
  hosts: "${ANSIBLE_DESTROY_HOSTS}"
  gather_facts: false
  user: root
  tasks:
    - name: Get os service script
      shell: |
        ls /etc/init | grep -e nova -e swift -e neutron
      failed_when: false
      register: servicenames
    - name: Stop services
      service:
        name: "{{ item.split('.')[0] }}"
        state: "stopped"
        enabled: no
      failed_when: false
      with_items: servicenames.stdout_lines
      when: servicenames.stdout
    - name: Remove init scripts
      shell: |
        rm "/etc/init/{{ item }}"
      with_items: servicenames.stdout_lines
      when: servicenames.stdout
    - name: Get pip packages
      shell: |
        pip freeze | grep -i {% for i in remote_pip_pacakges %} -e {{ i }}{% endfor %}
      register: pippackages
      failed_when: false
    - name: Remove python packages
      pip:
        name: "{{ item }}"
        state: "absent"
      with_items: pippackages.stdout_lines
      when: pippackages.stdout
    - name: Remove packages
      apt:
        name: "{{ item }}"
        state: "absent"
      with_items: remove_packages
    - name: Clean up apt cruft
      shell: |
        apt-get autoremove --yes || true
    - name: Get containers
      command: lxc-ls
      register: onlinecontainers
    - name: Destroy containers
      command: lxc-destroy -fn "{{ item }}"
      with_items: onlinecontainers.stdout_lines
      when: onlinecontainers.stdout
    - name: Shutdown the lxc bridge
      shell: |
        ifdown {{ item }} || true
      with_items: shut_interfaces_down
    - name: Lxc system manage shutdown
      shell: |
        lxc-system-manage system-force-tear-down || true
        lxc-system-manage veth-cleanup || true
    - name: Get all logical volumes
      shell: >
        lvs | awk '/lxc/ || /cinder/ || /swift/ {print \$1","\$2}'
      register: lvstorage
    - name: Remove all logical volumes
      lvol:
        vg: "{{ item.split(',')[1] }}"
        lv: "{{ item.split(',')[0] }}"
        state: "absent"
        force: "yes"
      with_items: lvstorage.stdout_lines
      when: lvstorage.stdout
    - name: Get all dm storage devices
      shell: >
        dmsetup info | awk '/lxc/ || /cinder/ || /swift/ {print \$2}'
      register: dmstorage
    - name: Remove dm storage entries
      command: dmsetup remove "{{ item }}"
      with_items: dmstorage.stdout_lines
      when: dmstorage.stdout
    - name: Get all loopback storage devices
      shell: >
        losetup -a | awk -F':' '{print \$1}'
      register: lostorage
    - name: Unmount loopback storage
      shell: |
        umount {{ item }} || true
        losetup -d {{ item }} || true
      with_items: lostorage.stdout_lines
      when: lostorage.stdout
    - name: Remove known AIO mount points (fstab)
      lineinfile:
        dest: "/etc/fstab"
        state: "absent"
        regexp: "{{ item }}.*.img"
      with_items: aio_mount_points
    - name: Remove known AIO mount points (rc.local)
      lineinfile:
        dest: "/etc/rc.local"
        state: "absent"
        regexp: "{{ item }}.*.img"
      with_items: aio_mount_points
    - name: Stop all swap
      command: "swapoff -a"
    - name: Remove known files and folders.
      shell: |
        rm -rf {{ item }}
      with_items: remove_files
  vars:
    aio_mount_points:
      - cinder
      - swap
      - swift
    shut_interfaces_down:
      - lxcbr0
    remove_files:
      - /etc/haproxy
      - /etc/nova
      - /etc/network/interfaces.d/aio_interfaces.cfg
      - /etc/neutron
      - /etc/openstack_deploy
      - /etc/swift
      - /openstack
      - /opt/*.img
      - /opt/*lxc*
      - /opt/*neutron*
      - /opt/*nova*
      - /opt/*pip*
      - /opt/*repo*
      - /opt/*stackforge*
      - /root/.pip
      - /var/lib/neutron
      - /var/lib/nova
      - /var/log/swift
      - /var/log/neutron
      - /var/log/nova
    remove_packages:
      - haproxy
      - hatop
      - liblxc1
      - libvirt0
      - libvirt-bin
      - lxc
      - lxc-dev
      - vim-haproxy
    remote_pip_pacakges:
      - cinder
      - eventlet
      - euca2ools
      - glance
      - heat
      - keystone
      - kombu
      - lxc
      - lxml
      - mysql
      - neutron
      - nova
      - oslo
      - Paste
      - pbr
      - repoze
      - six
      - sql
      - swift
      - turbolift
      - warlock
EOF

  # Destroy all of the known stuff.
  if [ "${ANSIBLE_DESTROY_HOSTS}" == "localhost" ];then
    echo -e '[all]\nlocalhost ansible_connection=local' | tee /tmp/localhost
    openstack-ansible -i /tmp/localhost /tmp/destroy_play.yml --forks 5 || true
  else
    openstack-ansible lxc-containers-destroy.yml --forks 5 || true
    openstack-ansible /tmp/destroy_play.yml --forks 5  || true
  fi
popd

# Remove the temp destruction play
rm /tmp/destroy_play.yml || true
rm /tmp/localhost || true

# Final message
get_instance_info
info_block "* NOTICE *"
echo -e "The system has been torn down."
echo -e "Make sure you update and/or review the file '/etc/fstab'."
if [ ! -z "${KNOWN_HOSTS}" ];then
  echo -e "The following hosts has been touched: \"${KNOWN_HOSTS}\""
fi
echo -e "Entries may need to be updated."
