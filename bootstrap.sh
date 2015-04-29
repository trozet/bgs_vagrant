#!/usr/bin/env bash

#bootstrap script for installing/running Khaleesi in Foreman/QuickStack VM
#author: Tim Rozet (trozet@redhat.com)
#
#Uses Vagrant and VirtualBox
#VagrantFile uses bootsrap.sh which Installs Khaleesi
#Khaleesi will install and configure Foreman/QuickStack
#
#Pre-requisties:
#Target system should be Centos7
#Ensure the host's kernel is up to date (yum update)

##VARS
reset=`tput sgr0`
blue=`tput setaf 4`
red=`tput setaf 1`
green=`tput setaf 2`

##END VARS


##install EPEL
if ! yum repolist | grep "epel/"; then
  if ! rpm -Uvh http://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm; then
    printf '%s\n' 'bootstrap.sh: Unable to configure EPEL repo' >&2
    exit 1
  fi
else
  printf '%s\n' 'bootstrap.sh: Skipping EPEL repo as it is already configured.'
fi

##install python,gcc,git
if ! yum -y install python-pip python-virtualenv gcc git; then
  printf '%s\n' 'bootstrap.sh: Unable to install python,gcc,git packages' >&2
  exit 1
fi

##Install sshpass
if ! yum -y install sshpass; then
  printf '%s\n' 'bootstrap.sh: Unable to install sshpass' >&2
  exit 1
fi

cd /opt

echo "Cloning khaleesi to /opt"

if [ ! -d khaleesi ]; then
  if ! git clone -b opnfv https://github.com/trozet/khaleesi.git; then
    printf '%s\n' 'bootstrap.sh: Unable to git clone khaleesi' >&2
    exit 1
  fi
fi

if ! pip install ansible; then
  printf '%s\n' 'bootstrap.sh: Unable to install ansible' >&2
  exit 1
fi

if ! pip install requests; then
  printf '%s\n' 'bootstrap.sh: Unable to install requests python package' >&2
  exit 1
fi


cd khaleesi

cp ansible.cfg.example ansible.cfg

echo "Completed Installing Khaleesi"

cd /opt/khaleesi/

ansible localhost -m setup -i local_hosts

./run.sh --no-logs --use /vagrant/opnfv_ksgen_settings.yml playbooks/opnfv.yml
