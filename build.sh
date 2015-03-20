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

##functions
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
  ((lsv++))
  echo $baseaddr.$lsv
}

##removes the network interface config from Vagrantfile
##params: interface
##assumes you are in the directory of Vagrantfile
function remove_vagrant_network {
  sed -i 's/^.*'"$1"'.*$//' Vagrantfile
}

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

cd /tmp/

##clone bgs vagrant
##will change this to be opnfv repo when commit is done
if ! git clone https://github.com/trozet/bgs_vagrant.git; then
  printf '%s\n' 'build.sh: Unable to clone vagrant repo' >&2
  exit 1
fi

cd bgs_vagrant

##detect host 1 or 3 interface configuration
output=`ip link show | grep -E "^[0-9]" | grep -Ev ": lo|tun|virbr" | awk '{print $2}' | sed 's/://'`

if [ ! "$output" ]; then
  printf '%s\n' 'build.sh: Unable to detect interfaces to bridge to' >&2
  exit 1
fi

##find number of interfaces with ip and substitute in VagrantFile
if_counter=0
for interface in ${output}; do

  if [ "$if_counter" >= 3 ]; then
    break
  fi
  interface_ip=$(find_ip $interface)
  if [ ! "$interface_ip" ]; then
    continue
  fi
  new_ip=$(next_ip $interface_ip)
  if [ ! "$new_ip" ]; then
    continue
  fi
  sed -i 's/^.*eth_replace'"$if_counter"'.*$/  config.vm.network "public_network", ip: '\""$new_ip"\"', bridge: '\'"$interface"\''/' Vagrantfile
  ((if_counter++))
done

##now remove interface config in Vagrantfile for 1 node
##if 1 or 3 interfaces set deployment type
##if 2 interfaces remove 2nd interface and set deployment type
if [ "$if_counter" == 1 ]; then
  deployment_type="single_network"
  remove_vagrant_network eth_replace1
  remove_vagrant_network eth_replace2
elif [ "$if_counter" == 2 ]; then
  deployment_type="single_network"
  second_interface=`echo $output | awk '{print $2}'`
  remove_vagrant_network $second_interface
  remove_vagrant_network eth_replace2
else
  deployment_type="multi_network"
fi



