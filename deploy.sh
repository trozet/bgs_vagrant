#!/usr/bin/env bash

#Deploy script to install provisioning server for Foreman/QuickStack
#author: Tim Rozet (trozet@redhat.com)
#
#Uses Vagrant and VirtualBox
#VagrantFile uses bootsrap.sh which Installs Khaleesi
#Khaleesi will install and configure Foreman/QuickStack
#
#Pre-requisties:
#Supports 3 or 4 network interface configuration
#Target system must be RPM based
#Ensure the host's kernel is up to date (yum update)
#Provisioned nodes expected to have following order of network connections (note: not all have to exist, but order is maintained):
#eth0- admin network
#eth1- private network (+storage network in 3 NIC config)
#eth2- public network
#eth3- storage network
#script assumes /24 subnet mask

##VARS
reset=`tput sgr0`
blue=`tput setaf 4`
red=`tput setaf 1`
green=`tput setaf 2`

declare -A interface_arr
declare -A controllers_ip_arr
declare -A admin_ip_arr
declare -A public_ip_arr
##END VARS

##FUNCTIONS
display_usage() {
  echo -e "\n\n${blue}This script is used to deploy Foreman/QuickStack Installer and Provision OPNFV Target System${reset}\n\n"
  echo -e "\n${green}Make sure you have the latest kernel installed before running this script! (yum update kernel +reboot)${reset}\n"
  echo -e "\nUsage:\n$0 [arguments] \n"
  echo -e "\n   -no_parse : No variable parsing into config. Flag. \n"
  echo -e "\n   -base_config : Full path of settings file to parse. Optional.  Will provide a new base settings file rather than the default.  Example:  -base_config /opt/myinventory.yml \n"
  echo -e "\n   -virtual : Node virtualization instead of baremetal. Flag. \n"
  echo -e "\n   -no_dhcp : Do not run dhcp server.  Use this with -virtual when your pc network already has a dhcp server. \n"
  echo -e "\n   -static_ip_range : static IP range to use when no_dhcp is specified, must at least a 20 IP block.  Format: '192.168.1.1,192.168.1.20' \n"
  echo -e "\n   -ping_site : site to use to verify IP connectivity from the VM when -virtual is used.  Format: -ping_site www.blah.com \n"
}

##find ip of interface
##params: interface name
function find_ip {
  ip addr show $1 | grep -Eo '^\s+inet\s+[\.0-9]+' | awk '{print $2}'
}

##finds subnet of ip and netmask
##params: ip, netmask
function find_subnet {
  IFS=. read -r i1 i2 i3 i4 <<< "$1"
  IFS=. read -r m1 m2 m3 m4 <<< "$2"
  printf "%d.%d.%d.%d\n" "$((i1 & m1))" "$((i2 & m2))" "$((i3 & m3))" "$((i4 & m4))"
}

##increments subnet by a value
##params: ip, value
##assumes low value
function increment_subnet {
  IFS=. read -r i1 i2 i3 i4 <<< "$1"
  printf "%d.%d.%d.%d\n" "$i1" "$i2" "$i3" "$((i4 | $2))"
}


##finds netmask of interface
##params: interface
##returns long format 255.255.x.x
function find_netmask {
  ifconfig $1 | grep -Eo 'netmask\s+[\.0-9]+' | awk '{print $2}'
}

##finds short netmask of interface
##params: interface
##returns short format, ex: /21
function find_short_netmask {
  echo "/$(ip addr show $1 | grep -Eo '^\s+inet\s+[\/\.0-9]+' | awk '{print $2}' | cut -d / -f2)"
}

##increments next IP
##params: ip
##assumes a /24 subnet
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
##params: ip
##ping ip to get arp entry, then check arp
function is_ip_used {
  ping -c 5 $1 > /dev/null 2>&1
  arp -n | grep "$1 " | grep -iv incomplete > /dev/null 2>&1
}

##find next usable IP
##params: ip
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

##increment ip by value
##params: ip, amount to increment by
##increment_ip $next_private_ip 10
function increment_ip {
  baseaddr="$(echo $1 | cut -d. -f1-3)"
  lsv="$(echo $1 | cut -d. -f4)"
  incrval=$2
  lsv=$((lsv+incrval))
  if [ "$lsv" -ge 254 ]; then
    return 1
  fi
  echo $baseaddr.$lsv
}

##translates yaml into variables
##params: filename, prefix (ex. "config_")
##usage: parse_yaml opnfv_ksgen_settings.yml "config_"
parse_yaml() {
   local prefix=$2
   local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
   sed -ne "s|^\($s\)\($w\)$s:$s\"\(.*\)\"$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
   awk -F$fs '{
      indent = length($1)/2;
      vname[indent] = $2;
      for (i in vname) {if (i > indent) {delete vname[i]}}
      if (length($3) > 0) {
         vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
         printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
      }
   }'
}

##END FUNCTIONS

if [[ ( $1 == "--help") ||  $1 == "-h" ]]; then
    display_usage
    exit 0
fi

echo -e "\n\n${blue}This script is used to deploy Foreman/QuickStack Installer and Provision OPNFV Target System${reset}\n\n"
echo "Use -h to display help"
sleep 2

while [ "`echo $1 | cut -c1`" = "-" ]
do
    echo $1
    case "$1" in
        -base_config)
                base_config=$2
                shift 2
            ;;
        -no_parse)
                no_parse="TRUE"
                shift 1
            ;;
        -virtual)
                virtual="TRUE"
                shift 1
            ;;
        -no_dhcp)
                no_dhcp="TRUE"
                shift 1
            ;;
        -static_ip_range)
                static_ip_range=$2
                shift 2
            ;;
        -ping_site)
                ping_site=$2
                shift 2
            ;;
        *)
                display_usage
                exit 1
            ;;
esac
done

##disable selinux
/sbin/setenforce 0

##install EPEL
if ! yum repolist | grep "epel/"; then
  if ! rpm -Uvh http://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm; then
    printf '%s\n' 'deploy.sh: Unable to configure EPEL repo' >&2
    exit 1
  fi
else
  printf '%s\n' 'deploy.sh: Skipping EPEL repo as it is already configured.'
fi

##install dependencies
if ! yum -y install binutils gcc make patch libgomp glibc-headers glibc-devel kernel-headers kernel-devel dkms psmisc; then
  printf '%s\n' 'deploy.sh: Unable to install dependency packages' >&2
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
    printf '%s\n' 'deploy.sh: Unable to install virtualbox package' >&2
    exit 1
  fi
fi

##install kmod-VirtualBox
if ! lsmod | grep vboxdrv; then
  if ! sudo /etc/init.d/vboxdrv setup; then
    printf '%s\n' 'deploy.sh: Unable to install kernel module for virtualbox' >&2
    exit 1
  fi
else
  printf '%s\n' 'deploy.sh: Skipping kernel module for virtualbox.  Already Installed'
fi

##install Ansible
if ! yum list installed | grep -i ansible; then
  if ! yum -y install ansible; then
    printf '%s\n' 'deploy.sh: Unable to install Ansible package' >&2
    exit 1
  fi
fi

##install Vagrant
if ! rpm -qa | grep vagrant; then
  if ! rpm -Uvh https://dl.bintray.com/mitchellh/vagrant/vagrant_1.7.2_x86_64.rpm; then
    printf '%s\n' 'deploy.sh: Unable to install vagrant package' >&2
    exit 1
  fi
else
  printf '%s\n' 'deploy.sh: Skipping Vagrant install as it is already installed.'
fi

##add centos 7 box to vagrant
if ! vagrant box list | grep chef/centos-7.0; then
  if ! vagrant box add chef/centos-7.0 --provider virtualbox; then
    printf '%s\n' 'deploy.sh: Unable to download centos7 box for Vagrant' >&2
    exit 1
  fi
else
  printf '%s\n' 'deploy.sh: Skipping Vagrant box add as centos-7.0 is already installed.'
fi

##install workaround for centos7
if ! vagrant plugin list | grep vagrant-centos7_fix; then
  if ! vagrant plugin install vagrant-centos7_fix; then
    printf '%s\n' 'deploy.sh: Warning: unable to install vagrant centos7 workaround' >&2
  fi
else
  printf '%s\n' 'deploy.sh: Skipping Vagrant plugin as centos7 workaround is already installed.'
fi

cd /tmp/

##remove bgs vagrant incase it wasn't cleaned up
rm -rf /tmp/bgs_vagrant

##clone bgs vagrant
##will change this to be opnfv repo when commit is done
if ! git clone https://github.com/trozet/bgs_vagrant.git; then
  printf '%s\n' 'deploy.sh: Unable to clone vagrant repo' >&2
  exit 1
fi

cd bgs_vagrant

echo "${blue}Detecting network configuration...${reset}"
##detect host 1 or 3 interface configuration
#output=`ip link show | grep -E "^[0-9]" | grep -Ev ": lo|tun|virbr|vboxnet" | awk '{print $2}' | sed 's/://'`
output=`ifconfig | grep -E "^[a-zA-Z0-9]+:"| grep -Ev "lo|tun|virbr|vboxnet" | awk '{print $1}' | sed 's/://'`

if [ ! "$output" ]; then
  printf '%s\n' 'deploy.sh: Unable to detect interfaces to bridge to' >&2
  exit 1
fi

##virtual we only find 1 interface
if [ $virtual ]; then
  ##find interface with default gateway
  this_default_gw=$(ip route | grep default | awk '{print $3}')
  echo "${blue}Default Gateway: $this_default_gw ${reset}"
  this_default_gw_interface=$(ip route get $this_default_gw | awk '{print $3}')

  ##find interface IP, make sure its valid
  interface_ip=$(find_ip $this_default_gw_interface)
  if [ ! "$interface_ip" ]; then
      echo "${red}Interface ${this_default_gw_interface} does not have an IP: $interface_ip ! Exiting ${reset}"
      exit 1
  fi

  ##set variable info
  if [ ! -z "$no_dhcp" ] && [ ! -z "$static_ip_range" ]; then
    new_ip=$(echo $static_ip_range | cut -d , -f1)
  else
    new_ip=$(next_usable_ip $interface_ip)
    if [ ! "$new_ip" ]; then
      echo "${red} Cannot find next IP on interface ${this_default_gw_interface} new_ip: $new_ip ! Exiting ${reset}"
      exit 1
    fi
  fi
  interface=$this_default_gw_interface
  public_interface=$interface
  interface_arr[$interface]=2
  interface_ip_arr[2]=$new_ip
  subnet_mask=$(find_netmask $interface)
  public_subnet_mask=$subnet_mask
  public_short_subnet_mask=$(find_short_netmask $interface)

  ##set that interface to be public
  sed -i 's/^.*eth_replace2.*$/  config.vm.network "public_network", ip: '\""$new_ip"\"', bridge: '\'"$interface"\'', netmask: '\""$subnet_mask"\"'/' Vagrantfile
  if_counter=1
else
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
    interface_arr[$interface]=$if_counter
    interface_ip_arr[$if_counter]=$new_ip
    subnet_mask=$(find_netmask $interface)
    if [ "$if_counter" -eq 0 ]; then
      admin_subnet_mask=$subnet_mask
    elif [ "$if_counter" -eq 1 ]; then
      private_subnet_mask=$subnet_mask
      private_short_subnet_mask=$(find_short_netmask $interface)
    elif [ "$if_counter" -eq 2 ]; then
      public_subnet_mask=$subnet_mask
      public_short_subnet_mask=$(find_short_netmask $interface)
    elif [ "$if_counter" -eq 3 ]; then
      storage_subnet_mask=$subnet_mask
    else
      echo "${red}ERROR: interface counter outside valid range of 0 to 3: $if_counter ! ${reset}"
      exit 1
    fi
    sed -i 's/^.*eth_replace'"$if_counter"'.*$/  config.vm.network "public_network", ip: '\""$new_ip"\"', bridge: '\'"$interface"\'', netmask: '\""$subnet_mask"\"'/' Vagrantfile
    ((if_counter++))
  done
fi
##now remove interface config in Vagrantfile for 1 node
##if 1, 3, or 4 interfaces set deployment type
##if 2 interfaces remove 2nd interface and set deployment type
if [[ "$if_counter" == 1 || "$if_counter" == 2 ]]; then
  if [ $virtual ]; then
    deployment_type="single_network"
    echo "${blue}Single network detected for Virtual deployment...converting to three_network with internal networks! ${reset}"
    private_internal_ip=155.1.2.2
    admin_internal_ip=156.1.2.2
    private_subnet_mask=255.255.255.0
    private_short_subnet_mask=/24
    interface_ip_arr[1]=$private_internal_ip
    interface_ip_arr[0]=$admin_internal_ip
    admin_subnet_mask=255.255.255.0
    admin_short_subnet_mask=/24
    sed -i 's/^.*eth_replace1.*$/  config.vm.network "private_network", virtualbox__intnet: "my_private_network", ip: '\""$private_internal_ip"\"', netmask: '\""$private_subnet_mask"\"'/' Vagrantfile
    sed -i 's/^.*eth_replace0.*$/  config.vm.network "private_network", virtualbox__intnet: "my_admin_network", ip: '\""$admin_internal_ip"\"', netmask: '\""$private_subnet_mask"\"'/' Vagrantfile
    remove_vagrant_network eth_replace3
    deployment_type=three_network
  else
     echo "${blue}Single network or 2 network detected for baremetal deployment.  This is unsupported! Exiting. ${reset}"
     exit 1
  fi
elif [ "$if_counter" == 3 ]; then
  deployment_type="three_network"
  remove_vagrant_network eth_replace3
else
  deployment_type="multi_network"
fi

echo "${blue}Network detected: ${deployment_type}! ${reset}"

if [ $virtual ]; then
  if [ $no_dhcp ]; then
    sed -i 's/^.*disable_dhcp_flag =.*$/  disable_dhcp_flag = true/' Vagrantfile
    if [ $static_ip_range ]; then
      ##verify static range is at least 20 IPs
      static_ip_range_begin=$(echo $static_ip_range | cut -d , -f1)
      static_ip_range_end=$(echo $static_ip_range | cut -d , -f2)
      ##verify range is at least 20 ips
      ##assumes less than 255 range pool
      begin_octet=$(echo $static_ip_range_begin | cut -d . -f4)
      end_octet=$(echo $static_ip_range_end | cut -d . -f4)
      ip_count=$((end_octet-begin_octet+1))
      if [ "$ip_count" -lt 20 ]; then
        echo "${red}Static range is less than 20 ips: ${ip_count}, exiting  ${reset}"
        exit 1
      else
        echo "${blue}Static IP range is size $ip_count ${reset}"
      fi
    fi
  fi
fi

if route | grep default; then
  echo "${blue}Default Gateway Detected ${reset}"
  host_default_gw=$(ip route | grep default | awk '{print $3}')
  echo "${blue}Default Gateway: $host_default_gw ${reset}"
  default_gw_interface=$(ip route get $host_default_gw | awk '{print $3}')
  case "${interface_arr[$default_gw_interface]}" in
           0)
             echo "${blue}Default Gateway Detected on Admin Interface!${reset}"
             sed -i 's/^.*default_gw =.*$/  default_gw = '\""$host_default_gw"\"'/' Vagrantfile
             node_default_gw=$host_default_gw
             ;;
           1)
             echo "${red}Default Gateway Detected on Private Interface!${reset}"
             echo "${red}Private subnet should be private and not have Internet access!${reset}"
             exit 1
             ;;
           2)
             echo "${blue}Default Gateway Detected on Public Interface!${reset}"
             sed -i 's/^.*default_gw =.*$/  default_gw = '\""$host_default_gw"\"'/' Vagrantfile
             echo "${blue}Will setup NAT from Admin -> Public Network on VM!${reset}"
             sed -i 's/^.*nat_flag =.*$/  nat_flag = true/' Vagrantfile
             echo "${blue}Setting node gateway to be VM Admin IP${reset}"
             node_default_gw=${interface_ip_arr[0]}
             public_gateway=$default_gw
             ;;
           3)
             echo "${red}Default Gateway Detected on Storage Interface!${reset}"
             echo "${red}Storage subnet should be private and not have Internet access!${reset}"
             exit 1
             ;;
           *)
             echo "${red}Unable to determine which interface default gateway is on..Exiting!${reset}"
             exit 1
             ;;
  esac
else
  #assumes 24 bit mask
  defaultgw=`echo ${interface_ip_arr[0]} | cut -d. -f1-3`
  firstip=.1
  defaultgw=$defaultgw$firstip
  echo "${blue}Unable to find default gateway.  Assuming it is $defaultgw ${reset}"
  sed -i 's/^.*default_gw =.*$/  default_gw = '\""$defaultgw"\"'/' Vagrantfile
  node_default_gw=$defaultgw
fi

if [ $base_config ]; then
  if ! cp -f $base_config opnfv_ksgen_settings.yml; then
    echo "{red}ERROR: Unable to copy $base_config to opnfv_ksgen_settings.yml${reset}"
    exit 1
  fi
fi

if [ $no_parse ]; then
echo "${blue}Skipping parsing variables into settings file as no_parse flag is set${reset}"

else

echo "${blue}Gathering network parameters for Target System...this may take a few minutes${reset}"
##Edit the ksgen settings appropriately
##ksgen settings will be stored in /vagrant on the vagrant machine
##if single node deployment all the variables will have the same ip
##interface names will be enp0s3, enp0s8, enp0s9 in chef/centos7

sed -i 's/^.*default_gw:.*$/default_gw:'" $node_default_gw"'/' opnfv_ksgen_settings.yml

##replace private interface parameter
##private interface will be of hosts, so we need to know the provisioned host interface name
##we add biosdevname=0, net.ifnames=0 to the kickstart to use regular interface naming convention on hosts
##replace IP for parameters with next IP that will be given to controller
if [ "$deployment_type" == "single_network" ]; then
  ##we also need to assign IP addresses to nodes
  ##for single node, foreman is managing the single network, so we can't reserve them
  ##not supporting single network anymore for now
  echo "{blue}Single Network type is unsupported right now.  Please check your interface configuration.  Exiting. ${reset}"
  exit 0

elif [[ "$deployment_type" == "multi_network" || "$deployment_type" == "three_network" ]]; then

  if [ "$deployment_type" == "three_network" ]; then
    sed -i 's/^.*network_type:.*$/network_type: three_network/' opnfv_ksgen_settings.yml
  fi

  sed -i 's/^.*deployment_type:.*$/  deployment_type: '"$deployment_type"'/' opnfv_ksgen_settings.yml

  ##get ip addresses for private network on controllers to make dhcp entries
  ##required for controllers_ip_array global param
  next_private_ip=${interface_ip_arr[1]}
  type=_private
  control_count=0
  for node in controller1 controller2 controller3; do
    next_private_ip=$(next_usable_ip $next_private_ip)
    if [ ! "$next_private_ip" ]; then
       printf '%s\n' 'deploy.sh: Unable to find next ip for private network for control nodes' >&2
       exit 1
    fi
    sed -i 's/'"$node$type"'/'"$next_private_ip"'/g' opnfv_ksgen_settings.yml
    controller_ip_array=$controller_ip_array$next_private_ip,
    controllers_ip_arr[$control_count]=$next_private_ip
    ((control_count++))
  done

  next_public_ip=${interface_ip_arr[2]}
  foreman_ip=$next_public_ip

  ##if no dhcp, find all the Admin IPs for nodes in advance
  if [ $virtual ]; then
    sed -i 's/^.*no_dhcp:.*$/no_dhcp: true/' opnfv_ksgen_settings.yml
    nodes=`sed -nr '/nodes:/{:start /workaround/!{N;b start};//p}' opnfv_ksgen_settings.yml | sed -n '/^  [A-Za-z0-9]\+:$/p' | sed 's/\s*//g' | sed 's/://g'`
    compute_nodes=`echo $nodes | tr " " "\n" | grep -v controller | tr "\n" " "`
    controller_nodes=`echo $nodes | tr " " "\n" | grep controller | tr "\n" " "`
    nodes=${controller_nodes}${compute_nodes}
    next_admin_ip=${interface_ip_arr[0]}
    type=_admin
    for node in ${nodes}; do
      next_admin_ip=$(next_ip $next_admin_ip)
      if [ ! "$next_admin_ip" ]; then
        echo "${red} Unable to find an unused IP in admin_network for $node ! ${reset}"
        exit 1
      else
        admin_ip_arr[$node]=$next_admin_ip
        sed -i 's/'"$node$type"'/'"$next_admin_ip"'/g' opnfv_ksgen_settings.yml
      fi
    done
    if [ $no_dhcp ]; then
      ##allocate node public IPs
      for node in ${nodes}; do
        next_public_ip=$(next_usable_ip $next_public_ip)
        if [ ! "$next_public_ip" ]; then
          echo "${red} Unable to find an unused IP in admin_network for $node ! ${reset}"
          exit 1
        else
          public_ip_arr[$node]=$next_public_ip
        fi
      done
    fi
  fi
  ##replace global param for controllers_ip_array
  controller_ip_array=${controller_ip_array%?}
  sed -i 's/^.*controllers_ip_array:.*$/  controllers_ip_array: '"$controller_ip_array"'/' opnfv_ksgen_settings.yml

  ##now replace all the VIP variables.  admin//private can be the same IP
  ##we have to use IP's here that won't be allocated to hosts at provisioning time
  ##therefore we increment the ip by 10 to make sure we have a safe buffer
  next_private_ip=$(increment_ip $next_private_ip 10)

  private_output=$(grep -E '*private_vip|loadbalancer_vip|db_vip|amqp_vip|*admin_vip' opnfv_ksgen_settings.yml)
  if [ ! -z "$private_output" ]; then
    while read -r line; do
      sed -i 's/^.*'"$line"'.*$/  '"$line $next_private_ip"'/' opnfv_ksgen_settings.yml
      next_private_ip=$(next_usable_ip $next_private_ip)
      if [ ! "$next_private_ip" ]; then
        printf '%s\n' 'deploy.sh: Unable to find next ip for private network for vip replacement' >&2
        exit 1
      fi
    done <<< "$private_output"
  fi

  ##replace odl_control_ip (non-HA only)
  odl_control_ip=${controllers_ip_arr[0]}
  sed -i 's/^.*odl_control_ip:.*$/  odl_control_ip: '"$odl_control_ip"'/' opnfv_ksgen_settings.yml

  ##replace controller_ip (non-HA only)
  sed -i 's/^.*controller_ip:.*$/  controller_ip: '"$odl_control_ip"'/' opnfv_ksgen_settings.yml

  ##replace foreman site
  sed -i 's/^.*foreman_url:.*$/  foreman_url:'" https:\/\/$foreman_ip"'\/api\/v2\//' opnfv_ksgen_settings.yml
  ##replace public vips
  ##no need to do this if virtual and no dhcp
  if [ -z $no_dhcp ]; then
    next_public_ip=$(increment_ip $next_public_ip 10)
  else
    next_public_ip=$(next_usable_ip $next_public_ip)
  fi

  public_output=$(grep -E '*public_vip' opnfv_ksgen_settings.yml)
  if [ ! -z "$public_output" ]; then
    while read -r line; do
      if echo $line | grep horizon_public_vip; then
        horizon_public_vip=$next_public_ip
      fi
      sed -i 's/^.*'"$line"'.*$/  '"$line $next_public_ip"'/' opnfv_ksgen_settings.yml
      next_public_ip=$(next_usable_ip $next_public_ip)
      if [ ! "$next_public_ip" ]; then
        printf '%s\n' 'deploy.sh: Unable to find next ip for public network for vip replcement' >&2
        exit 1
      fi
    done <<< "$public_output"
  fi

  ##replace public_network param
  public_subnet=$(find_subnet $next_public_ip $public_subnet_mask)
  sed -i 's/^.*public_network:.*$/  public_network:'" $public_subnet"'/' opnfv_ksgen_settings.yml
  ##replace private_network param
  private_subnet=$(find_subnet $next_private_ip $private_subnet_mask)
  sed -i 's/^.*private_network:.*$/  private_network:'" $private_subnet"'/' opnfv_ksgen_settings.yml
  ##replace storage_network
  if [ "$deployment_type" == "three_network" ]; then
    sed -i 's/^.*storage_network:.*$/  storage_network:'" $private_subnet"'/' opnfv_ksgen_settings.yml
  else
    next_storage_ip=${interface_ip_arr[3]}
    storage_subnet=$(find_subnet $next_storage_ip $storage_subnet_mask)
    sed -i 's/^.*storage_network:.*$/  storage_network:'" $storage_subnet"'/' opnfv_ksgen_settings.yml
  fi

  ##replace public_subnet param
  public_subnet=$public_subnet'\'$public_short_subnet_mask
  sed -i 's/^.*public_subnet:.*$/  public_subnet:'" $public_subnet"'/' opnfv_ksgen_settings.yml
  ##replace private_subnet param
  private_subnet=$private_subnet'\'$private_short_subnet_mask
  sed -i 's/^.*private_subnet:.*$/  private_subnet:'" $private_subnet"'/' opnfv_ksgen_settings.yml

  ##replace public_dns param to be foreman server
  sed -i 's/^.*public_dns:.*$/  public_dns: '${interface_ip_arr[2]}'/' opnfv_ksgen_settings.yml

  ##replace public_gateway
  if [ -z "$public_gateway" ]; then
    ##if unset then we assume its the first IP in the public subnet
    public_subnet=$(find_subnet $next_public_ip $public_subnet_mask)
    public_gateway=$(increment_subnet $public_subnet 1)
  fi
  sed -i 's/^.*public_gateway:.*$/  public_gateway:'" $public_gateway"'/' opnfv_ksgen_settings.yml

  ##we have to define an allocation range of the public subnet to give
  ##to neutron to use as floating IPs
  ##we should control this subnet, so this range should work .150-200
  ##but generally this is a bad idea and we are assuming at least a /24 subnet here
  ##if static ip range, then we take the difference of the end range and current ip
  ## to be the allocation pool
  public_subnet=$(find_subnet $next_public_ip $public_subnet_mask)
  if [ ! -z "$static_ip_range" ]; then
    begin_octet=$(echo $next_public_ip | cut -d . -f4)
    end_octet=$(echo $static_ip_range_end | cut -d . -f4)
    ip_diff=$((end_octet-begin_octet))
    if [ $ip_diff -le 0 ]; then
      echo "${red}ip range left for floating range is less than or equal to 0! $ipdiff ${reset}"
      exit 1
    else
      public_allocation_start=$(next_ip $next_public_ip)
      public_allocation_end=$static_ip_range_end
      echo "${blue}Neutron Floating IP range: $public_allocation_start to $public_allocation_end ${reset}"
    fi
  else
    public_allocation_start=$(increment_subnet $public_subnet 150)
    public_allocation_end=$(increment_subnet $public_subnet 200)
    echo "${blue}Neutron Floating IP range: $public_allocation_start to $public_allocation_end ${reset}"
    echo "${blue}Foreman VM is up! ${reset}"
  fi

  sed -i 's/^.*public_allocation_start:.*$/  public_allocation_start:'" $public_allocation_start"'/' opnfv_ksgen_settings.yml
  sed -i 's/^.*public_allocation_end:.*$/  public_allocation_end:'" $public_allocation_end"'/' opnfv_ksgen_settings.yml

else
  printf '%s\n' 'deploy.sh: Unknown network type: $deployment_type' >&2
  exit 1
fi

echo "${blue}Parameters Complete.  Settings have been set for Foreman. ${reset}"

fi

if [ $virtual ]; then
  echo "${blue} Virtual flag detected, setting Khaleesi playbook to be opnfv-vm.yml ${reset}"
  sed -i 's/opnfv.yml/opnfv-vm.yml/' bootstrap.sh
fi

echo "${blue}Starting Vagrant! ${reset}"

##stand up vagrant
if ! vagrant up; then
  printf '%s\n' 'deploy.sh: Unable to start vagrant' >&2
  exit 1
else
  echo "${blue}Foreman VM is up! ${reset}"
fi

if [ $virtual ]; then

##Bring up VM nodes
echo "${blue}Setting VMs up... ${reset}"
nodes=`sed -nr '/nodes:/{:start /workaround/!{N;b start};//p}' opnfv_ksgen_settings.yml | sed -n '/^  [A-Za-z0-9]\+:$/p' | sed 's/\s*//g' | sed 's/://g'`
##due to ODL Helium bug of OVS connecting to ODL too early, we need controllers to install first
##this is fix kind of assumes more than I would like to, but for now it should be OK as we always have
##3 static controllers
compute_nodes=`echo $nodes | tr " " "\n" | grep -v controller | tr "\n" " "`
controller_nodes=`echo $nodes | tr " " "\n" | grep controller | tr "\n" " "`
nodes=${controller_nodes}${compute_nodes}
controller_count=0
compute_wait_completed=false

for node in ${nodes}; do
  cd /tmp

  ##remove VM nodes incase it wasn't cleaned up
  rm -rf /tmp/$node

  ##clone bgs vagrant
  ##will change this to be opnfv repo when commit is done
  if ! git clone https://github.com/trozet/bgs_vagrant.git $node; then
    printf '%s\n' 'deploy.sh: Unable to clone vagrant repo' >&2
    exit 1
  fi

  cd $node

  if [ $base_config ]; then
    if ! cp -f $base_config opnfv_ksgen_settings.yml; then
      echo "${red}ERROR: Unable to copy $base_config to opnfv_ksgen_settings.yml${reset}"
      exit 1
    fi
  fi

  ##parse yaml into variables
  eval $(parse_yaml opnfv_ksgen_settings.yml "config_")
  ##find node type
  node_type=config_nodes_${node}_type
  node_type=$(eval echo \$$node_type)

  ##trozet test make compute nodes wait 20 minutes
  if [ "$compute_wait_completed" = false ] && [ "$node_type" != "controller" ]; then
    echo "${blue}Waiting 20 minutes for Control nodes to install before continuing with Compute nodes..."
    compute_wait_completed=true
    sleep 1400
  fi

  ##find number of interfaces with ip and substitute in VagrantFile
  output=`ifconfig | grep -E "^[a-zA-Z0-9]+:"| grep -Ev "lo|tun|virbr|vboxnet" | awk '{print $1}' | sed 's/://'`

  if [ ! "$output" ]; then
    printf '%s\n' 'deploy.sh: Unable to detect interfaces to bridge to' >&2
    exit 1
  fi


  if_counter=0
  for interface in ${output}; do

    if [ $no_dhcp ]; then
      if [ "$if_counter" -ge 1 ]; then
        break
      fi
    elif [ "$if_counter" -ge 4 ]; then
      break
    fi
    interface_ip=$(find_ip $interface)
    if [ ! "$interface_ip" ]; then
      continue
    fi
    case "${if_counter}" in
           0)
             mac_string=config_nodes_${node}_mac_address
             mac_addr=$(eval echo \$$mac_string)
             mac_addr=$(echo $mac_addr | sed 's/:\|-//g')
             if [ $mac_addr == "" ]; then
                 echo "${red} Unable to find mac_address for $node! ${reset}"
                 exit 1
             fi
             ;;
           1)
             if [ "$node_type" == "controller" ]; then
               mac_string=config_nodes_${node}_private_mac
               mac_addr=$(eval echo \$$mac_string)
               if [ $mac_addr == "" ]; then
                 echo "${red} Unable to find private_mac for $node! ${reset}"
                 exit 1
               fi
             else
               ##generate random mac
               mac_addr=$(echo -n 00-60-2F; dd bs=1 count=3 if=/dev/random 2>/dev/null |hexdump -v -e '/1 "-%02X"')
             fi
             mac_addr=$(echo $mac_addr | sed 's/:\|-//g')
             ;;
           *)
             mac_addr=$(echo -n 00-60-2F; dd bs=1 count=3 if=/dev/random 2>/dev/null |hexdump -v -e '/1 "-%02X"')
             mac_addr=$(echo $mac_addr | sed 's/:\|-//g')
             ;;
    esac
    this_admin_ip=${admin_ip_arr[$node]}
    sed -i 's/^.*eth_replace'"$if_counter"'.*$/  config.vm.network "private_network", virtualbox__intnet: "my_admin_network", ip: '\""$this_admin_ip"\"', netmask: '\""$admin_subnet_mask"\"', :mac => '\""$mac_addr"\"'/' Vagrantfile
    ((if_counter++))
  done

  ##now remove interface config in Vagrantfile for 1 node
  ##if 1, 3, or 4 interfaces set deployment type
  ##if 2 interfaces remove 2nd interface and set deployment type
  if [[ "$if_counter" == 1 || "$if_counter" == 2 ]]; then
    deployment_type="single_network"
    if [ "$node_type" == "controller" ]; then
               mac_string=config_nodes_${node}_private_mac
               mac_addr=$(eval echo \$$mac_string)
               if [ $mac_addr == "" ]; then
                 echo "${red} Unable to find private_mac for $node! ${reset}"
                 exit 1
               fi
    else
               ##generate random mac
               mac_addr=$(echo -n 00-60-2F; dd bs=1 count=3 if=/dev/random 2>/dev/null |hexdump -v -e '/1 "-%02X"')
    fi
    mac_addr=$(echo $mac_addr | sed 's/:\|-//g')
    if [ "$node_type" == "controller" ]; then
      new_node_ip=${controllers_ip_arr[$controller_count]}
      if [ ! "$new_node_ip" ]; then
        echo "{red}ERROR: Empty node ip for controller $controller_count ${reset}"
        exit 1
      fi
      ((controller_count++))
    else
      next_private_ip=$(next_ip $next_private_ip)
      if [ ! "$next_private_ip" ]; then
        echo "{red}ERROR: Could not find private ip for $node ${reset}"
        exit 1
      fi
      new_node_ip=$next_private_ip
    fi
    sed -i 's/^.*eth_replace1.*$/  config.vm.network "private_network", virtualbox__intnet: "my_private_network", :mac => '\""$mac_addr"\"', ip: '\""$new_node_ip"\"', netmask: '\""$private_subnet_mask"\"'/' Vagrantfile

    ##replace host_ip in vm_nodes_provision with private ip
    sed -i 's/^host_ip=REPLACE/host_ip='$new_node_ip'/' vm_nodes_provision.sh

    ##replace ping site
    if [ ! -z "$ping_site" ]; then
      sed -i 's/www.google.com/'$ping_site'/' vm_nodes_provision.sh
    fi

    ##find public ip info
    mac_addr=$(echo -n 00-60-2F; dd bs=1 count=3 if=/dev/random 2>/dev/null |hexdump -v -e '/1 "-%02X"')
    mac_addr=$(echo $mac_addr | sed 's/:\|-//g')
    this_public_ip=${public_ip_arr[$node]}
    
    if [ $no_dhcp ]; then
      sed -i 's/^.*eth_replace2.*$/  config.vm.network "public_network", bridge: '\'"$public_interface"\'', :mac => '\""$mac_addr"\"', ip: '\""$this_public_ip"\"', netmask: '\""$public_subnet_mask"\"'/' Vagrantfile
    else
      sed -i 's/^.*eth_replace2.*$/  config.vm.network "public_network", bridge: '\'"$public_interface"\'', :mac => '\""$mac_addr"\"'/' Vagrantfile
    fi

    remove_vagrant_network eth_replace3
  elif [ "$if_counter" == 3 ]; then
    deployment_type="three_network"
    remove_vagrant_network eth_replace3
  else
    deployment_type="multi_network"
  fi

  ##modify provisioning to do puppet install, config, and foreman check-in
  ##substitute host_name and dns_server in the provisioning script
  host_string=config_nodes_${node}_hostname
  host_name=$(eval echo \$$host_string)
  sed -i 's/^host_name=REPLACE/host_name='$host_name'/' vm_nodes_provision.sh
  ##dns server should be the foreman server
  sed -i 's/^dns_server=REPLACE/dns_server='${interface_ip_arr[0]}'/' vm_nodes_provision.sh

  ## remove bootstrap and NAT provisioning
  sed -i '/nat_setup.sh/d' Vagrantfile
  sed -i 's/bootstrap.sh/vm_nodes_provision.sh/' Vagrantfile

  ## modify default_gw to be node_default_gw
  sed -i 's/^.*default_gw =.*$/  default_gw = '\""$node_default_gw"\"'/' Vagrantfile

  ## modify VM memory to be 4gig
  ##if node type is controller
  if [ "$node_type" == "controller" ]; then
    sed -i 's/^.*vb.memory =.*$/     vb.memory = 4096/' Vagrantfile
  fi
  echo "${blue}Starting Vagrant Node $node! ${reset}"

  ##stand up vagrant
  if ! vagrant up; then
    echo "${red} Unable to start $node ${reset}"
    exit 1
  else
    echo "${blue} $node VM is up! ${reset}"
  fi

done

  echo "${blue} All VMs are UP! ${reset}"
  echo "${blue} Waiting for puppet to complete on the nodes... ${reset}"
  ##check puppet is complete
  ##ssh into foreman server, run check to verify puppet is complete
  pushd /tmp/bgs_vagrant
  if ! vagrant ssh -c "/opt/khaleesi/run.sh --no-logs --use /vagrant/opnfv_ksgen_settings.yml /opt/khaleesi/playbooks/validate_opnfv-vm.yml"; then
    echo "${red} Failed to validate puppet completion on nodes ${reset}"
    exit 1
  else
    echo "{$blue} Puppet complete on all nodes! ${reset}"
  fi
  popd

  ##add routes back to nodes
  for node in ${nodes}; do
    pushd /tmp/$node
    if ! vagrant ssh -c "route | grep default | grep $this_default_gw"; then
      echo "${blue} Adding public route back to $node! ${reset}"
      vagrant ssh -c "route add default gw $this_default_gw"
    fi
    popd
  done

  if [ ! -z "$horizon_public_vip" ]; then
    echo "${blue} Virtual deployment SUCCESS!! Foreman URL:  http://${foreman_ip}, Horizon URL: http://${horizon_public_vip} ${reset}"
  else
    echo "${blue} Virtual deployment SUCCESS!! Foreman URL:  http://${foreman_ip}, Horizon URL: http://${odl_control_ip} ${reset}"
  fi
fi
