
  Install BigBlueButton 2.6.x with a SSL certificate from Let's Encrypt using hostname bbb.example.com
  and email address info@example.com and apply a basic firewall


usage() {
    set +x
    cat 1>&2 <<HERE

Script for installing a BigBlueButton 2.6 server in under 30 minutes. It also supports upgrading a BigBlueButton server to version 2.6 (from version 2.5.0+ or an earlier 2.6.x version)

This script also supports installation of a coturn (TURN) server on a separate server.

USAGE:
    wget -qO- https://ubuntu.bigbluebutton.org/bbb-install-2.6.sh | bash -s -- [OPTIONS]

OPTIONS (install BigBlueButton):

  -v <version>           Install given version of BigBlueButton (e.g. 'focal-260') (required)

  -s <hostname>          Configure server with <hostname>
  -e <email>             Email for Let's Encrypt certbot

  -x                     Use Let's Encrypt certbot with manual dns challenges

  -g                     Install Greenlight version 3
  -k                     Install Keycloak version 20

  -c <hostname>:<secret> Configure with coturn server at <hostname> using <secret> (instead of built-in TURN server)

  -m <link_path>         Create a Symbolic link from /var/bigbluebutton to <link_path> 

  -p <host>[:<port>]     Use apt-get proxy at <host> (default port 3142)
  -r <host>              Use alternative apt repository (such as packages-eu.bigbluebutton.org)

  -d                     Skip SSL certificates request (use provided certificates from mounted volume) in /local/certs/
  -w                     Install UFW firewall (recommended)

  -j                     Allows the installation of BigBlueButton to proceed even if not all requirements [for production use] are met.
                         Note that not all requirements can be ignored. This is useful in development / testing / ci scenarios.

  -i                     Allows the installation of BigBlueButton to proceed even if Apache webserver is installed.

  -h                     Print help

OPTIONS (install Let's Encrypt certificate only):

  -s <hostname>          Configure server with <hostname> (required)
  -e <email>             Configure email for Let's Encrypt certbot (required)
  -l                     Only install Let's Encrypt certificate (not BigBlueButton)
  -x                     Use Let's Encrypt certbot with manual dns challenges (optional)

OPTIONS (install Greenlight only):

  -g                     Install Greenlight version 3 (required)
  -k                     Install Keycloak version 20 (optional)

EXAMPLES:

Sample options for setup a BigBlueButton server

    -v focal-260 -s bbb.example.com -e info@example.com
    -v focal-260 -s bbb.example.com -e info@example.com -g

SUPPORT:
    Community: https://bigbluebutton.org/support
         Docs: https://github.com/bigbluebutton/bbb-install

HERE
}

main() {
  export DEBIAN_FRONTEND=noninteractive
  PACKAGE_REPOSITORY=ubuntu.bigbluebutton.org
  LETS_ENCRYPT_OPTIONS="--webroot --non-interactive"
  SOURCES_FETCHED=false
  GL3_DIR=~/greenlight-v3
  NGINX_FILES_DEST=/usr/share/bigbluebutton/nginx
  CR_TMPFILE=$(mktemp /tmp/carriage-return.XXXXXX)
  echo "\n" > $CR_TMPFILE

  need_x64

  while builtin getopts "hs:r:c:v:e:p:m:lxgadwjik" opt "${@}"; do

    case $opt in
      h)
        usage
        exit 0
        ;;

      s)
        HOST=$OPTARG
        if [ "$HOST" == "bbb.example.com" ]; then 
          err "You must specify a valid hostname (not the hostname given in the docs)."
        fi
        ;;
      r)
        PACKAGE_REPOSITORY=$OPTARG
        ;;
      e)
        EMAIL=$OPTARG
        if [ "$EMAIL" == "info@example.com" ]; then 
          err "You must specify a valid email address (not the email in the docs)."
        fi
        ;;
      x)
        LETS_ENCRYPT_OPTIONS="--manual --preferred-challenges dns"
      ;;
      c)
        COTURN=$OPTARG
        check_coturn "$COTURN"
        ;;

      v)
        VERSION=$OPTARG
        ;;

      p)
        PROXY=$OPTARG
        if [ -n "$PROXY" ]; then
          if [[ "$PROXY" =~ : ]]; then
            echo "Acquire::http::Proxy \"http://$PROXY\";"  > /etc/apt/apt.conf.d/01proxy
          else
            echo "Acquire::http::Proxy \"http://$PROXY:3142\";"  > /etc/apt/apt.conf.d/01proxy
          fi
        fi
        ;;

      l)
        LETS_ENCRYPT_ONLY=true
        ;;
      g)
        GREENLIGHT=true
        ;;
      k)
        INSTALL_KC=true
        ;;
      a)
        err "Error: bbb-demo (API demos, '-a' option) were deprecated in BigBlueButton 2.6. Please use Greenlight or API MATE"
        ;;
      m)
        LINK_PATH=$OPTARG
        ;;
      d)
        PROVIDED_CERTIFICATE=true
        ;;
      w)
        SSH_PORT=$(grep Port /etc/ssh/ssh_config | grep -v \# | sed 's/[^0-9]*//g')
        if [[ -n "$SSH_PORT" && "$SSH_PORT" != "22" ]]; then
          err "Detected sshd not listening to standard port 22 -- unable to install default UFW firewall rules.  See https://docs.bigbluebutton.org/2.2/customize.html#secure-your-system--restrict-access-to-specific-ports"
        fi
        UFW=true
        ;;
      j)
        SKIP_MIN_SERVER_REQUIREMENTS_CHECK=true
        ;;
      i)
        SKIP_APACHE_INSTALLED_CHECK=true
        ;;

      :)
        err "Missing option argument for -$OPTARG"
        exit 1
        ;;

      \?)
        err "Invalid option: -$OPTARG" >&2
        usage
        ;;
    esac
  done

  if [ -n "$HOST" ]; then
    check_host "$HOST"
  fi

  if [ -n "$VERSION" ]; then
    check_version "$VERSION"
  fi

  if [ "$SKIP_APACHE_INSTALLED_CHECK" != true ]; then
    check_apache2
  fi

  # Check if we're installing coturn (need an e-mail address for Let's Encrypt) 
  if [ -z "$VERSION" ] && [ -n "$COTURN" ]; then
    if [ -z "$EMAIL" ]; then err "Installing coturn needs an e-mail address for Let's Encrypt"; fi
    check_ubuntu 20.04

    install_coturn
    exit 0
  fi

  if [ -z "$VERSION" ]; then
    usage
    exit 0
  fi

  if [ -n "$INSTALL_KC" ] && [ -z "$GREENLIGHT" ]; then
    err "Keycloak cannot be installed without Greenlight."
  fi

  # We're installing BigBlueButton
  env

  check_mem
  check_cpus

  need_pkg software-properties-common  # needed for add-apt-repository
  sudo add-apt-repository universe
  need_pkg wget curl gpg-agent dirmngr apparmor-utils

  # need_pkg xmlstarlet
  get_IP "$HOST"

  if [ "$DISTRO" == "focal" ]; then
    need_pkg ca-certificates

    # yq version 3 is provided by ppa:bigbluebutton/support
    # Uncomment the following to enable yq 4 after bigbluebutton/bigbluebutton#14511 is resolved
    #need_ppa rmescandon-ubuntu-yq-bionic.list         ppa:rmescandon/yq          CC86BB64 # Edit yaml files with yq

    #need_ppa libreoffice-ubuntu-ppa-focal.list       ppa:libreoffice/ppa        1378B444 # Latest version of libreoffice
    need_ppa bigbluebutton-ubuntu-support-focal.list ppa:bigbluebutton/support  E95B94BC # Needed for libopusenc0
    if ! apt-key list 5AFA7A83 | grep -q -E "1024|4096"; then   # Add Kurento package
      sudo apt-key adv --keyserver https://keyserver.ubuntu.com --recv-keys 5AFA7A83
    fi

    rm -rf /etc/apt/sources.list.d/kurento.list     # Kurento 6.15 now packaged with 2.3

    if [ -f /etc/apt/sources.list.d/nodesource.list ] &&  grep -q 12 /etc/apt/sources.list.d/nodesource.list; then 
      # Node 12 might be installed, previously used in BigBlueButton
      sudo apt-get purge nodejs
      sudo rm -r /etc/apt/sources.list.d/nodesource.list
    fi
    if [ ! -f /etc/apt/sources.list.d/nodesource.list ]; then
      curl -sL https://deb.nodesource.com/setup_16.x | sudo -E bash -
    fi
    if ! apt-cache madison nodejs | grep -q node_16; then
      err "Did not detect nodejs 16.x candidate for installation"
    fi
    if ! apt-key list MongoDB | grep -q 4.4; then
      wget -qO - https://www.mongodb.org/static/pgp/server-4.4.asc | sudo apt-key add -
    fi
    echo "deb [ arch=amd64 ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/4.4 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-4.4.list
    rm -f /etc/apt/sources.list.d/mongodb-org-4.2.list

    touch /root/.rnd
    MONGODB=mongodb-org
    install_docker		                     # needed for bbb-libreoffice-docker
    need_pkg ruby

    BBB_WEB_ETC_CONFIG=/etc/bigbluebutton/bbb-web.properties            # Override file for local settings 

    need_pkg openjdk-11-jre
    update-java-alternatives -s java-1.11.0-openjdk-amd64

    # Remove old bbb-demo if installed from a previous 2.5 setup
    if dpkg -s bbb-demo > /dev/null 2>&1; then
      apt purge -y bbb-demo tomcat9
      rm -rf /var/lib/tomcat9
    fi
  fi

  apt-get update
  apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" dist-upgrade

  need_pkg nodejs $MONGODB apt-transport-https haveged
  need_pkg bigbluebutton
  need_pkg bbb-html5

  if [ -f /usr/share/bbb-web/WEB-INF/classes/bigbluebutton.properties ]; then
    SERVLET_DIR=/usr/share/bbb-web
  fi

  while [ ! -f $SERVLET_DIR/WEB-INF/classes/bigbluebutton.properties ]; do sleep 1; echo -n '.'; done

  check_lxc
  check_nat
  check_LimitNOFILE

  configure_HTML5 

  if [ -n "$LINK_PATH" ]; then
    ln -s "$LINK_PATH" "/var/bigbluebutton"
  fi

  if [ -n "$PROVIDED_CERTIFICATE" ] ; then
    install_ssl
  elif [ -n "$HOST" ] && [ -n "$EMAIL" ] ; then
    install_ssl
  fi

  if [ -n "$GREENLIGHT" ]; then
    install_greenlight_v3
  fi

  if [ -n "$COTURN" ]; then
    configure_coturn

    if systemctl is-active --quiet haproxy.service; then
      systemctl disable --now haproxy.service
    fi
  else
    install_coturn
    install_haproxy
    systemctl enable --now haproxy.service  # In case we had previously disabled (see above)

    # The turn server will always try to connect to the BBB server's public IP address,
    # so if NAT is in use, add an iptables rule to adjust the destination IP address
    # of UDP packets sent from the turn server to FreeSWITCH.
    if [ -n "$INTERNAL_IP" ]; then
      need_pkg iptables-persistent
      iptables -t nat -A OUTPUT -p udp -s $INTERNAL_IP -d $IP -j DNAT --to-destination $INTERNAL_IP
      netfilter-persistent save
    fi
  fi

  apt-get auto-remove -y

  if systemctl status freeswitch.service | grep -q SETSCHEDULER; then
    sed -i "s/^CPUSchedulingPolicy=rr/#CPUSchedulingPolicy=rr/g" /lib/systemd/system/freeswitch.service
    systemctl daemon-reload
  fi

  systemctl restart systemd-journald

  if [ -n "$UFW" ]; then
    setup_ufw 
  fi

  if [ -n "$HOST" ]; then
    bbb-conf --setip "$HOST"
  else
    bbb-conf --setip "$IP"
  fi

  if ! systemctl show-environment | grep LANG= | grep -q UTF-8; then
    sudo systemctl set-environment LANG=C.UTF-8
  fi

  bbb-conf --check
}

say() {
  echo "bbb-install: $1"
}

err() {
  say "$1" >&2
  exit 1
}

check_root() {
  if [ $EUID != 0 ]; then err "You must run this command as root."; fi
}

check_mem() {
  if awk '$1~/MemTotal/ {exit !($2<3940000)}' /proc/meminfo; then
    echo "Your server needs to have (at least) 4G of memory."
    if [ "$SKIP_MIN_SERVER_REQUIREMENTS_CHECK" != true ]; then
      exit 1
    fi
  fi
}

check_cpus() {
  if [ "$(nproc --all)" -lt 4 ]; then
    echo "Your server needs to have (at least) 4 CPUs (8 recommended for production)."
    if [ "$SKIP_MIN_SERVER_REQUIREMENTS_CHECK" != true ]; then
      exit 1
    fi
  fi
}

check_ubuntu(){
  RELEASE=$(lsb_release -r | sed 's/^[^0-9]*//g')
  if [ "$RELEASE" != "$1" ]; then err "You must run this command on Ubuntu $1 server."; fi
}

need_x64() {
  UNAME=`uname -m`
  if [ "$UNAME" != "x86_64" ]; then err "You must run this command on a 64-bit server."; fi
}

wait_443() {
  echo "Waiting for port 443 to clear "
  # ss fields 4 and 6 are Local Address and State
  while ss -ant | awk '{print $4, $6}' | grep TIME_WAIT | grep -q ":443"; do sleep 1; echo -n '.'; done
  echo
}

get_IP() {
  if [ -n "$IP" ]; then return 0; fi

  # Determine local IP
  if [ -e "/sys/class/net/venet0:0" ]; then
    # IP detection for OpenVZ environment
    _dev="venet0:0"
  else
    _dev=$(awk '$2 == 00000000 { print $1 }' /proc/net/route | head -1)
  fi
  _ips=$(LANG=C ip -4 -br address show dev "$_dev" | awk '{ $1=$2=""; print $0 }')
  _ips=${_ips/127.0.0.1\/8/}
  read -r IP _ <<< "$_ips"
  IP=${IP/\/*} # strip subnet provided by ip address
  if [ -z "$IP" ]; then
    read -r IP _ <<< "$(hostname -I)"
  fi


  # Determine external IP 
  if grep -sqi ^ec2 /sys/devices/virtual/dmi/id/product_uuid; then
    # EC2
    local external_ip=$(wget -qO- http://169.254.169.254/latest/meta-data/public-ipv4)
  elif [ -f /var/lib/dhcp/dhclient.eth0.leases ] && grep -q unknown-245 /var/lib/dhcp/dhclient.eth0.leases; then
    # Azure
    local external_ip=$(curl -H Metadata:true "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2017-08-01&format=text")
  elif [ -f /run/scw-metadata.cache ]; then
    # Scaleway
    local external_ip=$(grep "PUBLIC_IP_ADDRESS" /run/scw-metadata.cache | cut -d '=' -f 2)
  elif which dmidecode > /dev/null && dmidecode -s bios-vendor | grep -q Google; then
    # Google Compute Cloud
    local external_ip=$(wget -O - -q "http://metadata/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" --header 'Metadata-Flavor: Google')
  elif [ -n "$1" ]; then
    # Try and determine the external IP from the given hostname
    need_pkg dnsutils
    local external_ip=$(dig +short "$1" @resolver1.opendns.com | grep '^[.0-9]*$' | tail -n1)
  fi

  # Check if the external IP reaches the internal IP
  if [ -n "$external_ip" ] && [ "$IP" != "$external_ip" ]; then
    if which nginx; then
      systemctl stop nginx
    fi

    need_pkg netcat-openbsd

    wait_443

    nc -l -p 443 > /dev/null 2>&1 &
    nc_PID=$!
    sleep 1
    
     # Check if we can reach the server through it's external IP address
     if nc -zvw3 "$external_ip" 443  > /dev/null 2>&1; then
       INTERNAL_IP=$IP
       IP=$external_ip
       echo 
       echo "  Detected this server has an internal/external IP address."
       echo 
       echo "      INTERNAL_IP: $INTERNAL_IP"
       echo "    (external) IP: $IP"
       echo 
     fi

    kill $nc_PID  > /dev/null 2>&1;

    if which nginx; then
      systemctl start nginx
    fi
  fi

  if [ -z "$IP" ]; then err "Unable to determine local IP address."; fi
}

need_pkg() {
  check_root
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do echo "Sleeping for 1 second because of dpkg lock"; sleep 1; done

  if [ ! "$SOURCES_FETCHED" = true ]; then
    apt-get update
    SOURCES_FETCHED=true
  fi

  if ! dpkg -s ${@:1} >/dev/null 2>&1; then
    LC_CTYPE=C.UTF-8 apt-get install -yq ${@:1}
  fi
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do echo "Sleeping for 1 second because of dpkg lock"; sleep 1; done
}

need_ppa() {
  need_pkg software-properties-common 
  if [ ! -f "/etc/apt/sources.list.d/$1" ]; then
    LC_CTYPE=C.UTF-8 add-apt-repository -y "$2"
  fi
  if ! apt-key list "$3" | grep -q -E "1024|4096"; then  # Let's try it a second time
    LC_CTYPE=C.UTF-8 add-apt-repository "$2" -y
    if ! apt-key list "$3" | grep -q -E "1024|4096"; then
      err "Unable to setup PPA for $2"
    fi
  fi
}

check_version() {
  if ! echo "$1" | grep -Eq "focal-26"; then err "This script can only install BigBlueButton 2.6 and is meant to be run on Ubuntu 20.04 (focal) server."; fi
  DISTRO=$(echo "$1" | sed 's/-.*//g')
  if ! wget -qS --spider "https://$PACKAGE_REPOSITORY/$1/dists/bigbluebutton-$DISTRO/Release.gpg" > /dev/null 2>&1; then
    err "Unable to locate packages for $1 at $PACKAGE_REPOSITORY."
  fi
  check_root
  need_pkg apt-transport-https
  if ! apt-key list | grep -q "BigBlueButton apt-get"; then
    wget "https://$PACKAGE_REPOSITORY/repo/bigbluebutton.asc" -O- | apt-key add -
  fi

  echo "deb https://$PACKAGE_REPOSITORY/$VERSION bigbluebutton-$DISTRO main" > /etc/apt/sources.list.d/bigbluebutton.list
}

check_host() {
  if [ -z "$PROVIDED_CERTIFICATE" ] && [ -z "$HOST" ]; then
    need_pkg dnsutils apt-transport-https
    DIG_IP=$(dig +short "$1" | grep '^[.0-9]*$' | tail -n1)
    if [ -z "$DIG_IP" ]; then err "Unable to resolve $1 to an IP address using DNS lookup.";  fi
    get_IP "$1"
    if [ "$DIG_IP" != "$IP" ]; then err "DNS lookup for $1 resolved to $DIG_IP but didn't match local $IP."; fi
  fi
}

check_coturn() {
  if ! echo "$1" | grep -q ':'; then err "Option for coturn must be <hostname>:<secret>"; fi

  COTURN_HOST=$(echo "$OPTARG" | cut -d':' -f1)
  COTURN_SECRET=$(echo "$OPTARG" | cut -d':' -f2)

  if [ -z "$COTURN_HOST" ];   then err "-c option must contain <hostname>"; fi
  if [ -z "$COTURN_SECRET" ]; then err "-c option must contain <secret>"; fi

  if [ "$COTURN_HOST" == "turn.example.com" ]; then 
    err "You must specify a valid hostname (not the example given in the docs)"
  fi
  if [ "$COTURN_SECRET" == "1234abcd" ]; then 
    err "You must specify a new password (not the example given in the docs)."
  fi

  check_host "$COTURN_HOST"
}

check_apache2() {
  if dpkg -l | grep -q apache2-bin; then 
    echo "You must uninstall the Apache2 server first"
    if [ "$SKIP_APACHE_INSTALLED_CHECK" != true ]; then
      exit 1;
   fi 
  fi
}

# If running under LXC, then modify the FreeSWITCH systemctl service so it does not use realtime scheduler
check_lxc() {
  if grep -qa container=lxc /proc/1/environ; then
    if grep IOSchedulingClass /lib/systemd/system/freeswitch.service > /dev/null; then
      cat > /lib/systemd/system/freeswitch.service << HERE
[Unit]
Description=freeswitch
After=syslog.target network.target local-fs.target

[Service]
Type=forking
PIDFile=/opt/freeswitch/var/run/freeswitch/freeswitch.pid
Environment="DAEMON_OPTS=-nonat"
EnvironmentFile=-/etc/default/freeswitch
ExecStart=/opt/freeswitch/bin/freeswitch -u freeswitch -g daemon -ncwait \$DAEMON_OPTS
TimeoutSec=45s
Restart=always
WorkingDirectory=/opt/freeswitch
User=freeswitch
Group=daemon

LimitCORE=infinity
LimitNOFILE=100000
LimitNPROC=60000
LimitSTACK=250000
LimitRTPRIO=infinity
LimitRTTIME=7000000
#IOSchedulingClass=realtime
#IOSchedulingPriority=2
#CPUSchedulingPolicy=rr
#CPUSchedulingPriority=89

[Install]
WantedBy=multi-user.target
HERE

    systemctl daemon-reload
  fi
fi
}

# Check if running externally with internal/external IP addresses
check_nat() {
  xmlstarlet edit --inplace --update '//X-PRE-PROCESS[@cmd="set" and starts-with(@data, "external_rtp_ip=")]/@data' --value "external_rtp_ip=$IP" /opt/freeswitch/conf/vars.xml
  xmlstarlet edit --inplace --update '//X-PRE-PROCESS[@cmd="set" and starts-with(@data, "external_sip_ip=")]/@data' --value "external_sip_ip=$IP" /opt/freeswitch/conf/vars.xml

  if [ -n "$INTERNAL_IP" ]; then
    xmlstarlet edit --inplace --update '//param[@name="ext-rtp-ip"]/@value' --value "\$\${external_rtp_ip}" /opt/freeswitch/conf/sip_profiles/external.xml
    xmlstarlet edit --inplace --update '//param[@name="ext-sip-ip"]/@value' --value "\$\${external_sip_ip}" /opt/freeswitch/conf/sip_profiles/external.xml

    sed -i "s/$INTERNAL_IP:/$IP:/g" /usr/share/bigbluebutton/nginx/sip.nginx
    ip addr add "$IP" dev lo

    # If dummy NIC is not in dummy-nic.service (or the file does not exist), update/create it
    if ! grep -q "$IP" /lib/systemd/system/dummy-nic.service > /dev/null 2>&1; then
      if [ -f /lib/systemd/system/dummy-nic.service ]; then 
        DAEMON_RELOAD=true; 
      fi

      cat > /lib/systemd/system/dummy-nic.service << HERE
[Unit]
Description=Configure dummy NIC for FreeSWITCH
Before=freeswitch.service
After=network.target

[Service]
ExecStart=/sbin/ip addr add $IP dev lo

[Install]
WantedBy=multi-user.target
HERE

      if [ "$DAEMON_RELOAD" == "true" ]; then
        systemctl daemon-reload
        systemctl restart dummy-nic
      else
        systemctl enable dummy-nic
        systemctl start dummy-nic
      fi
    fi
  fi
}

check_LimitNOFILE() {
  CPU=$(nproc --all)

  if [ "$CPU" -ge 8 ]; then
    if [ -f /lib/systemd/system/bbb-web.service ]; then
      # Let's create an override file to increase the number of LimitNOFILE 
      mkdir -p /etc/systemd/system/bbb-web.service.d/
      cat > /etc/systemd/system/bbb-web.service.d/override.conf << HERE
[Service]
LimitNOFILE=8192
HERE
      systemctl daemon-reload
    fi
  fi
}

configure_HTML5() {
  # Use Google's default STUN server
  if [ -n "$INTERNAL_IP" ]; then
   sed -i "s/[;]*externalIPv4=.*/externalIPv4=$IP/g"                   /etc/kurento/modules/kurento/WebRtcEndpoint.conf.ini
   sed -i "s/[;]*iceTcp=.*/iceTcp=0/g"                                 /etc/kurento/modules/kurento/WebRtcEndpoint.conf.ini
  fi
}

install_haproxy() {
  need_pkg haproxy
  if [ -n "$INTERNAL_IP" ]; then
    TURN_IP="$INTERNAL_IP"
  else
    TURN_IP="$IP"
  fi
  HAPROXY_CFG=/etc/haproxy/haproxy.cfg
  cat > "$HAPROXY_CFG" <<END
global
	log /dev/log	local0
	log /dev/log	local1 notice
	chroot /var/lib/haproxy
	stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
	stats timeout 30s
	user haproxy
	group haproxy
	daemon

	# Default SSL material locations
	ca-base /etc/ssl/certs
	crt-base /etc/ssl/private

	# Default ciphers to use on SSL-enabled listening sockets.
	# For more information, see ciphers(1SSL). This list is from:
	#  https://hynek.me/articles/hardening-your-web-servers-ssl-ciphers/
	# An alternative list with additional directives can be obtained from
	#  https://mozilla.github.io/server-side-tls/ssl-config-generator/?server=haproxy
	ssl-default-bind-ciphers ECDH+AESGCM:DH+AESGCM:ECDH+AES256:DH+AES256:ECDH+AES128:DH+AES:RSA+AESGCM:RSA+AES:!aNULL:!MD5:!DSS
	ssl-default-bind-options ssl-min-ver TLSv1.2
	tune.ssl.default-dh-param 2048

defaults
	log	global
	mode	http
	option	httplog
	option	dontlognull
        timeout connect 5000
        timeout client  50000
        timeout server  50000
	errorfile 400 /etc/haproxy/errors/400.http
	errorfile 403 /etc/haproxy/errors/403.http
	errorfile 408 /etc/haproxy/errors/408.http
	errorfile 500 /etc/haproxy/errors/500.http
	errorfile 502 /etc/haproxy/errors/502.http
	errorfile 503 /etc/haproxy/errors/503.http
	errorfile 504 /etc/haproxy/errors/504.http


frontend nginx_or_turn
  bind *:443 ssl crt /etc/haproxy/certbundle.pem ssl-min-ver TLSv1.2 alpn h2,http/1.1,stun.turn
  mode tcp
  option tcplog
  tcp-request content capture req.payload(0,1) len 1
  log-format "%ci:%cp [%t] %ft %b/%s %Tw/%Tc/%Tt %B %ts %ac/%fc/%bc/%sc/%rc %sq/%bq captured_user:%{+X}[capture.req.hdr(0)]"
  tcp-request inspect-delay 30s
  # We terminate SSL on haproxy. HTTP2 is a binary protocol. haproxy has to
  # decide which protocol is spoken. This is negotiated by ALPN.
  #
  # Depending on the ALPN value traffic is redirected to either port 82 (HTTP2,
  # ALPN value h2) or 81 (HTTP 1.0 or HTTP 1.1, ALPN value http/1.1 or no value)
  # If no ALPN value is set, the first byte is inspected and depending on the
  # value traffic is sent to either port 81 or coturn.
  use_backend nginx-http2 if { ssl_fc_alpn h2 }
  use_backend nginx if { ssl_fc_alpn http/1.1 }
  use_backend turn if { ssl_fc_alpn stun.turn }
  use_backend %[capture.req.hdr(0),map_str(/etc/haproxy/protocolmap,turn)]
  default_backend turn

backend turn
  mode tcp
  server localhost $TURN_IP:3478

backend nginx
  mode tcp
  server localhost 127.0.0.1:81 send-proxy check

backend nginx-http2
  mode tcp
  server localhost 127.0.0.1:82 send-proxy check
END
  chown root:haproxy "$HAPROXY_CFG"
  chmod 640 "$HAPROXY_CFG"
  for l in {a..z} {A..Z}; do echo "$l" nginx ; done > /etc/haproxy/protocolmap
  chmod 0644 /etc/haproxy/protocolmap

  # cert renewal
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/haproxy <<HERE
#!/bin/bash -e

cat "/etc/letsencrypt/live/${HOST}"/{fullchain,privkey}.pem > /etc/haproxy/certbundle.pem.new
chown root:haproxy /etc/haproxy/certbundle.pem.new
chmod 0640 /etc/haproxy/certbundle.pem.new
mv /etc/haproxy/certbundle.pem.new /etc/haproxy/certbundle.pem
systemctl reload haproxy
HERE
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/haproxy
  /etc/letsencrypt/renewal-hooks/deploy/haproxy
}

# This function will install the latest official version of greenlight-v3 and set it as the hosting Bigbluebutton default frontend or update greenlight-v3 if installed.
# Greenlight is a simple to use Bigbluebutton room manager that offers a set of features useful to online workloads especially virtual schooling.
# https://docs.bigbluebutton.org/greenlight/gl-overview.html
install_greenlight_v3(){
  # This function depends on the following files existing on their expected location so an eager check is done asserting that.
  if [[ -z $SERVLET_DIR  || ! -f $SERVLET_DIR/WEB-INF/classes/bigbluebutton.properties || ! -f $CR_TMPFILE || ! -f $BBB_WEB_ETC_CONFIG ]]; then
    err "greenlight-v3 failed to install due to unmet requirements, have you followed the recommended steps to install Bigbluebutton?"
  fi

  check_root
  install_docker

  # Purge older docker compose if exists.
  if dpkg -l | grep -q docker-compose; then
    apt-get purge -y docker-compose
  fi

  if [ ! -x /usr/local/bin/docker-compose ]; then
    curl -L "https://github.com/docker/compose/releases/download/1.24.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  fi

  # Preparing and checking the enviroment.
  say "preparing and checking the enviroment to install/update greelight-v3..."

  if [ ! -d $GL3_DIR ]; then
    mkdir -p $GL3_DIR && say "created $GL3_DIR"
  fi

  local GL_IMG_REPO=bigbluebutton/greenlight:v3

  say "pulling latest $GL_IMG_REPO image..."
  docker pull $GL_IMG_REPO

  if [ ! -f $GL3_DIR/.env ]; then
    docker run --rm --entrypoint sh $GL_IMG_REPO -c 'cat sample.env' > $GL3_DIR/.env && say ".env file was created"
  fi

  if [ ! -f $GL3_DIR/docker-compose.yml ]; then
    docker run --rm --entrypoint sh $GL_IMG_REPO -c 'cat docker-compose.yml' > $GL3_DIR/docker-compose.yml && say "docker compose file was created"
  fi

  # Configuring Greenlight v3.
  say "checking the configuration of greenlight-v3..."

  local ROOT_URL=$(cat $SERVLET_DIR/WEB-INF/classes/bigbluebutton.properties $CR_TMPFILE $BBB_WEB_ETC_CONFIG | grep -v '#' | sed -n '/^bigbluebutton.web.serverURL/{s/.*=//;p}' | tail -n 1 )
  local BIGBLUEBUTTON_URL=$ROOT_URL/bigbluebutton/
  local BIGBLUEBUTTON_SECRET=$(cat $SERVLET_DIR/WEB-INF/classes/bigbluebutton.properties $CR_TMPFILE $BBB_WEB_ETC_CONFIG | grep -v '#' | grep ^securitySalt | tail -n 1  | cut -d= -f2)
  local SECRET_KEY_BASE=$(docker run --rm --entrypoint bundle $GL_IMG_REPO exec rake secret)
  local PGUSER=postgres # Postgres db user to be used by greenlight-v3.
  local PGTXADDR=postgres:5432 # Postgres DB transport address (pair of (@ip:@port)).
  local PGDBNAME=greenlight-v3-production
  local PGPASSWORD=$(openssl rand -hex 24) # Postgres user password.
  local RSTXADDR=redis:6379

  # A note for future maintainers:
  #   The following configuration operations were made idempotent, meaning that playing these actions will have an outcome on the system (configure it) only once.
  #   Replaying these steps are a safe and an expected operation, this gurantees the seemless simple installation and upgrade of Greenlight v3.
  #   A simple change can impact that property and therefore render the upgrading functionnality unoperationnal or impact the running system.

  # Configuring Greenlight v3 .env file (if already configured this will only update the BBB endpoint and secret).
  sed -i "s|^[# \t]*BIGBLUEBUTTON_ENDPOINT=.*|BIGBLUEBUTTON_ENDPOINT=$BIGBLUEBUTTON_URL|" $GL3_DIR/.env
  sed -i "s|^[# \t]*BIGBLUEBUTTON_SECRET=.*|BIGBLUEBUTTON_SECRET=$BIGBLUEBUTTON_SECRET|"  $GL3_DIR/.env
  sed -i "s|^[# \t]*SECRET_KEY_BASE=[ \t]*$|SECRET_KEY_BASE=$SECRET_KEY_BASE|" $GL3_DIR/.env
  sed -i "s|^[# \t]*DATABASE_URL=[ \t]*$|DATABASE_URL=postgres://$PGUSER:$PGPASSWORD@$PGTXADDR/$PGDBNAME|" $GL3_DIR/.env
  sed -i "s|^[# \t]*REDIS_URL=[ \t]*$|REDIS_URL=redis://$RSTXADDR/|" $GL3_DIR/.env
  # Configuring Greenlight v3 docker-compose.yml (if configured no side effect will happen).
  sed -i "s|^\([ \t-]*POSTGRES_PASSWORD\)\(=[ \t]*\)$|\1=$PGPASSWORD|g" $GL3_DIR/docker-compose.yml

  # Placing greenlight-v3 nginx file, this will enable greenlight-v3 as your Bigbluebutton frontend (bbb-fe).
  docker run --rm --entrypoint sh $GL_IMG_REPO -c 'cat greenlight-v3.nginx' > $NGINX_FILES_DEST/greenlight-v3.nginx && say "added greenlight-v3 nginx file"

  # For backward compatibility with deployments running greenlight-v2 and haven't picked the patch from COMMIT (583f868).
  # Move any nginx files from greenlight-v2 to the expected location.
  if [ -f /etc/bigbluebutton/nginx/greenlight.nginx ]; then
    mv /etc/bigbluebutton/nginx/greenlight.nginx $NGINX_FILES_DEST/greenlight.nginx && say "found /etc/bigbluebutton/nginx/greenlight.nginx and moved to expected location."
  fi

  if [ -f /etc/bigbluebutton/nginx/greenlight-redirect.nginx ]; then
    mv /etc/bigbluebutton/nginx/greenlight-redirect.nginx $NGINX_FILES_DEST/greenlight-redirect.nginx && say "found /etc/bigbluebutton/nginx/greenlight-redirect.nginx and moved to expected location."
  fi

  if [ -z "$COTURN" ]; then
    # When NGINX is the frontend reverse proxy, 'X-Forwarded-Proto' proxy header will dynamically match the $scheme of the received client request.
    # In case a builtin turn server is installed, then HAPROXY is introduced and it becomes the frontend reverse proxy.
    # NGINX will then act as a backend reverse proxy residing behind of it.
    # HTTPS traffic from the client then is terminated at HAPROXY and plain HTTP traffic is proxied to NGINX.
    # Therefore the 'X-Forwarded-Proto' proxy header needs to correctly indicate that HTTPS traffic was proxied in such scenario.
    sed -i '/X-Forwarded-Proto/s/$scheme/"https"/' $NGINX_FILES_DEST/greenlight-v3.nginx

    if [ -f $NGINX_FILES_DEST/greenlight.nginx ]; then
      # For backward compatibility with deployments running greenlight-v2 and haven't picked the patch from PR (#579).
      sed -i '/X-Forwarded-Proto/s/$scheme/"https"/' $NGINX_FILES_DEST/greenlight.nginx
    fi
  fi

  # For backward compatibility, any already installed greenlight-v2 application will remain but it will not be the default frontend for BigBluebutton.
  # To access greelight-v2 an explicit /b relative root needs to be indicated, otherwise greelight-v3 will be served by default.

  # Disabling the greenlight-v2 redirection rule.
  disable_nginx_site greenlight-redirect.nginx && say "found greelight-v2 redirection rule and disabled it!"

  # Disabling the Bigbluebutton default Welcome page frontend.
  disable_nginx_site default-fe.nginx && say "found default bbb-fe 'Welcome' and disabled it!"

  # Adding Keycloak
  if ! grep -q 'keycloak:' $GL3_DIR/docker-compose.yml; then
    # Keycloak isn't installed
    if [ -n "$INSTALL_KC" ]; then
      # Add Keycloak
      say "Adding Keycloak..."
      docker-compose -f $GL3_DIR/docker-compose.yml up -d postgres && say "started postgres"
      sleep 5
      docker-compose -f $GL3_DIR/docker-compose.yml exec -T postgres psql -U postgres -c 'CREATE DATABASE keycloakdb;' || err "unable to create Keycloak DB"

      say "created Keycloak DB"
      docker-compose -f $GL3_DIR/docker-compose.yml down
      cp -v $GL3_DIR/docker-compose.yml $GL3_DIR/docker-compose.base.yml # Persist working base compose file for admins.
      docker run --rm --entrypoint sh $GL_IMG_REPO -c 'cat docker-compose.kc.yml' >> $GL3_DIR/docker-compose.yml && say "added Keycloak to compose file"
      KCPASSWORD=$(openssl rand -hex 12) # Keycloak admin password.
      PGPASSWORD=$(sed -ne "s/^\([ \t-]*POSTGRES_PASSWORD=\)\(.*\)$/\2/p" $GL3_DIR/docker-compose.yml)
      sed -i "s|^\([ \t-]*KEYCLOAK_ADMIN_PASSWORD\)\(=[ \t]*\)$|\1=$KCPASSWORD|g" $GL3_DIR/docker-compose.yml
      sed -i "s|^\([ \t-]*KC_DB_PASSWORD\)\(=[ \t]*\)$|\1=$PGPASSWORD|g" $GL3_DIR/docker-compose.yml

      # Updating Keycloak nginx file.
      docker run --rm --entrypoint sh $GL_IMG_REPO -c 'cat keycloak.nginx' > $NGINX_FILES_DEST/keycloak.nginx && say "added Keycloak nginx file"
    fi

  else
    # Update Keycloak nginx file only.
    docker run --rm --entrypoint sh $GL_IMG_REPO -c 'cat keycloak.nginx' > $NGINX_FILES_DEST/keycloak.nginx && say "added Keycloak nginx file"
  fi

  if [ -z "$COTURN" ] && [ -f $NGINX_FILES_DEST/keycloak.nginx ]; then
    sed -i '/X-Forwarded-Proto/s/$scheme/"https"/' $NGINX_FILES_DEST/keycloak.nginx
  fi

  nginx -qt || err 'greenlight-v3 failed to install due to nginx tests failing to pass - if using the official image then please contact the maintainers.'
  nginx -qs reload && say 'greenlight-v3 was successfully configured'

  # Eager pulling images.
  say "pulling latest greenlight-v3 services images..."
  docker-compose -f $GL3_DIR/docker-compose.yml pull

  if check_container_running greenlight-v3; then
    # Restarting Greenlight-v3 services after updates.
    say "greenlight-v3 is updating..."
    say "shutting down greenlight-v3..."
    docker-compose -f $GL3_DIR/docker-compose.yml down
  fi

  say "starting greenlight-v3..."
  docker-compose -f $GL3_DIR/docker-compose.yml up -d
  sleep 5
  say "greenlight-v3 is now installed and accessible on: https://$HOST/"
  say "To create Greenlight administrator account, see: https://docs.bigbluebutton.org/greenlight_v3/gl3-install.html#creating-an-admin-account-1"


  if grep -q 'keycloak:' $GL3_DIR/docker-compose.yml; then
    say "Keycloak is now installed and accessible for configuration on: https://$HOST/keycloak/"
    if [ -n "$KCPASSWORD" ];then
      say "Use the following credentials when accessing the admin console:"
      say "   admin"
      say "   $KCPASSWORD"
    fi

    say "To complete the configuration of Keycloak, see: https://docs.bigbluebutton.org/greenlight_v3/gl3-external-authentication.html#configuring-keycloak"
  fi

  return 0;
}

# Given a container name as $1, this function will check if there's a match for that name in the list of running docker containers on the system.
# The result will be binded to $?.
check_container_running() {
  docker ps | grep -q "$1" || return 1;

  return 0;
}

# Given a filename as $1, if file exists under $sites_dir then the file will be suffixed with '.disabled'.
# sites_dir points to Bigbluebutton nginx sites, when suffixed with '.disabled' nginx will not include the site on reload/restart thus disabling it.
disable_nginx_site() {
  local site_path="$1"

  if [ -z $site_path ]; then
    return 1;
  fi

  if [ -f $NGINX_FILES_DEST/$site_path ]; then
    mv $NGINX_FILES_DEST/$site_path $NGINX_FILES_DEST/$site_path.disabled && return 0;
  fi

  return 1;
}

install_docker() {
  need_pkg apt-transport-https ca-certificates curl gnupg-agent software-properties-common openssl

  # Install Docker
  if ! apt-key list | grep -q Docker; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  fi

  if ! dpkg -l | grep -q docker-ce; then
    echo "deb [ arch=amd64 ] https://download.docker.com/linux/ubuntu \
     $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
    
    add-apt-repository --remove\
     "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
     $(lsb_release -cs) \
     stable"

    apt-get update
    need_pkg docker-ce docker-ce-cli containerd.io
  fi
  if ! which docker; then err "Docker did not install"; fi

  # Remove Docker Compose
  if dpkg -l | grep -q docker-compose; then
    apt-get purge -y docker-compose
  fi
}


install_ssl() {
  if ! grep -q "$HOST" /usr/local/bigbluebutton/core/scripts/bigbluebutton.yml; then
    bbb-conf --setip "$HOST"
  fi

  mkdir -p /etc/nginx/ssl

  if [ -z "$PROVIDED_CERTIFICATE" ]; then
    add-apt-repository universe
    apt-get update
    need_pkg certbot
  fi

  if [ ! -f "/etc/letsencrypt/live/$HOST/fullchain.pem" ]; then
    rm -f /tmp/bigbluebutton.bak
    if ! grep -q "$HOST" /etc/nginx/sites-available/bigbluebutton; then  # make sure we can do the challenge
      if [ -f /etc/nginx/sites-available/bigbluebutton ]; then
        cp /etc/nginx/sites-available/bigbluebutton /tmp/bigbluebutton.bak
      fi
      cat <<HERE > /etc/nginx/sites-available/bigbluebutton
server_tokens off;
server {
  listen 80;
  listen [::]:80;
  server_name $HOST;

  access_log  /var/log/nginx/bigbluebutton.access.log;

  # BigBlueButton landing page.
  location / {
    root   /var/www/bigbluebutton-default/assets;
    try_files \$uri @bbb-fe;
  }
}
HERE
      systemctl restart nginx
    fi

    if [ -z "$PROVIDED_CERTIFICATE" ]; then
      if ! certbot --email "$EMAIL" --agree-tos --rsa-key-size 4096 -w /var/www/bigbluebutton-default/assets/ \
           -d "$HOST" --deploy-hook "systemctl reload nginx" $LETS_ENCRYPT_OPTIONS certonly; then
        systemctl restart nginx
        err "Let's Encrypt SSL request for $HOST did not succeed - exiting"
      fi
    else
      # Place your fullchain.pem and privkey.pem files in /local/certs/ and bbb-install-2.6.sh will deal with the rest.
      mkdir -p "/etc/letsencrypt/live/$HOST/"
      ln -s /local/certs/fullchain.pem "/etc/letsencrypt/live/$HOST/fullchain.pem"
      ln -s /local/certs/privkey.pem "/etc/letsencrypt/live/$HOST/privkey.pem"
    fi
  fi

  if [ -z "$COTURN" ]; then
    # No COTURN credentials provided, setup a local TURN server
  cat <<HERE > /etc/nginx/sites-available/bigbluebutton
server_tokens off;

server {
  listen 80;
  listen [::]:80;
  server_name $HOST;
  
  return 301 https://\$server_name\$request_uri; #redirect HTTP to HTTPS

}
set_real_ip_from 127.0.0.1;
real_ip_header proxy_protocol;
real_ip_recursive on;
server {
  # this double listenting is intended. We terminate SSL on haproxy. HTTP2 is a
  # binary protocol. haproxy has to decide which protocol is spoken. This is
  # negotiated by ALPN.
  #
  # Depending on the ALPN value traffic is redirected to either port 82 (HTTP2,
  # ALPN value h2) or 81 (HTTP 1.0 or HTTP 1.1, ALPN value http/1.1 or no value)

  listen 127.0.0.1:82 http2 proxy_protocol;
  listen [::1]:82 http2;
  listen 127.0.0.1:81 proxy_protocol;
  listen [::1]:81;
  server_name $HOST;

    
    # HSTS (comment out to enable)
    #add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

  access_log  /var/log/nginx/bigbluebutton.access.log;

  # BigBlueButton landing page.
  location / {
    root   /var/www/bigbluebutton-default/assets;
    try_files \$uri @bbb-fe;
  }

  # Include specific rules for record and playback
  include /etc/bigbluebutton/nginx/*.nginx;
}
HERE
  else
    # We've been given COTURN credentials, so HAPROXY is not installed for local TURN server
  cat <<HERE > /etc/nginx/sites-available/bigbluebutton
server_tokens off;

server {
  listen 80;
  listen [::]:80;
  server_name $HOST;
  
  return 301 https://\$server_name\$request_uri; #redirect HTTP to HTTPS

}
server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name $HOST;

    ssl_certificate /etc/letsencrypt/live/$HOST/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$HOST/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_dhparam /etc/nginx/ssl/dhp-4096.pem;
    
    # HSTS (comment out to enable)
    #add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

  access_log  /var/log/nginx/bigbluebutton.access.log;

  # BigBlueButton landing page.
  location / {
    root   /var/www/bigbluebutton-default/assets;
    try_files \$uri @bbb-fe;
  }

  # Include specific rules for record and playback
  include /etc/bigbluebutton/nginx/*.nginx;
}
HERE

    if [ ! -f /etc/nginx/ssl/dhp-4096.pem ]; then
      openssl dhparam -dsaparam  -out /etc/nginx/ssl/dhp-4096.pem 4096
    fi 
  fi
# Create the default Welcome page Bigbluebutton Frontend unless it exists.
if [[ ! -f /usr/share/bigbluebutton/nginx/default-fe.nginx && ! -f /usr/share/bigbluebutton/nginx/default-fe.nginx.disabled ]]; then
cat <<HERE > /usr/share/bigbluebutton/nginx/default-fe.nginx
# Default Bigbluebutton Landing page.

location @bbb-fe {
  index  index.html index.htm;
  expires 1m;
}

HERE
fi

  # Configure rest of BigBlueButton Configuration for SSL
  xmlstarlet edit --inplace --update '//param[@name="wss-binding"]/@value' --value "$IP:7443" /opt/freeswitch/conf/sip_profiles/external.xml
 
  source /etc/bigbluebutton/bigbluebutton-release
  if [ -n "$(echo "$BIGBLUEBUTTON_RELEASE" | grep '2.2')" ] && [ "$(echo "$BIGBLUEBUTTON_RELEASE" | cut -d\. -f3)" -lt 29 ]; then
    sed -i "s/proxy_pass .*/proxy_pass https:\/\/$IP:7443;/g" /usr/share/bigbluebutton/nginx/sip.nginx
  else
    # Use nginx as proxy for WSS -> WS (see https://github.com/bigbluebutton/bigbluebutton/issues/9667)
    yq w -i /usr/share/meteor/bundle/programs/server/assets/app/config/settings.yml public.media.sipjsHackViaWs true
    sed -i "s/proxy_pass .*/proxy_pass http:\/\/$IP:5066;/g" /usr/share/bigbluebutton/nginx/sip.nginx
    xmlstarlet edit --inplace --update '//param[@name="ws-binding"]/@value' --value "$IP:5066" /opt/freeswitch/conf/sip_profiles/external.xml
  fi

  sed -i 's/^bigbluebutton.web.serverURL=http:/bigbluebutton.web.serverURL=https:/g' $SERVLET_DIR/WEB-INF/classes/bigbluebutton.properties
  if [ -f $BBB_WEB_ETC_CONFIG ]; then
    sed -i 's/^bigbluebutton.web.serverURL=http:/bigbluebutton.web.serverURL=https:/g' $BBB_WEB_ETC_CONFIG
  fi

  yq w -i /usr/local/bigbluebutton/core/scripts/bigbluebutton.yml playback_protocol https
  chmod 644 /usr/local/bigbluebutton/core/scripts/bigbluebutton.yml 

  # Update Greenlight (if installed) to use SSL
  for gl_dir in ~/greenlight $GL3_DIR;do
    if [ -f $gl_dir/.env ]; then
      if ! grep ^BIGBLUEBUTTON_ENDPOINT $gl_dir/.env | grep -q https; then
        if [[ -z $BIGBLUEBUTTON_URL ]]; then
          BIGBLUEBUTTON_URL=$(cat $SERVLET_DIR/WEB-INF/classes/bigbluebutton.properties $CR_TMPFILE $BBB_WEB_ETC_CONFIG | grep -v '#' | sed -n '/^bigbluebutton.web.serverURL/{s/.*=//;p}' | tail -n 1 )/bigbluebutton/
        fi

        sed -i "s|.*BIGBLUEBUTTON_ENDPOINT=.*|BIGBLUEBUTTON_ENDPOINT=$BIGBLUEBUTTON_URL|" ~/greenlight/.env
        docker-compose -f $gl_dir/docker-compose.yml down
        docker-compose -f $gl_dir/docker-compose.yml up -d
      fi
    fi
  done

  TARGET=/usr/local/bigbluebutton/bbb-webrtc-sfu/config/default.yml
  if [ -f $TARGET ]; then
    if grep -q kurentoIp $TARGET; then
      # 2.0
      yq w -i $TARGET kurentoIp "$IP"
    else
      # 2.2
      yq w -i $TARGET kurento[0].ip "$IP"
      yq w -i $TARGET freeswitch.ip "$IP"

      if [ -n "$(echo "$BIGBLUEBUTTON_RELEASE" | grep '2.2')" ] && [ "$(echo "$BIGBLUEBUTTON_RELEASE" | cut -d\. -f3)" -lt 29 ]; then
        if [ -n "$INTERNAL_IP" ]; then
          yq w -i $TARGET freeswitch.sip_ip "$INTERNAL_IP"
        else
          yq w -i $TARGET freeswitch.sip_ip "$IP"
        fi
      else
        # Use nginx as proxy for WSS -> WS (see https://github.com/bigbluebutton/bigbluebutton/issues/9667)
        yq w -i $TARGET freeswitch.sip_ip "$IP"
      fi
    fi
    chown bigbluebutton:bigbluebutton $TARGET
    chmod 644 $TARGET
  fi

  mkdir -p /etc/bigbluebutton/bbb-webrtc-sfu
  TARGET=/etc/bigbluebutton/bbb-webrtc-sfu/production.yml
  touch $TARGET

  # Configure mediasoup IPs, reference: https://raw.githubusercontent.com/bigbluebutton/bbb-webrtc-sfu/v2.7.2/docs/mediasoup.md
  # mediasoup IPs: WebRTC
  yq w -i "$TARGET" mediasoup.webrtc.listenIps[0].ip "0.0.0.0"
  yq w -i "$TARGET" mediasoup.webrtc.listenIps[0].announcedIp "$IP"

  # mediasoup IPs: plain RTP (internal comms, FS <-> mediasoup)
  yq w -i "$TARGET" mediasoup.plainRtp.listenIp.ip "0.0.0.0"
  yq w -i "$TARGET" mediasoup.plainRtp.listenIp.announcedIp "$IP"

  systemctl reload nginx
}

configure_coturn() {
  TURN_XML=/etc/bigbluebutton/turn-stun-servers.xml

  if [ -z "$COTURN" ]; then
    # the user didn't pass '-c', so use the local TURN server's host
    COTURN_HOST=$HOST
  fi

  cat <<HERE > $TURN_XML
<?xml version="1.0" encoding="UTF-8"?>
<beans xmlns="http://www.springframework.org/schema/beans"
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
        xsi:schemaLocation="http://www.springframework.org/schema/beans
        http://www.springframework.org/schema/beans/spring-beans-2.5.xsd">

    <!-- 
         We need turn0 for FireFox to workaround its limited ICE implementation.
         This is UDP connection.  Note that port 3478 must be open on this BigBlueButton
         and reachble by the client.

         Also, in 2.5, we previously defined turn:\$HOST:443?transport=tcp (not 'turns') 
         to workaround a bug in Safari's handling of Let's Encrypt. This bug is now fixed
         https://bugs.webkit.org/show_bug.cgi?id=219274, so we omit the 'turn' protocol over
         port 443.
     -->
    <bean id="turn0" class="org.bigbluebutton.web.services.turn.TurnServer">
        <constructor-arg index="0" value="$COTURN_SECRET"/>
        <constructor-arg index="1" value="turn:$COTURN_HOST:3478"/>
        <constructor-arg index="2" value="86400"/>
    </bean>
    <bean id="turn1" class="org.bigbluebutton.web.services.turn.TurnServer">
        <constructor-arg index="0" value="$COTURN_SECRET"/>
        <constructor-arg index="1" value="turns:$COTURN_HOST:443?transport=tcp"/>
        <constructor-arg index="2" value="86400"/>
    </bean>
    
    <bean id="stunTurnService"
            class="org.bigbluebutton.web.services.turn.StunTurnService">
        <property name="stunServers">
            <set>
            </set>
        </property>
        <property name="turnServers">
            <set>
                <ref bean="turn0"/>
                <ref bean="turn1"/>
            </set>
        </property>
    </bean>
</beans>
HERE

  chown root:bigbluebutton "$TURN_XML"
  chmod 640 "$TURN_XML"
}


install_coturn() {
  apt-get update
  apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" dist-upgrade

  need_pkg software-properties-common certbot

  need_pkg coturn

  if [ -n "$INTERNAL_IP" ]; then
    SECOND_ALLOWED_PEER_IP="allowed-peer-ip=$INTERNAL_IP"
  fi
  # check if this is still the default coturn config file. Replace it in this case.
  if grep "#static-auth-secret=north" /etc/turnserver.conf > /dev/null ; then
    COTURN_SECRET="$(openssl rand -base64 32)"
    cat <<HERE > /etc/turnserver.conf
listening-port=3478

listening-ip=${INTERNAL_IP:-$IP}
relay-ip=${INTERNAL_IP:-$IP}

min-port=32769
max-port=65535
verbose

fingerprint
lt-cred-mech
use-auth-secret
static-auth-secret=$COTURN_SECRET
realm=$HOST

keep-address-family

no-cli
no-tlsv1
no-tlsv1_1

# Block connections to IP ranges which shouldn't be reachable
no-loopback-peers
no-multicast-peers


# we only need to allow peer connections from the machine itself (from mediasoup or freeswitch).
denied-peer-ip=0.0.0.0-255.255.255.255
denied-peer-ip=::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
allowed-peer-ip=$IP
$SECOND_ALLOWED_PEER_IP

HERE
    chown root:turnserver /etc/turnserver.conf
    chmod 640 /etc/turnserver.conf
  else
    # fetch secret for later setting up in BBB turn config
    COTURN_SECRET="$(grep static-auth-secret= /etc/turnserver.conf |cut -d = -f 2-)"
  fi

  mkdir -p /var/log/turnserver
  chown turnserver:turnserver /var/log/turnserver

  cat <<HERE > /etc/logrotate.d/coturn
/var/log/turnserver/*.log
{
	rotate 7
	daily
	missingok
	notifempty
	compress
	postrotate
		/bin/systemctl kill -s HUP coturn.service
	endscript
}
HERE

  # Eanble coturn to bind to port 443 with CAP_NET_BIND_SERVICE
  mkdir -p /etc/systemd/system/coturn.service.d
  rm -rf /etc/systemd/system/coturn.service.d/ansible.conf      # Remove previous file 
  cat > /etc/systemd/system/coturn.service.d/override.conf <<HERE
[Service]
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=
ExecStart=/usr/bin/turnserver --daemon -c /etc/turnserver.conf --pidfile /run/turnserver/turnserver.pid --no-stdout-log --simple-log --log-file /var/log/turnserver/turnserver.log
Restart=always
HERE

  systemctl daemon-reload
  systemctl restart coturn
  configure_coturn
}


setup_ufw() {
  if [ ! -f /etc/bigbluebutton/bbb-conf/apply-config.sh ]; then
    cat > /etc/bigbluebutton/bbb-conf/apply-config.sh << HERE
#!/bin/bash

# Pull in the helper functions for configuring BigBlueButton
source /etc/bigbluebutton/bbb-conf/apply-lib.sh

enableUFWRules
HERE
  chmod +x /etc/bigbluebutton/bbb-conf/apply-config.sh
  fi
}

main "$@" || exit 1

