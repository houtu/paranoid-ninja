#!/usr/bin/env bash

# fail on void variable and error
set -ue

IPT=iptables
BACKUP_FILES="/etc/tor/torrc /etc/resolv.conf"
SHOW_LOG=true

####################################################
# Check Bins

checkBins modprobe iptables ip systemctl
checkRoot

####################################################
# Command line parser

while [ "$#" -gt 0 ] ; do
  case "$1" in
    -c | --conf) CONF=$2 ; shift ; shift ;;
    *) die "$0 unknown arg $1"
  esac
done

####################################################
# Check network device and ip

IF=$net_device
INT_ADDR=$(ip a show $IF | grep -Eo '[0-9.]+/[0-9]+' | sed 's:/[0-9]*::' | head -n 1)
INT_NET=$(ipcalc $INT_ADDR | grep -i 'network:' | awk '{print $2}')

[[ -z $IF ]] && die "Device network UP no found"
[[ -z $INT_NET ]] && die "Ip addr no found"

echo "[*] Found interface $IF | ip $INT_NET"

####################################################
# Tor uid

tor_uid=$(searchTorUid)

####################################################
# backupFiles

backupFiles "$BACKUP_FILES"

####################################################
# TOR vars

readonly torrc="/etc/tor/torrc"

[[ ! -f $torrc ]] && die "$torrc no found, TOR isn't install ?"

# Tor transport
if ! grep TransPort $torrc > /dev/null ; then
  echo "[*] Add new TransPort 9040 to $torrc"
  echo "TransPort 9040 IsolateClientAddr IsolateClientProtocol IsolateDestAddr IsolateDestPort" >> $torrc
fi
readonly trans_port=$(grep TransPort $torrc | awk '{print $2}')

# Tor DNSPort
if ! grep "^DNSPort" $torrc > /dev/null ; then
  echo "[*] Add new DNSPort 5353 to $torrc"
  echo "DNSPort 5353" >> $torrc
fi
readonly dns_port=$(grep DNSPort $torrc | awk '{print $2}')

# Tor AutomapHostsOnResolve
if ! grep AutomapHostsOnResolve $torrc > /dev/null ; then
  echo "[*] Add new AutomapHostsOnResolve 1 to $torrc"
  echo "AutomapHostsOnResolve 1" >> $torrc
fi

# Tor VirtualAddrNetworkIPv4
if ! grep VirtualAddrNetworkIPv4 $torrc > /dev/null ; then
  echo "[*] Add VirtualAddrNetworkIPv4 10.192.0.0/10 to $torrc"
  echo "VirtualAddrNetworkIPv4 10.192.0.0/10" >> $torrc
fi
readonly virt_tor=$(grep VirtualAddrNetworkIPv4 $torrc | awk '{print $2}')

# LAN destination, shouldn't be routed through Tor
readonly non_tor="127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 $docker_ipv4 192.168.0.0/16 192.168.99.0/16 $INT_NET"

# other IANA reserved blocks
readonly resv_iana="0.0.0.0/8 100.64.0.0/10 169.254.0.0/16 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4 255.255.255.255/32"

# Just to be sure :)
[[ -z $trans_port ]] && die "No TransPort value found on $torrc"
[[ -z $dns_port ]] && die "No DNSPort value found on $torrc"
[[ -z $virt_tor ]] && die "No VirtualAddrNetworkIPv4 value found on $torrc"

####################################################
# resolv.conf

echo "[+] Update /etc/resolv.conf"
if $tor_proxy ; then
cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
EOF
else
cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
EOF
fi

####################################################
# load modules

# Look which system need
modprobe ip_tables iptable_nat ip_conntrack iptable-filter ipt_state

####################################################
# Options

if [[ $firewall_quiet =~ ^y|^Y|^t|^T ]] ; then
  SHOW_LOG=false
fi

####################################################
# Flushing rules

echo "[+] Flushing existing rules..."
clearIptables

echo "[+] Setting up $firewall rules ..."

icmp_rules() {
  # Create ICMP incoming chain
  $IPT -N ICMP_IN
  $IPT -A INPUT -p icmp -j ICMP_IN
  # ICMP for incoming traffic
  $IPT -A ICMP_IN -i $IF -p icmp --icmp-type 0 -m state --state ESTABLISHED,RELATED -j ACCEPT
  $IPT -A ICMP_IN -i $IF -p icmp --icmp-type 3 -m state --state ESTABLISHED,RELATED -j ACCEPT
  $IPT -A ICMP_IN -i $IF -p icmp --icmp-type 11 -m state --state ESTABLISHED,RELATED -j ACCEPT
  if $SHOW_LOG ; then
    $IPT -A ICMP_IN -i $IF -p icmp -j LOG --log-prefix "IPT: ICMP_IN "
  fi
  $IPT -A ICMP_IN -i $IF -p icmp -j DROP

  # Create ICMP outgoing chain
  $IPT -N ICMP_OUT
  $IPT -A OUTPUT -p icmp -j ICMP_OUT
  # ICMP for outgoing traffic
  $IPT -A ICMP_OUT -o $IF -p icmp --icmp-type 8 -m state --state NEW -j ACCEPT
  if $SHOW_LOG ; then
    $IPT -A ICMP_OUT -o $IF -p icmp -j LOG --log-prefix "IPT: ICMP_OUT "
  fi
  $IPT -A ICMP_OUT -o $IF -p icmp -j DROP
}

bad_sources() {
  # bad source chain
  $IPT -N BAD_SOURCES
  # pass traffic with bad src addresses to the Bad Sources Chain
  $IPT -A INPUT -j BAD_SOURCES
  # drop incoming traffic from our own host
  if $SHOW_LOG ; then
    $IPT -A BAD_SOURCES -i $IF -s $INT_ADDR -j LOG --log-prefix "SPOOFED PKT "
    $IPT -A BAD_SOURCES -o $IF ! -s $INT_ADDR -j LOG --log-prefix "SPOOFED PKT "
  fi
  # drop incoming allegedly from our host
  $IPT -A BAD_SOURCES -i $IF -s $INT_ADDR -j DROP
  # drop outgoing traffic not from our own host
  $IPT -A BAD_SOURCES -o $IF ! -s $INT_ADDR -j DROP
  # drop other bad sources
  for lan in $non_tor ; do
    $IPT -A BAD_SOURCES -i $IF -s $lan -j DROP
  done
  for iana in $resv_iana ; do
    $IPT -A BAD_SOURCES -i $IF -s $iana -j DROP
  done
}

# block bad tcp flags if secure_rules="yes"
secure_rules() {
  # bad flag chain
  $IPT -N BAD_FLAGS
  # pass traffic with bad flags to the bad flag chain
  $IPT -A INPUT -p tcp -j BAD_FLAGS
  if $SHOW_LOG ; then
    $IPT -A BAD_FLAGS -p tcp --tcp-flags SYN,FIN SYN,FIN -j LOG --log-prefix "IPT: Bad SF Flag "
    $IPT -A BAD_FLAGS -p tcp --tcp-flags SYN,RST SYN,RST -j LOG --log-prefix "IPT: Bad SR Flag "
    $IPT -A BAD_FLAGS -p tcp --tcp-flags SYN,FIN,PSH SYN,FIN,PSH -j LOG --log-prefix "IPT: Bad SFP Flag "
    $IPT -A BAD_FLAGS -p tcp --tcp-flags SYN,FIN,RST SYN,FIN,RST -j LOG --log-prefix "IPT: Bad SFR Flag "
    $IPT -A BAD_FLAGS -p tcp --tcp-flags SYN,FIN,RST,PSH SYN,FIN,RST,PSH -j LOG --log-prefix "IPT: Bad SFRP Flag "
    $IPT -A BAD_FLAGS -p tcp --tcp-flags FIN FIN -j LOG --log-prefix "IPT: Bad F Flag "
    $IPT -A BAD_FLAGS -p tcp --tcp-flags ALL NONE -j LOG --log-prefix "IPT: Null Flag "
    $IPT -A BAD_FLAGS -p tcp --tcp-flags ALL ALL -j LOG --log-prefix "IPT: All Flags "
    $IPT -A BAD_FLAGS -p tcp --tcp-flags ALL FIN,URG,PSH -j LOG --log-prefix "IPT: Nmap:Xmas Flags "
    $IPT -A BAD_FLAGS -p tcp --tcp-flags ALL RST,ACK,FIN,URG -j LOG --log-prefix "IPT: Merry Xmas Flags "
  fi
  $IPT -A BAD_FLAGS -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
  $IPT -A BAD_FLAGS -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
  $IPT -A BAD_FLAGS -p tcp --tcp-flags SYN,FIN,PSH SYN,FIN,PSH -j DROP
  $IPT -A BAD_FLAGS -p tcp --tcp-flags SYN,FIN,RST SYN,FIN,RST -j DROP
  $IPT -A BAD_FLAGS -p tcp --tcp-flags SYN,FIN,RST,PSH SYN,FIN,RST,PSH -j DROP
  $IPT -A BAD_FLAGS -p tcp --tcp-flags FIN FIN -j DROP
  $IPT -A BAD_FLAGS -p tcp --tcp-flags ALL NONE -j DROP
  $IPT -A BAD_FLAGS -p tcp --tcp-flags ALL ALL -j DROP
  $IPT -A BAD_FLAGS -p tcp --tcp-flags ALL FIN,URG,PSH -j DROP
  $IPT -A BAD_FLAGS -p tcp --tcp-flags ALL RST,ACK,FIN,URG -j DROP
}

if [ $secure_rules == "yes" ] ; then 
  icmp_rules
  bad_sources
  secure_rules
fi

tor_proxy() {
  # bad flag chain
  $IPT -N TOR_PROXY
  # pass traffic with bad flags to the bad flag chain
  $IPT -A OUTPUT -j TOR_PROXY

  echo "Active transparent proxy throught tor"
  echo "Nat rules tor_uid: $tor_uid, dns: $dns_port, trans: $trans_port, virt: $virt_tor"

  $IPT -t nat -A PREROUTING ! -i lo -p udp -m udp --dport 53 -j REDIRECT --to-ports $dns_port
  #$IPT -t nat -A PREROUTING ! -i lo -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -j REDIRECT --to-ports $trans_port

  $IPT -t nat -A OUTPUT -m owner --uid-owner $tor_uid -j RETURN

  $IPT -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports $dns_port
  $IPT -t nat -A OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports $dns_port
  $IPT -t nat -A OUTPUT -m owner --uid-owner $tor_uid -p udp --dport 53 -j REDIRECT --to-ports $dns_port

  $IPT -t nat -A OUTPUT -p tcp -d $virt_tor -j REDIRECT --to-ports $trans_port
  $IPT -t nat -A OUTPUT -p udp -d $virt_tor -j REDIRECT --to-ports $trans_port

  # Do not torrify torrent - not sure this is required
  $IPT -t nat -A OUTPUT -p udp -m multiport --dports 6881,6882,6883,6884,6885,6886 -j RETURN

  # Don't nat the tor process on local network
  $IPT -t nat -A OUTPUT -o lo -j RETURN

  # Allow lan access for non_tor 
  for lan in $non_tor 127.0.0.0/9 127.128.0.0/10; do
    $IPT -t nat -A OUTPUT -d $lan -j RETURN
  done

  for iana in $resv_iana ; do
    $IPT -t nat -A OUTPUT -d $iana -j RETURN
  done

  # Redirect all other output to TOR
  $IPT -t nat -A OUTPUT -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -j REDIRECT --to-ports $trans_port
  $IPT -t nat -A OUTPUT -p icmp -j REDIRECT --to-ports $trans_port
  $IPT -t nat -A OUTPUT -p udp -j REDIRECT --to-ports $trans_port

  $IPT -A OUTPUT -p tcp --dport 8890 --syn -m state --state NEW -j ACCEPT # sshuttle
  $IPT -A INPUT -p tcp --sport 8890 --syn -m state --state NEW -j ACCEPT # sshuttle

  $IPT -A TOR_PROXY -o $IF -m owner --uid-owner $tor_uid -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -m state --state NEW -j ACCEPT

  # tor transparent magic
  $IPT -A TOR_PROXY -d 127.0.0.1/32 -p tcp -m tcp --dport $trans_port --tcp-flags FIN,SYN,RST,ACK SYN -j ACCEPT
}

# Start tor proxy if enable, else try to launch sshuttle and else you're naked :)
if $tor_proxy ; then
  [ $sshuttle_use == "yes" ] && {
    if systemctl is-active $sshuttle_service_name > /dev/null ; then 
      systemctl stop $sshuttle_service_name
    fi
  }
  tor_proxy
elif [ $sshuttle_use == "yes" ] ; then
  if ! systemctl is-active $sshuttle_service_name > /dev/null ; then 
    systemctl start $sshuttle_service_name
  fi
fi

docker_rules() {
  # Create the DOCKER-CUSTOM
  $IPT -N DOCKER_IN
  $IPT -N DOCKER_OUT
  $IPT -A INPUT -j DOCKER_IN
  $IPT -A OUTPUT -j DOCKER_OUT

  for _docker_ipv4 in $docker_ipv4 ; do
    if $tor_proxy ; then
      $IPT -A DOCKER_IN -s $_docker_ipv4 -d $_docker_ipv4 -p tcp -m tcp --dport 9040 -j ACCEPT
    fi
    $IPT -A DOCKER_IN -s $_docker_ipv4 -d $_docker_ipv4 -p udp -m udp --dport 5353 -j ACCEPT # docker with nodejs
    $IPT -A DOCKER_IN -d "$_docker_ipv4" -p tcp -m tcp --dport 443 -j ACCEPT # docker with nodejs
    $IPT -A DOCKER_IN -s "$_docker_ipv4" -p tcp -m tcp --dport 3000 -j ACCEPT # docker with nodejs
    $IPT -A DOCKER_OUT -s $_docker_ipv4 -d $_docker_ipv4 -p udp -m udp --sport 5353 -j ACCEPT # docker with nodejs
    $IPT -A DOCKER_OUT -s "$_docker_ipv4" -d 8.8.8.8 -p udp -m udp --dport 53 -j ACCEPT # docker with nodejs
    $IPT -A DOCKER_OUT -s "$_docker_ipv4" -d 8.8.4.4 -p udp -m udp --dport 53 -j ACCEPT # docker with nodejs
    $IPT -A DOCKER_OUT -s "$_docker_ipv4" -p tcp -m tcp --dport 443 -j ACCEPT # docker with nodejs
    $IPT -A DOCKER_OUT -s "$_docker_ipv4" -p tcp -m tcp --dport 8080 -j ACCEPT # docker web
    $IPT -A DOCKER_OUT -s "$_docker_ipv4" -p tcp -m tcp --dport 80 -j ACCEPT # docker web
    # allow local server 80
    $IPT -A DOCKER_IN -i lo -p tcp -m tcp --dport 80 -j ACCEPT
    $IPT -A DOCKER_IN -i lo -d $INT_ADDR -p tcp -m tcp --sport 443 -j ACCEPT

    # allow local database on 5432 (postgres)
    $IPT -A DOCKER_OUT -s $_docker_ipv4 -d $_docker_ipv4 -p tcp -m tcp --dport 5432 -j ACCEPT
  done
}

# if Docker
if [ $docker_use == "yes" ] ; then
  docker_rules
fi

####################################################
# Input chain

if $SHOW_LOG ; then
  $IPT -A INPUT -m state --state INVALID -j LOG --log-prefix "DROP INVALID " --log-ip-options --log-tcp-options
fi
$IPT -A INPUT -m state --state INVALID -j DROP

# allow access to the Loopback host
$IPT -A INPUT -i lo -j ACCEPT
$IPT -A OUTPUT -o lo -j ACCEPT

# prevent SYN flooding
$IPT -A INPUT -i $IF -p tcp --syn -m limit --limit 5/second -j ACCEPT

$IPT -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

if ! $tor_proxy ; then
  $IPT -A INPUT -i $IF -p udp -s $INT_NET --dport $dns_port -j ACCEPT
fi

# default input log rule
if $SHOW_LOG ; then
  $IPT -A INPUT ! -i lo -j LOG --log-prefix "DROP " --log-ip-options --log-tcp-options
fi
$IPT -A INPUT -f -j DROP

####################################################
# Output chain

# Tracking rules
if $SHOW_LOG ; then
  $IPT -A OUTPUT -m state --state INVALID -j LOG --log-prefix "DROP INVALID " --log-ip-options --log-tcp-options
fi
$IPT -A OUTPUT -m state --state INVALID -j DROP

$IPT -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

if ! $tor_proxy ; then
  $IPT -A OUTPUT -o $IF -s $INT_NET -p udp -m udp --dport 53 -j ACCEPT
  $IPT -A OUTPUT -o $IF -s $INT_NET -p tcp -m tcp --dport 443 -j ACCEPT
  $IPT -A OUTPUT -o $IF -s $INT_NET -p tcp -m tcp --dport 80 -j ACCEPT
fi

# Torrents
$IPT -A OUTPUT -o $IF -p udp -m multiport --sports 6881,6882,6883,6884,6885,6886 -j ACCEPT


# sshuttle
for i in $(seq 12298 12300) ; do
  #$IPT -A OUTPUT -o $IF -d 127.0.0.1/32 -p tcp -m multiport --dports 12300,12299,12298 -j ACCEPT
  $IPT -A OUTPUT -d 127.0.0.1/32 -p tcp -m tcp --dport $i -j ACCEPT

  if [ $docker_use == "yes" ] ; then
    for _docker_ipv4 in $docker_ipv4 ; do
      $IPT -A DOCKER_IN -s "$_docker_ipv4" -d "$_docker_ipv4" -p tcp -m tcp --dport $i -j ACCEPT
      $IPT -A DOCKER_OUT -s "$_docker_ipv4" -d "$_docker_ipv4" -p tcp -m tcp --dport $i -j ACCEPT
      $IPT -A DOCKER_OUT -s "$_docker_ipv4" -d 127.0.0.1/32 -p tcp -m tcp --dport $i -j ACCEPT
      $IPT -A DOCKER_OUT -s "$_docker_ipv4" -d 127.0.0.1/32 -p udp -m udp --dport $i -j ACCEPT
    done
    #$IPT -A OUTPUT -s $INT_NET -p tcp -m tcp --dport 8443 -j ACCEPT # kubectl
    $IPT -A OUTPUT -d 192.168.99.0/16 -p tcp -m tcp --dport 8443 -j ACCEPT # kubectl
    $IPT -A INPUT -s 192.168.99.0/16 -p tcp -m tcp --sport 8443 -j ACCEPT # kubectl
    $IPT -A OUTPUT -o $IF -s $INT_ADDR -p udp -m udp --dport $i -j ACCEPT # sshuttle dns
  fi
done

# Default output log rule
if $SHOW_LOG ; then
  $IPT -A OUTPUT ! -o lo -j LOG --log-prefix "DROP " --log-ip-options --log-tcp-options
fi

####################################################
# Forward chain

# Tracking rule
if $SHOW_LOG ; then
  $IPT -A FORWARD -m state --state INVALID -j LOG --log-prefix "DROP INVALID " --log-ip-options --log-tcp-options
fi
$IPT -A FORWARD -m state --state INVALID -j DROP
$IPT -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# Default log rule
if $SHOW_LOG ; then
  $IPT -A FORWARD ! -i lo -j LOG --log-prefix "DROP " --log-ip-options --log-tcp-options
fi

####################################################
# Others rules

# ssh
$IPT -A INPUT -i $IF -p tcp -s $INT_NET --dport 22 -m state --state NEW,ESTABLISHED -j ACCEPT
$IPT -A OUTPUT -o $IF -p tcp -d $INT_NET --sport 22 -m state --state ESTABLISHED -j ACCEPT

# freenode 7000
$IPT -A OUTPUT -p tcp -m tcp --dport 7000 -j ACCEPT

echo "Setting iptable ended"
