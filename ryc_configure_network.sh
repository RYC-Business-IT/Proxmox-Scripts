#!/bin/bash

# Script to configure Proxmox VE networking for DHCP or Static IP
# Usage: ./network-config.sh [--mode dhcp|static] [--ip IP_ADDRESS] [--netmask NETMASK]
#        [--gateway GATEWAY] [--dns DNS_SERVERS] [--hostname HOSTNAME]
#        [--interface INTERFACE] [--bridge-ports PORTS] [--test-ip TEST_IP]

# Default variables
MODE=""
IP_ADDRESS=""
NETMASK=""
GATEWAY=""
DNS_SERVERS=""
HOSTNAME=""
INTERFACE=""
BRIDGE_PORTS=""
TEST_IPS=()
DHCP_HOOK_SCRIPT="/etc/dhcp/dhclient-exit-hooks.d/update-etc-hosts"
LOGFILE="/var/log/network-config.log"
BACKUP_DIR="/var/backups/network-config-$(date +%F_%T)"

# Function to display usage
usage() {
  echo "Usage: $0 [--mode dhcp|static] [--ip IP_ADDRESS] [--netmask NETMASK]"
  echo "          [--gateway GATEWAY] [--dns DNS_SERVERS] [--hostname HOSTNAME]"
  echo "          [--interface INTERFACE] [--bridge-ports PORTS] [--test-ip TEST_IP]"
  exit 1
}

# Function to log messages
log() {
  MESSAGE="$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $MESSAGE" | tee -a "$LOGFILE"
  logger -t network-config.sh "$MESSAGE"
}

# Parse parameters
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --mode) MODE="$2"; shift ;;
    --ip) IP_ADDRESS="$2"; shift ;;
    --netmask) NETMASK="$2"; shift ;;
    --gateway) GATEWAY="$2"; shift ;;
    --dns) DNS_SERVERS="$2"; shift ;;
    --hostname) HOSTNAME="$2"; shift ;;
    --interface) INTERFACE="$2"; shift ;;
    --bridge-ports) BRIDGE_PORTS="$2"; shift ;;
    --test-ip) TEST_IPS+=("$2"); shift ;;
    *) echo "Unknown parameter passed: $1"; usage ;;
  esac
  shift
done

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
  log "Please run as root."
  exit 1
fi

# Function to get current network settings
get_current_settings() {
  CURRENT_IP=$(ip -4 addr show $INTERFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
  CURRENT_NETMASK=$(ip -o -f inet addr show $INTERFACE | awk '/scope global/ {print $4}' | cut -d'/' -f2)
  CURRENT_GATEWAY=$(ip route | awk '/default/ {print $3}')
  CURRENT_DNS=$(grep 'nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')
  CURRENT_HOSTNAME=$(hostname)
  
  # Get current bridge ports if interface is a bridge
  if [[ "$INTERFACE" == vmbr* ]]; then
    CURRENT_BRIDGE_PORTS=$(bridge link show | grep -B1 "master $INTERFACE" | grep "state UP" | awk '{print $2}' | tr -d ':')
  fi
}

# Function to list interfaces
list_interfaces() {
  log "Listing available network interfaces and their IP addresses:"
  ip -o -4 addr show | awk '{print $2 " - " $4}' | tee -a "$LOGFILE"
}

# Function to test connectivity
test_connectivity() {
  for IP in "${TEST_IPS[@]}"; do
    log "Testing connectivity to $IP..."
    if ping -c 3 -W 2 $IP > /dev/null 2>&1; then
      log "Successfully reached $IP."
      return 0
    else
      log "Failed to reach $IP."
    fi
  done
  return 1
}

# Function to rollback changes
rollback_changes() {
  log "Rolling back to previous network configuration."
  if [ -d "$BACKUP_DIR" ]; then
    cp "$BACKUP_DIR/interfaces.bak" /etc/network/interfaces
    cp "$BACKUP_DIR/hosts.bak" /etc/hosts
    hostnamectl set-hostname "$CURRENT_HOSTNAME"
    log "Restored /etc/network/interfaces, /etc/hosts, and hostname."
    ifreload -a
    log "Reapplied original network configuration with ifreload -a."
  else
    log "Backup directory not found. Cannot rollback."
  fi
}

# Default to vmbr0 if not specified
if [ -z "$INTERFACE" ]; then
  if ip link show vmbr0 > /dev/null 2>&1; then
    INTERFACE="vmbr0"
  else
    INTERFACE=$(ip -o -4 addr show | awk '{print $2}' | head -n1)
    log "Defaulting to interface: $INTERFACE"
  fi
fi

# Get current settings
get_current_settings

# Interactive mode if parameters are not provided
if [ -z "$MODE" ]; then
  echo "Do you want to configure networking for DHCP or Static IP?"
  read -p "Enter mode [dhcp/static] [${MODE:-dhcp}]: " INPUT_MODE
  MODE=${INPUT_MODE:-${MODE:-dhcp}}
fi

# If interface not provided, prompt for it
if [ -z "$INTERFACE" ]; then
  echo "Available network interfaces:"
  ip -o link show | awk -F': ' '{print $2}'
  read -p "Enter the network interface to configure [${INTERFACE}]: " INPUT_INTERFACE
  INTERFACE=${INPUT_INTERFACE:-$INTERFACE}
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"
log "Created backup directory at $BACKUP_DIR."

# Backup existing configuration files
cp /etc/network/interfaces "$BACKUP_DIR/interfaces.bak"
cp /etc/hosts "$BACKUP_DIR/hosts.bak"
log "Backed up /etc/network/interfaces and /etc/hosts."

# Save current hostname
echo "$CURRENT_HOSTNAME" > "$BACKUP_DIR/hostname.bak"

if [ "$MODE" == "dhcp" ]; then
  # DHCP Mode
  log "Configuring network interface $INTERFACE for DHCP."

  # If the interface is a bridge, configure accordingly
  if [[ "$INTERFACE" == vmbr* ]]; then
    # Prompt for bridge ports if not provided
    if [ -z "$BRIDGE_PORTS" ]; then
      echo "Enter physical interface(s) to bridge (e.g., eth0). Separate multiple interfaces with spaces."
      read -p "Bridge ports [${CURRENT_BRIDGE_PORTS}]: " INPUT_BRIDGE_PORTS
      BRIDGE_PORTS=${INPUT_BRIDGE_PORTS:-$CURRENT_BRIDGE_PORTS}
    fi

    # Set physical interfaces to manual
    PHYSICAL_INTERFACES=""
    for PORT in $BRIDGE_PORTS; do
      PHYSICAL_INTERFACES+=$'\n'"auto $PORT"$'\n'"iface $PORT inet manual"
    done

    # Update /etc/network/interfaces
    cat > /etc/network/interfaces <<EOF
# This file is auto-generated by network-config.sh

auto lo
iface lo inet loopback

$PHYSICAL_INTERFACES

auto $INTERFACE
iface $INTERFACE inet dhcp
    bridge-ports $BRIDGE_PORTS
    bridge-stp off
    bridge-fd 0
EOF
  else
    # Standard interface
    cat > /etc/network/interfaces <<EOF
# This file is auto-generated by network-config.sh

auto lo
iface lo inet loopback

auto $INTERFACE
iface $INTERFACE inet dhcp
EOF
  fi

  log "Updated /etc/network/interfaces with DHCP configuration for $INTERFACE."

  # Restart networking
  ifreload -a
  log "Applied network configuration changes with ifreload -a."

  # If test IPs not provided, prompt for them
  if [ ${#TEST_IPS[@]} -eq 0 ]; then
    echo "Enter IP addresses to test connectivity (comma-separated) [8.8.8.8,1.1.1.1]:"
    read -p "Test IPs: " INPUT_TEST_IPS
    if [ -z "$INPUT_TEST_IPS" ]; then
      TEST_IPS=("8.8.8.8" "1.1.1.1")
    else
      IFS=',' read -ra TEST_IPS <<< "$INPUT_TEST_IPS"
    fi
  fi

  # Test connectivity
  if test_connectivity; then
    log "Connectivity test passed."
  else
    log "Connectivity test failed."
    rollback_changes
    exit 1
  fi

  # List interfaces
  list_interfaces

  log "Network interface $INTERFACE has been configured for DHCP."

elif [ "$MODE" == "static" ]; then
  # Static IP Mode
  log "Configuring network interface $INTERFACE with a static IP."

  # Prompt for IP address
  if [ -z "$IP_ADDRESS" ]; then
    read -p "Enter IP address [${CURRENT_IP}]: " IP_ADDRESS
    IP_ADDRESS=${IP_ADDRESS:-$CURRENT_IP}
  fi

  # Prompt for Netmask
  if [ -z "$NETMASK" ]; then
    read -p "Enter Netmask (CIDR notation, e.g., 24) [${CURRENT_NETMASK}]: " NETMASK
    NETMASK=${NETMASK:-$CURRENT_NETMASK}
  fi

  # Prompt for Gateway
  if [ -z "$GATEWAY" ]; then
    read -p "Enter Gateway [${CURRENT_GATEWAY}]: " GATEWAY
    GATEWAY=${GATEWAY:-$CURRENT_GATEWAY}
  fi

  # Prompt for DNS Servers
  if [ -z "$DNS_SERVERS" ]; then
    read -p "Enter DNS servers (space-separated) [${CURRENT_DNS}]: " DNS_SERVERS
    DNS_SERVERS=${DNS_SERVERS:-$CURRENT_DNS}
  fi

  # Prompt for Hostname
  if [ -z "$HOSTNAME" ]; then
    read -p "Enter Hostname [${CURRENT_HOSTNAME}]: " HOSTNAME
    HOSTNAME=${HOSTNAME:-$CURRENT_HOSTNAME}
  fi

  # If test IPs not provided, prompt for them
  if [ ${#TEST_IPS[@]} -eq 0 ]; then
    echo "Enter IP addresses to test connectivity (comma-separated) [8.8.8.8,1.1.1.1]:"
    read -p "Test IPs: " INPUT_TEST_IPS
    if [ -z "$INPUT_TEST_IPS" ]; then
      TEST_IPS=("8.8.8.8" "1.1.1.1")
    else
      IFS=',' read -ra TEST_IPS <<< "$INPUT_TEST_IPS"
    fi
  fi

  # If the interface is a bridge, configure accordingly
  if [[ "$INTERFACE" == vmbr* ]]; then
    # Prompt for bridge ports if not provided
    if [ -z "$BRIDGE_PORTS" ]; then
      echo "Enter physical interface(s) to bridge (e.g., eth0). Separate multiple interfaces with spaces."
      read -p "Bridge ports [${CURRENT_BRIDGE_PORTS}]: " INPUT_BRIDGE_PORTS
      BRIDGE_PORTS=${INPUT_BRIDGE_PORTS:-$CURRENT_BRIDGE_PORTS}
    fi

    # Set physical interfaces to manual
    PHYSICAL_INTERFACES=""
    for PORT in $BRIDGE_PORTS; do
      PHYSICAL_INTERFACES+=$'\n'"auto $PORT"$'\n'"iface $PORT inet manual"
    done

    # Update /etc/network/interfaces
    cat > /etc/network/interfaces <<EOF
# This file is auto-generated by network-config.sh

auto lo
iface lo inet loopback

$PHYSICAL_INTERFACES

auto $INTERFACE
iface $INTERFACE inet static
    address $IP_ADDRESS/$NETMASK
    gateway $GATEWAY
    dns-nameservers $DNS_SERVERS
    bridge-ports $BRIDGE_PORTS
    bridge-stp off
    bridge-fd 0
EOF
  else
    # Standard interface
    cat > /etc/network/interfaces <<EOF
# This file is auto-generated by network-config.sh

auto lo
iface lo inet loopback

auto $INTERFACE
iface $INTERFACE inet static
    address $IP_ADDRESS/$NETMASK
    gateway $GATEWAY
    dns-nameservers $DNS_SERVERS
EOF
  fi

  log "Updated /etc/network/interfaces with static IP configuration for $INTERFACE."

  # Update hostname
  hostnamectl set-hostname "$HOSTNAME"
  log "Hostname has been set to $HOSTNAME."

  # Update /etc/hosts
  sed -i "s|127\.0\.1\.1.*|127.0.1.1 $HOSTNAME|" /etc/hosts
  log "Updated /etc/hosts with new hostname."

  # Restart networking
  ifreload -a
  log "Applied network configuration changes with ifreload -a."

  # Test connectivity
  if test_connectivity; then
    log "Connectivity test passed."
  else
    log "Connectivity test failed."
    rollback_changes
    exit 1
  fi

  log "Network interface $INTERFACE has been configured with static IP $IP_ADDRESS/$NETMASK."

else
  log "Invalid mode specified. Please choose 'dhcp' or 'static'."
  usage
fi

# Add DHCP client exit hook script to update /etc/hosts
if [ ! -f "$DHCP_HOOK_SCRIPT" ]; then
  cat > "$DHCP_HOOK_SCRIPT" <<'EOF'
#!/bin/bash

if ([ "$reason" = "BOUND" ] || [ "$reason" = "RENEW" ]); then
  HOSTNAME=$(hostname -s)
  FQDN=$(hostname -f)

  if [ -z "$FQDN" ] || [ "$FQDN" = "(none)" ]; then
    DOMAIN=$(dnsdomainname)
    FQDN="$HOSTNAME.$DOMAIN"
  fi

  sed -i "s|^.*\s$FQDN\s.*$|${new_ip_address} $FQDN $HOSTNAME|" /etc/hosts
fi
EOF

  chmod +x "$DHCP_HOOK_SCRIPT"
  log "DHCP client exit hook script has been added to update /etc/hosts."
else
  log "DHCP client exit hook script already exists."
fi

log "Configuration complete."
