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
#
# (c) 2014, Kevin Carter <kevin.carter@rackspace.com>

## Shell Opts ----------------------------------------------------------------
set -e -u -v -x


## Vars ----------------------------------------------------------------------
export ANSIBLE_GIT_REPO=${ANSIBLE_GIT_REPO:-"https://github.com/ansible/ansible"}
export ANSIBLE_GIT_RELEASE=${ANSIBLE_GIT_RELEASE:-"v1.8.2"}
export ANSIBLE_WORKING_DIR=${ANSIBLE_WORKING_DIR:-/opt/ansible_${ANSIBLE_GIT_RELEASE}}
export GET_PIP_URL=${GET_PIP_URL:-"https://bootstrap.pypa.io/get-pip.py"}
export SSH_DIR=${SSH_DIR:-"/root/.ssh"}
export ANSIBLE_ROLE_FILE=${ANSIBLE_ROLE_FILE:-"ansible-role-requirements.yml"}
export UPDATE_ANSIBLE_REQUIREMENTS=${UPDATE_ANSIBLE_REQUIREMENTS:-"yes"}

# Export known paths
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


## Main ----------------------------------------------------------------------
echo "Bootstrapping System with Ansible"

# Check that we are in the root path of the cloned repo
if [ ! -d "playbooks" ];then
    echo "Please execute the gate scripts from the root directory of the cloned source code."
    echo -e "Example: /opt/os-ansible-deployment/\n"
    exit_state 99
fi

# Create the ssh dir if needed
if [ ! -d "${SSH_DIR}" ];then
    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"
fi

# Make the system key used for bootstrapping self if needed
if [ ! -f "${SSH_DIR}/id_rsa" ];then
    echo y | ssh-keygen -t rsa -f "${SSH_DIR}/id_rsa" -N ''
    pushd "${SSH_DIR}"
        cat id_rsa.pub | tee -a authorized_keys
    popd
fi

# Install the base packages
(apt-get update && apt-get -y install git python-all python-dev curl autoconf g++ python2.7-dev) || yum install git python-devel curl

# If the working directory exists remove it
if [ -d "${ANSIBLE_WORKING_DIR}" ];then
    rm -rf "${ANSIBLE_WORKING_DIR}"
fi

# Clone down the base ansible source
git clone "${ANSIBLE_GIT_REPO}" "${ANSIBLE_WORKING_DIR}"
pushd "${ANSIBLE_WORKING_DIR}"
    git checkout "${ANSIBLE_GIT_RELEASE}"
    git submodule update --init --recursive
popd


# Install pip
if [ ! "$(which pip)" ];then
    curl ${GET_PIP_URL} > /opt/get-pip.py
    python2 /opt/get-pip.py || python /opt/get-pip.py
fi

# Install requirements if there are any
if [ -f "requirements.txt" ];then
    pip2 install -r requirements.txt || pip install -r requirements.txt
fi

# Install ansible
pip2 install "${ANSIBLE_WORKING_DIR}" || pip install "${ANSIBLE_WORKING_DIR}"

# Update dependent roles
if [ -f "ansible-role-requirements.yml" ];then
    # Update or create the roles manifest
    if [ "${UPDATE_ANSIBLE_REQUIREMENTS}" == "yes" ];then
        ./scripts/os-ansible-role-requirements.py --requirement-file ${ANSIBLE_ROLE_FILE} update
    fi
    # Pull all required roles.
    ansible-galaxy install --role-file=${ANSIBLE_ROLE_FILE} \
                           --roles-path=playbooks/roles/ \
                           --ignore-errors \
                           --force
fi

# Create openstack ansible wrapper tool
cat > /usr/local/bin/openstack-ansible <<EOF
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
#
# (c) 2014, Kevin Carter <kevin.carter@rackspace.com>

# Openstack wrapper tool to ease the use of ansible with multiple variable files.

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

function info() {
    echo -e "\e[0;35m\${@}\e[0m"
}

# Discover the variable files.
VAR1="\$(for i in \$(ls /etc/openstack_deploy/user_*.yml); do echo -ne "-e @\$i "; done)"

# Provide information on the discovered variables.
info "Variable files: \"\${VAR1}\""

# Run the ansible playbook command.
\$(which ansible-playbook) \${VAR1} \$@
EOF

# Ensure wrapper tool is executable
chmod +x /usr/local/bin/openstack-ansible

echo "openstack-ansible script created."
echo "System is bootstrapped and ready for use."
