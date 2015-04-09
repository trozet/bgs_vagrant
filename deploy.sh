#Deploy script to install provisioning server for Foreman/QuickStack
#author: Tim Rozet (trozet@redhat.com)
#
#Uses Vagrant and VirtualBox
#VagrantFile uses bootsrap.sh which Installs Khaleesi
#Khaleesi will install and configure Foreman/QuickStack 
#
#Pre-requisties:
#Supports 4,3 or 1 interface configuration
#Target system must be RPM based
#Ensure the host's kernel is up to date (yum update)

##FUNCTIONS
##find ip of interface
##params: interface name
function find_ip {
  ip addr show $1 | grep -Eo '^\s+inet\s+[\.0-9]+' | awk '{print $2}'
}

##increments next IP
##params: ip
##assumes there is room before 255 max
function next_ip {
  baseaddr="$(echo $1 | cut -d. -f1-3)"
  lsv="$(echo $1 | cut -d. -f4)"
  if [ "$lsv" -ge 254 ]; then
    return 1
  fi
  ((lsv++))
  echo $baseaddr.$lsv
}

##removes the network interface config from Vagrantfile
##params: interface
##assumes you are in the directory of Vagrantfile
function remove_vagrant_network {
  sed -i 's/^.*'"$1"'.*$//' Vagrantfile
}

##check if IP is in use
##ping ip to get arp entry, then check arp
function is_ip_used {
  ping -c 5 $1 > /dev/null 2>&1
  arp -n | grep "$1 " | grep -iv incomplete > /dev/null 2>&1
}

##find next usable IP
function next_usable_ip {
  new_ip=$(next_ip $1)
  while [ "$new_ip" ]; do
    if ! is_ip_used $new_ip; then
      echo $new_ip
      return 0
    fi
    new_ip=$(next_ip $new_ip)
  done
  return 1
}

##END FUNCTIONS

##disable selinux
/sbin/setenforce 0

##install EPEL
if ! yum repolist | grep "epel/"; then
  if ! rpm -Uvh http://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm; then
    printf '%s\n' 'build.sh: Unable to configure EPEL repo' >&2
    exit 1
  fi
else
  printf '%s\n' 'build.sh: Skipping EPEL repo as it is already configured.'
fi

##install dependencies
if ! yum -y install binutils gcc make patch libgomp glibc-headers glibc-devel kernel-headers kernel-devel dkms; then
  printf '%s\n' 'build.sh: Unable to install depdency packages' >&2
  exit 1
fi

##install VirtualBox repo
if cat /etc/*release | grep -i "Fedora release"; then
  vboxurl=http://download.virtualbox.org/virtualbox/rpm/fedora/\$releasever/\$basearch
else
  vboxurl=http://download.virtualbox.org/virtualbox/rpm/el/\$releasever/\$basearch
fi

cat > /etc/yum.repos.d/virtualbox.repo << EOM
[virtualbox]
name=Oracle Linux / RHEL / CentOS-\$releasever / \$basearch - VirtualBox
baseurl=$vboxurl
enabled=1
gpgcheck=1
gpgkey=https://www.virtualbox.org/download/oracle_vbox.asc
skip_if_unavailable = 1
keepcache = 0
EOM

##install VirtualBox
if ! yum list installed | grep -i virtualbox; then
  if ! yum -y install VirtualBox-4.3; then
    printf '%s\n' 'build.sh: Unable to install virtualbox package' >&2
    exit 1
  fi
fi

##install kmod-VirtualBox
if ! lsmod | grep vboxdrv; then
  if ! sudo /etc/init.d/vboxdrv setup; then
    printf '%s\n' 'build.sh: Unable to install kernel module for virtualbox' >&2
    exit 1
  fi
else
  printf '%s\n' 'build.sh: Skipping kernel module for virtualbox.  Already Installed'
fi

##install Vagrant
if ! rpm -qa | grep vagrant; then
  if ! rpm -Uvh https://dl.bintray.com/mitchellh/vagrant/vagrant_1.7.2_x86_64.rpm; then
    printf '%s\n' 'build.sh: Unable to install vagrant package' >&2
    exit 1
  fi
else
  printf '%s\n' 'build.sh: Skipping Vagrant install as it is already installed.'
fi

##add centos 7 box to vagrant
if ! vagrant box list | grep chef/centos-7.0; then
  if ! vagrant box add chef/centos-7.0 --provider virtualbox; then
    printf '%s\n' 'build.sh: Unable to download centos7 box for Vagrant' >&2
    exit 1
  fi
else
  printf '%s\n' 'build.sh: Skipping Vagrant box add as centos-7.0 is already installed.'
fi

##install workaround for centos7
if ! vagrant plugin install vagrant-centos7_fix; then
  printf '%s\n' 'build.sh: Warning: unable to install vagrant centos7 workaround' >&2
fi

cd /tmp/

##remove bgs vagrant in case it wasn't cleaned up
rm -rf /tmp/bgs_vagrant

##clone bgs vagrant
##will change this to be opnfv repo when commit is done
if ! git clone https://github.com/trozet/bgs_vagrant.git; then
  printf '%s\n' 'build.sh: Unable to clone vagrant repo' >&2
  exit 1
fi

cd bgs_vagrant

##detect host 1 or 3 interface configuration
output=`ip link show | grep -E "^[0-9]" | grep -Ev ": lo|tun|virbr|vboxnet" | awk '{print $2}' | sed 's/://'`

if [ ! "$output" ]; then
  printf '%s\n' 'build.sh: Unable to detect interfaces to bridge to' >&2
  exit 1
fi

##find number of interfaces with ip and substitute in VagrantFile
if_counter=0
for interface in ${output}; do

  if [ "$if_counter" -ge 4 ]; then
    break
  fi
  interface_ip=$(find_ip $interface)
  if [ ! "$interface_ip" ]; then
    continue
  fi
  new_ip=$(next_usable_ip $interface_ip)
  if [ ! "$new_ip" ]; then
    continue
  fi
  interface_ip[$if_counter]=$new_ip
  sed -i 's/^.*eth_replace'"$if_counter"'.*$/  config.vm.network "public_network", ip: '\""$new_ip"\"', bridge: '\'"$interface"\''/' Vagrantfile
  ((if_counter++))
done

##now remove interface config in Vagrantfile for 1 node
##if 1, 3, or 4 interfaces set deployment type
##if 2 interfaces remove 2nd interface and set deployment type
if [ "$if_counter" == 1 ]; then
  deployment_type="single_network"
  remove_vagrant_network eth_replace1
  remove_vagrant_network eth_replace2
  remove_vagrant_network eth_replace3
elif [ "$if_counter" == 2 ]; then
  deployment_type="single_network"
  second_interface=`echo $output | awk '{print $2}'`
  remove_vagrant_network $second_interface
  remove_vagrant_network eth_replace2
elif [ "$if_counter" == 3 ]; then
  deployment_type="three_network"
  remove_vagrant_network eth_replace3
else
  deployment_type="multi_network"
fi

##Edit the ksgen settings appropriately
##ksgen settings will be stored in /vagrant on the vagrant machine
##if single node deployment all the variables will have the same ip
##interface names will be enp0s3, enp0s8, enp0s9 in chef/centos7

##replace private interface parameter
##private interface will be of hosts, so we need to know the provisioned host interface name
##we add biosdevname=0, net.ifnames=0 to the kickstart to use regular interface naming convention on hosts
##replace IP for parameters with next IP that will be given to controller
##need to add changes here for public network in tempest settings eventually
if [ "$deployment_type" == "single_network" ]; then
  sed -i 's/^.*ovs_tunnel_if:.*$/  ovs_tunnel_if: eth0/' opnfv_ksgen_settings.yml
  private_ip=$(next_ip ${interface_ip[0]})
  if [ ! "$private_ip" ]; then
    printf '%s\n' 'build.sh: Unable to find next ip for single network' >&2
  fi
  sed -i 's/10.4.9.2/'"$private_ip"'/g' opnfv_ksgen_settings.yml
  sed -i 's/10.2.84.3/'"$private_ip"'/g' opnfv_ksgen_settings.yml
elif [ "$deployment_type" == "three_network" ]; then
  sed -i 's/^.*ovs_tunnel_if:.*$/  ovs_tunnel_if: eth1/' opnfv_ksgen_settings.yml
  sed -i 's/^.*storage_iface:.*$/  storage_iface: eth1/' opnfv_ksgen_settings.yml
elif [ "$deployment_type" == "multi_network" ]; then
  sed -i 's/^.*ovs_tunnel_if:.*$/  ovs_tunnel_if: eth1/' opnfv_ksgen_settings.yml
  sed -i 's/^.*storage_iface:.*$/  storage_iface: eth3/' opnfv_ksgen_settings.yml
else
  printf '%s\n' 'build.sh: Unknown network type: $deployment_type' >&2
  exit 1
fi

##stand up vagrant
if ! vagrant up; then
  printf '%s\n' 'build.sh: Unable to start vagrant' >&2
  exit 1
fi


