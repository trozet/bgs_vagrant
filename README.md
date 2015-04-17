# Foreman/QuickStack Automatic Deployment README

A simple bash script (deploy.sh) will provision out a Foreman/QuickStack VM Server and 4-5 other baremetal nodes in an OpenStack HA + OpenDaylight environment.

##Pre-Requisites

* At least 5 baremetal servers, with 3 interfaces minimum, all connected to separate VLANs
* DHCP should not be running in any VLAN. Foreman will act as a DHCP server.
* On the baremetal server that will be your JumpHost, you need to have the 3 interfaces configured with IP addresses
* On baremetal JumpHost you will need an RPM based linux (CentOS 7 will do) with the kernel up to date (yum update kernel) + at least 2GB of RAM
* Nodes will need to be set to PXE boot first in priority, and off the first NIC, connected to the same VLAN as NIC 1 * of your JumpHost
* Nodes need to have BMC/OOB management via IPMI setup

##How It Works

###deploy.sh:

* Detects your network configuration (3 or 4 usable interfaces)
* Modifies a “ksgen.yml” settings file and Vagrantfile with necessary network info
* Installs Vagrant and dependencies
* Downloads Centos7 Vagrant basebox, and issues a “vagrant up” to start the VM
* The Vagrantfile points to bootstrap.sh as the provisioner to takeover rest of the install

###bootstrap.sh:

* Is initiated inside of the VM once it is up
* Installs Khaleesi, Ansible, and Python dependencies
* Makes a call to Khaleesi to start a playbook: opnfv.yml + “ksgen.yml” settings file

###Khaleesi (Ansible):

* Runs through the playbook to install Foreman/QuickStack inside of the VM
* Configures services needed for a JumpHost: DHCP, TFTP, DNS
* Uses info from “ksgen.yml” file to add your baremetal nodes into Foreman and set them to Build mode
* Issues an API call to Foreman to rebuild all nodes
* Ansible then waits to make sure nodes come back via ssh checks
* Ansible then waits for puppet to run on each node and complete

##Execution Instructions

* On your JumpHost, clone 'git clone https://github.com/trozet/bgs_vagrant.git' to as root to /root/

* Edit opnvf_ksgen_settings.yml → “nodes” section:

  * For each node, compute, controller1..3:
    * mac_address - change to mac_address of that node's Admin NIC (1st NIC)
    * bmc_ip - change to IP of BMC (out-of-band) IP
    * bmc_mac - same as above, but MAC address
    * bmc_user - IPMI username
    * bmc_pass - IPMI password

  * For each controller node:
    * private_mac - change to mac_address of node's Private NIC (2nd NIC)

* Execute deploy.sh via: ./deploy.sh -base_config /root/bgs_vagrant/opnfv_ksgen_settings.yml
