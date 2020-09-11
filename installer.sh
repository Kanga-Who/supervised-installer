#!/usr/bin/env bash

systemctl status ModemManager | grep 'active (running)' > /dev/null 2>&1

if [ $? != 0 ]
then
        systemctl disable ModemManager > /dev/null
	systemctl stop ModemManager > /dev/null
fi

set -e

function info { echo -e "[Info] $*"; }
function error { echo -e "[Error] $*"; exit 1; }
function warn  { echo -e "[Warning] $*"; }

# Install required dependencies
test $? -eq 0 || exit 1 "you should have sudo priveledge to run this script"

info ""
info ""
info "Installing Home Assistant dependencies"
info ""
info ""

while read -r p ; do sudo apt-get install -y $p ; done < <(cat << "EOF"
	software-properties-common
	apparmor-utils 
	apt-transport-https 
	avahi-daemon 
	ca-certificates 
	curl 
	dbus 
	jq 
	network-manager
EOF
)

# Install Docker-ce
info ""
info ""
info "Installing Docker-ce"
info ""
info ""

curl -fsSL get.docker.com | sh

# Install Home Assistant Supervised
info ""
info ""
info "Now installing Home Assistant Supervised"
info ""
info ""

warn ""
warn "If you want more control over your own system, run"
warn "Home Assistant as a VM or run Home Assistant Core"
warn "via a Docker container."
warn ""

ARCH=$(uname -m)
DOCKER_BINARY=/usr/bin/docker
DOCKER_REPO=homeassistant
DOCKER_SERVICE=docker.service
DOCKER_DAEMON_CONFIG=/etc/docker/daemon.json
URL_VERSION="https://version.home-assistant.io/stable.json"
URL_HA="https://raw.githubusercontent.com/home-assistant/supervised-installer/master/files/ha"
URL_BIN_HASSIO="https://raw.githubusercontent.com/home-assistant/supervised-installer/master/files/hassio-supervisor"
URL_BIN_APPARMOR="https://raw.githubusercontent.com/home-assistant/supervised-installer/master/files/hassio-apparmor"
URL_SERVICE_HASSIO="https://raw.githubusercontent.com/home-assistant/supervised-installer/master/files/hassio-supervisor.service"
URL_SERVICE_APPARMOR="https://raw.githubusercontent.com/home-assistant/supervised-installer/master/files/hassio-apparmor.service"
URL_APPARMOR_PROFILE="https://version.home-assistant.io/apparmor.txt"

# Check env
command -v systemctl > /dev/null 2>&1 || error "Only systemd is supported!"
command -v docker > /dev/null 2>&1 || error "Please install docker first"
command -v jq > /dev/null 2>&1 || error "Please install jq first"
command -v curl > /dev/null 2>&1 || error "Please install curl first"
command -v avahi-daemon > /dev/null 2>&1 || error "Please install avahi first"
command -v dbus-daemon > /dev/null 2>&1 || error "Please install dbus first"
command -v nmcli > /dev/null 2>&1 || error "No NetworkManager support on host."
command -v apparmor_parser > /dev/null 2>&1 || error "No AppArmor support on host."


# Check if Modem Manager is enabled
if systemctl list-unit-files ModemManager.service | grep enabled; then
    warn "ModemManager service is enabled. This might cause issue when using serial devices."
fi

# Detect wrong docker logger config
if [ ! -f "$DOCKER_DAEMON_CONFIG" ]; then
  # Write default configuration
  info "Creating default docker deamon configuration $DOCKER_DAEMON_CONFIG"
  cat > "$DOCKER_DAEMON_CONFIG" <<- EOF
    {
        "log-driver": "journald",
        "storage-driver": "overlay2"
    }
EOF
  # Restart Docker service
  info "Restarting docker service"
  systemctl restart "$DOCKER_SERVICE"
else
  STORAGE_DRIVER=$(docker info -f "{{json .}}" | jq -r -e .Driver)
  LOGGING_DRIVER=$(docker info -f "{{json .}}" | jq -r -e .LoggingDriver)
  if [[ "$STORAGE_DRIVER" != "overlay2" ]]; then 
    warn "Docker is using $STORAGE_DRIVER and not 'overlay2' as the storage driver, this is not supported."
  fi
  if [[ "$LOGGING_DRIVER"  != "journald" ]]; then 
    warn "Docker is using $LOGGING_DRIVER and not 'journald' as the logging driver, this is not supported."
  fi
fi

# Check dmesg access
if [[ "$(sysctl --values kernel.dmesg_restrict)" != "0" ]]; then
    info "Fix kernel dmesg restriction"
    echo 0 > /proc/sys/kernel/dmesg_restrict
    echo "kernel.dmesg_restrict=0" >> /etc/sysctl.conf
fi

# Parse command line parameters
while [[ $# -gt 0 ]]; do
    arg="$1"

    case $arg in
        -m|--machine)
            MACHINE=$2
            shift
            ;;
        -d|--data-share)
            DATA_SHARE=$2
            shift
            ;;
        -p|--prefix)
            PREFIX=$2
            shift
            ;;
        -s|--sysconfdir)
            SYSCONFDIR=$2
            shift
            ;;
        *)
            error "Unrecognized option $1"
            ;;
    esac
    shift
done

PREFIX=${PREFIX:-/usr}
SYSCONFDIR=${SYSCONFDIR:-/etc}
DATA_SHARE=${DATA_SHARE:-$PREFIX/share/hassio}
CONFIG=$SYSCONFDIR/hassio.json

# Generate hardware options
case $ARCH in
    "i386" | "i686")
        MACHINE=${MACHINE:=qemux86}
        HASSIO_DOCKER="$DOCKER_REPO/i386-hassio-supervisor"
    ;;
    "x86_64")
        MACHINE=${MACHINE:=qemux86-64}
        HASSIO_DOCKER="$DOCKER_REPO/amd64-hassio-supervisor"
    ;;
    "arm" |"armv6l")
        if [ -z $MACHINE ]; then
            error "Please set machine for $ARCH"
        fi
        HASSIO_DOCKER="$DOCKER_REPO/armhf-hassio-supervisor"
    ;;
    "armv7l")
        if [ -z $MACHINE ]; then
            error "Please set machine for $ARCH"
        fi
        HASSIO_DOCKER="$DOCKER_REPO/armv7-hassio-supervisor"
    ;;
    "aarch64")
        if [ -z $MACHINE ]; then
            error "Please set machine for $ARCH"
        fi
        HASSIO_DOCKER="$DOCKER_REPO/aarch64-hassio-supervisor"
    ;;
    *)
        error "$ARCH unknown!"
    ;;
esac

if [[ ! "${MACHINE}" =~ ^(intel-nuc|odroid-c2|odroid-n2|odroid-xu|qemuarm|qemuarm-64|qemux86|qemux86-64|raspberrypi|raspberrypi2|raspberrypi3|raspberrypi4|raspberrypi3-64|raspberrypi4-64|tinker)$ ]]; then
    error "Unknown machine type ${MACHINE}!"
fi

### Main

# Init folders
if [ ! -d "$DATA_SHARE" ]; then
    mkdir -p "$DATA_SHARE"
fi

# Read infos from web
HASSIO_VERSION=$(curl -s $URL_VERSION | jq -e -r '.supervisor')

##
# Write configuration
cat > "$CONFIG" <<- EOF
{
    "supervisor": "${HASSIO_DOCKER}",
    "machine": "${MACHINE}",
    "data": "${DATA_SHARE}"
}
EOF

##
# Pull supervisor image
info "Install supervisor Docker container"
docker pull "$HASSIO_DOCKER:$HASSIO_VERSION" > /dev/null
docker tag "$HASSIO_DOCKER:$HASSIO_VERSION" "$HASSIO_DOCKER:latest" > /dev/null

##
# Install Hass.io Supervisor
info "Install supervisor startup scripts"
curl -sL ${URL_BIN_HASSIO} > "${PREFIX}/sbin/hassio-supervisor"
curl -sL ${URL_SERVICE_HASSIO} > "${SYSCONFDIR}/systemd/system/hassio-supervisor.service"

sed -i "s,%%HASSIO_CONFIG%%,${CONFIG},g" "${PREFIX}"/sbin/hassio-supervisor
sed -i -e "s,%%DOCKER_BINARY%%,${DOCKER_BINARY},g" \
       -e "s,%%DOCKER_SERVICE%%,${DOCKER_SERVICE},g" \
       -e "s,%%HASSIO_BINARY%%,${PREFIX}/sbin/hassio-supervisor,g" \
       "${SYSCONFDIR}/systemd/system/hassio-supervisor.service"

chmod a+x "${PREFIX}/sbin/hassio-supervisor"
systemctl enable hassio-supervisor.service

#
# Install Hass.io AppArmor
if command -v apparmor_parser > /dev/null 2>&1; then
    info "Install AppArmor scripts"
    mkdir -p "${DATA_SHARE}/apparmor"
    curl -sL ${URL_BIN_APPARMOR} > "${PREFIX}/sbin/hassio-apparmor"
    curl -sL ${URL_SERVICE_APPARMOR} > "${SYSCONFDIR}/systemd/system/hassio-apparmor.service"
    curl -sL ${URL_APPARMOR_PROFILE} > "${DATA_SHARE}/apparmor/hassio-supervisor"

    sed -i "s,%%HASSIO_CONFIG%%,${CONFIG},g" "${PREFIX}/sbin/hassio-apparmor"
    sed -i -e "s,%%DOCKER_SERVICE%%,${DOCKER_SERVICE},g" \
	   -e "s,%%HASSIO_APPARMOR_BINARY%%,${PREFIX}/sbin/hassio-apparmor,g" \
	   "${SYSCONFDIR}/systemd/system/hassio-apparmor.service"

    chmod a+x "${PREFIX}/sbin/hassio-apparmor"
    systemctl enable hassio-apparmor.service
    systemctl start hassio-apparmor.service
fi

##
# Init system
info "Run Home Assistant Supervised"
systemctl start hassio-supervisor.service

##
# Setup CLI
info "Install cli 'ha'"
curl -sL ${URL_HA} > "${PREFIX}/bin/ha"
chmod a+x "${PREFIX}/bin/ha"
