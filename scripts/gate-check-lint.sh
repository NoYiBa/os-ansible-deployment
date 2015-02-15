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


## Library Check -------------------------------------------------------------
info_block "Checking for required libraries." || source $(dirname ${0})/scripts-library.sh


## Main ----------------------------------------------------------------------
info_block "Running Basic Ansible Lint Check"

# Check that we are in the root path of the cloned repo
if [ ! -d "playbooks" ];then
    echo "Please execute the gate scripts from the root directory of the cloned source code."
    echo -e "Example: /opt/os-ansible-deployment/\n"
    exit_state 99
fi

# Install the development requirements
if [ -f "dev-requirements.txt" ]; then
  pip2 install -r dev-requirements.txt || pip install -r dev-requirements.txt
else
  pip2 install ansible-lint || pip install ansible-lint
fi

# Perform our simple sanity checks
pushd playbooks
  echo -e '[all]\nlocalhost ansible_connection=local' | tee local_only_inventory

  # Do a basic syntax check on all playbooks and roles
  echo "Running Syntax Check"
  ansible-playbook -i local_only_inventory --syntax-check *.yml --list-tasks

  # Perform a lint check on all playbooks and roles
  echo "Running Lint Check"
  ansible-lint --version
  ansible-lint *.yml
popd