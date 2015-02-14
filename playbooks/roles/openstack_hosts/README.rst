Openstack host setup
####################
:tags: openstack, host, cloud, ansible
:category: \*nix

Role for basic setup and configuration of a host machine for the intended purpose of use within Openstack.

.. code-block:: yaml

    - name: Basic host setup
      hosts: "hosts"
      user: root
      roles:
        - { role: "openstack_hosts", tags: [ "openstack-hosts-setup" ] }
