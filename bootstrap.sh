#!/usr/bin/env bash

#sudo yum -y update

sudo rpm -i http://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm

sudo yum -y install python-pip python-virtualenv gcc git

sudo yum -y install python-keystoneclient python-novaclient python-glanceclient python-neutronclient python-keystoneclient

yum -y install sshpass

cd /opt

echo "Cloning khaleesi to /opt"

if [ ! -d khaleesi ]; then
  sudo git clone -b opnfv https://github.com/trozet/khaleesi.git
fi


pip install ansible
pip install requests



cd khaleesi

sudo cp ansible.cfg.example ansible.cfg

cd tools/ksgen

sudo python setup.py develop

cd ../..

echo "Completed Installing Khaleesi"

cd /opt

echo "Grab Khaleesi settings"

git clone https://gist.github.com/trozet/c5bde608822d8e6b063a.git foreman_ksgen-settings


./run.sh --use foreman_ksgen-settings/foreman-opnfv-settings.yml playbooks/opnfv.yml
