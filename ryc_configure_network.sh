#!/bin/bash

# Script to configure Proxmox VE networking for DHCP or Static IP
# Includes backup preservation and restoration functionality
# Usage: ./network-config.sh [--mode dhcp|static] [--ip IP_ADDRESS] [--netmask NETMASK]
#        [--gateway GATEWAY] [--dns DNS_SERVERS] [--hostname HOSTNAME]
#        [--interface INTERFACE] [--bridge-ports PORTS] [--test-ip TEST_IP]
#        [--no-confirm] [--restore-backup]

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
NO_CONFIRM=0
RESTORE_BACKUP=0
DHCP_HOOK_SCRIPT="/etc/dhcp/dhclient-exit-hooks.d/update-etc-hosts"
LOGFILE="/var/log/network-config.log"
BACKUP_DIR="/var/backups/network-config"
TIMESTAMP=$(date +%F_%T)
PHYSICAL_INTERFACES=""

# Function to display usage
usage() {
  echo "Usage: $0 [--mode dhcp|static] [--ip IP_ADDRESS] [--netmask NETMASK]"
  echo "          [--gateway GATEWAY] [--dns DNS_SERVERS] [--hostname HOSTNAME]"
  echo "          [--interface INTERFACE] [--bridge-ports PORTS] [--test-ip TEST_IP]"
  echo "          [--no-confirm] [--restore-backup]"
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
    --no-confirm) NO_CONFIRM=1 ;;
    --restore-backup) RESTORE_BACKUP=1 ;;
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
  if [ -d "$BACKUP_DIR/latest" ]; then
    cp "$BACKUP_DIR/latest/interfaces.bak" /etc/network/interfaces
    cp "$BACKUP_DIR/latest/hosts.bak" /etc/hosts
    if [ -f "$BACKUP_DIR/latest/hostname.bak" ]; then
      RESTORED_HOSTNAME=$(cat "$BACKUP_DIR/latest/hostname.bak")
      hostnamectl set-hostname "$RESTORED_HOSTNAME"
    fi
    log "Restored /etc/network/interfaces, /etc/hosts, and hostname."
    ifreload -a
    log "Reapplied original network configuration with ifreload -a."
  else
    log "Backup directory not found. Cannot rollback."
  fi
}

# Function to restore from backup
restore_from_backup() {
  log "Restoring from backup."
  rollback_changes
  exit 0
}

# Check for existing backups and offer to restore
if [ "$RESTORE_BACKUP" -eq 1 ]; then
  if [ -d "$BACKUP_DIR/latest" ]; then
    restore_from_backup
  else
    log "No backup found to restore."
    exit 1
  fi
fi

if [ -d "$BACKUP_DIR/latest" ]; then
  echo "A previous backup was found."
  if [ "$NO_CONFIRM" -eq 1 ]; then
    RESTORE_CHOICE="n"
  else
    read -p "Do you want to restore the previous backup? [y/N]: " RESTORE_CHOICE
  fi
  if [[ "$RESTORE_CHOICE" =~ ^[Yy]$ ]]; then
    restore_from_backup
  fi
fi

# Create a new backup directory with a timestamp
NEW_BACKUP_DIR="$BACKUP_DIR/$TIMESTAMP"
mkdir -p "$NEW_BACKUP_DIR"
log "Created backup directory at $NEW_BACKUP_DIR."

# Backup existing configuration files
cp /etc/network/interfaces "$NEW_BACKUP_DIR/interfaces.bak"
cp /etc/hosts "$NEW_BACKUP_DIR/hosts.bak"
hostnamectl status | grep "Static hostname" | awk '{print $3}' > "$NEW_BACKUP_DIR/hostname.bak"
log "Backed up /etc/network/interfaces, /etc/hosts, and hostname."

# Update the 'latest' symlink to point to the most recent backup
ln -sfn "$NEW_BACKUP_DIR" "$BACKUP_DIR/latest"
log "Updated latest backup symlink."

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

# Collect user inputs before making changes
collect_inputs() {

  # Interactive mode if parameters are not provided
  if [ -z "$MODE" ]; then
    if [ "$NO_CONFIRM" -eq 1 ]; then
      MODE="dhcp"
    else
      echo "Do you want to configure networking for DHCP or Static IP?"
      read -p "Enter mode [dhcp/static] [${MODE:-dhcp}]: " INPUT_MODE
      MODE=${INPUT_MODE:-${MODE:-dhcp}}
    fi
  fi

  # If interface not provided, prompt for it
  if [ -z "$INTERFACE" ]; then
    if [ "$NO_CONFIRM" -eq 1 ]; then
      # Use default INTERFACE
      :
    else
      echo "Available network interfaces:"
      ip -o link show | awk -F': ' '{print $2}'
      read -p "Enter the network interface to configure [${INTERFACE}]: " INPUT_INTERFACE
      INTERFACE=${INPUT_INTERFACE:-$INTERFACE}
    fi
  fi

  # Get current settings again in case INTERFACE changed
  get_current_settings

  if [ "$MODE" == "dhcp" ]; then
    # DHCP Mode Inputs
    if [[ "$INTERFACE" == vmbr* ]]; then
      # Prompt for bridge ports if not provided
      if [ -z "$BRIDGE_PORTS" ]; then
        if [ "$NO_CONFIRM" -eq 1 ]; then
          BRIDGE_PORTS="$CURRENT_BRIDGE_PORTS"
        else
          echo "Enter physical interface(s) to bridge (e.g., eth0). Separate multiple interfaces with spaces."
          read -p "Bridge ports [${CURRENT_BRIDGE_PORTS}]: " INPUT_BRIDGE_PORTS
          BRIDGE_PORTS=${INPUT_BRIDGE_PORTS:-$CURRENT_BRIDGE_PORTS}
        fi
      fi
    fi
  elif [ "$MODE" == "static" ]; then
    # Static Mode Inputs
    if [ -z "$IP_ADDRESS" ]; then
      if [ "$NO_CONFIRM" -eq 1 ]; then
        IP_ADDRESS="$CURRENT_IP"
      else
        read -p "Enter IP address [${CURRENT_IP}]: " IP_ADDRESS
        IP_ADDRESS=${IP_ADDRESS:-$CURRENT_IP}
      fi
    fi

    if [ -z "$NETMASK" ]; then
      if [ "$NO_CONFIRM" -eq 1 ]; then
        NETMASK="$CURRENT_NETMASK"
      else
        read -p "Enter Netmask (CIDR notation, e.g., 24) [${CURRENT_NETMASK}]: " NETMASK
        NETMASK=${NETMASK:-$CURRENT_NETMASK}
      fi
    fi

    if [ -z "$GATEWAY" ]; then
      if [ "$NO_CONFIRM" -eq 1 ]; then
        GATEWAY="$CURRENT_GATEWAY"
      else
        read -p "Enter Gateway [${CURRENT_GATEWAY}]: " GATEWAY
        GATEWAY=${GATEWAY:-$CURRENT_GATEWAY}
      fi
    fi

    if [ -z "$DNS_SERVERS" ]; then
      if [ "$NO_CONFIRM" -eq 1 ]; then
        DNS_SERVERS="$CURRENT_DNS"
      else
        read -p "Enter DNS servers (space-separated) [${CURRENT_DNS}]: " DNS_SERVERS
        DNS_SERVERS=${DNS_SERVERS:-$CURRENT_DNS}
      fi
    fi

    if [ -z "$HOSTNAME" ]; then
      if [ "$NO_CONFIRM" -eq 1 ]; then
        HOSTNAME="$CURRENT_HOSTNAME"
      else
        read -p "Enter Hostname [${CURRENT_HOSTNAME}]: " HOSTNAME
        HOSTNAME=${HOSTNAME:-$CURRENT_HOSTNAME}
      fi
    fi

    if [[ "$INTERFACE" == vmbr* ]]; then
      # Prompt for bridge ports if not provided
      if [ -z "$BRIDGE_PORTS" ]; then
        if [ "$NO_CONFIRM" -eq 1 ]; then
          BRIDGE_PORTS="$CURRENT_BRIDGE_PORTS"
        else
          echo "Enter physical interface(s) to bridge (e.g., eth0). Separate multiple interfaces with spaces."
          read -p "Bridge ports [${CURRENT_BRIDGE_PORTS}]: " INPUT_BRIDGE_PORTS
          BRIDGE_PORTS=${INPUT_BRIDGE_PORTS:-$CURRENT_BRIDGE_PORTS}
        fi
      fi
    fi
  else
    log "Invalid mode specified. Please choose 'dhcp' or 'static'."
    usage
  fi

  # If test IPs not provided, prompt for them
  if [ ${#TEST_IPS[@]} -eq 0 ]; then
    if [ "$NO_CONFIRM" -eq 1 ]; then
      TEST_IPS=("8.8.8.8" "1.1.1.1")
    else
      echo "Enter IP addresses to test connectivity (comma-separated) [8.8.8.8,1.1.1.1]:"
      read -p "Test IPs: " INPUT_TEST_IPS
      if [ -z "$INPUT_TEST_IPS" ]; then
        TEST_IPS=("8.8.8.8" "1.1.1.1")
      else
        IFS=',' read -ra TEST_IPS <<< "$INPUT_TEST_IPS"
      fi
    fi
  fi

  # Confirm before proceeding (if not in no-confirm mode)
  if [ "$NO_CONFIRM" -ne 1 ]; then
    echo ""
    echo "Configuration Summary:"
    echo "Mode: $MODE"
    echo "Interface: $INTERFACE"
    if [[ "$INTERFACE" == vmbr* ]]; then
      echo "Bridge Ports: $BRIDGE_PORTS"
    fi
    if [ "$MODE" == "static" ]; then
      echo "IP Address: $IP_ADDRESS/$NETMASK"
      echo "Gateway: $GATEWAY"
      echo "DNS Servers: $DNS_SERVERS"
      echo "Hostname: $HOSTNAME"
    fi
    echo "Test IPs: ${TEST_IPS[*]}"
    echo ""
    read -p "Proceed with the configuration? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
      log "Configuration cancelled by user."
      exit 0
    fi
  fi
}

# Collect inputs
collect_inputs

# Begin making changes
log "Starting network configuration."

if [ "$MODE" == "dhcp" ]; then
  # DHCP Mode
  log "Configuring network interface $INTERFACE for DHCP."

  # If the interface is a bridge, configure accordingly
  if [[ "$INTERFACE" == vmbr* ]]; then
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

elif [ "$MODE" == "static" ]; then
  # Static IP Mode
  log "Configuring network interface $INTERFACE with a static IP."

  # If the interface is a bridge, configure accordingly
  if [[ "$INTERFACE" == vmbr* ]]; then
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

else
  log "Invalid mode specified. Please choose 'dhcp' or 'static'."
  usage
fi

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
