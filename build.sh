#Build script to install provisioning server for Foreman/QuickStack
#author: Tim Rozet (trozet@redhat.com)
#
#Uses Vagrant and VirtualBox
#VagrantFile uses bootsrap.sh which Installs Khaleesi
#Khaleesi will install and configure Foreman/QuickStack 
#
#Pre-requisties:
#Supports 3 or 1 interface configuration
#Target system must be RPM based

##install kernel-devel
if ! yum install kernel-devel; then
  printf '%s\n' 'build.sh: Unable to install kernel-devel package' >&2
  exit 1
fi

##install VirtualBox
if ! yum install virtualbox; then
  printf '%s\n' 'build.sh: Unable to install virtualbox package' >&2
  exit 1
fi

##install kmod-VirtualBox
if ! yum install kmod-VirtualBox; then
  printf '%s\n' 'build.sh: Unable to install kmod-VirtualBox package' >&2
  exit 1
fi

##install Vagrant
if ! yum install vagrant; then
  printf '%s\n' 'build.sh: Unable to install vagrant package' >&2
  exit 1
fi

##add centos 7 box to vagrant
if ! vagrant box add chef/centos-7 --provider virtualbox; then
  printf '%s\n' 'build.sh: Unable to download centos7 box for Vagrant' >&2
  exit 1
fi

##install workaround for centos7
if ! vagrant plugin install vagrant-centos7_fix; then
  printf '%s\n' 'build.sh: Warning: unable to install vagrant centos7 workaround' >&2
fi

##clone bgs vagrant
##will change this to be opnfv repo when commit is done
if ! git clone https://github.com/trozet/bgs_vagrant.git; then
  printf '%s\n' 'build.sh: Unable to clone vagrant repo' >&2
  exit 1
fi

cd bgs_vagrant

##detect host 1 or 3 interface configuration
ip link show | grep -E "^[0-9]" | grep -Ev ": lo|tun|virbr" | awk '{print $2}' | sed 's/://'
