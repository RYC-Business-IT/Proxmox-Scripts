#!/bin/bash

# Script to configure Proxmox VE networking for DHCP or Static IP
# Usage: ./network-config.sh [--mode dhcp|static] [--ip IP_ADDRESS] [--netmask NETMASK]
#        [--gateway GATEWAY] [--dns DNS_SERVERS] [--hostname HOSTNAME]
#        [--interface INTERFACE] [--persistent] [--no-confirm]

# Default variables
MODE=""
IP_ADDRESS=""
NETMASK=""
GATEWAY=""
DNS_SERVERS=""
HOSTNAME=""
INTERFACE=""
PERSISTENT=0
NO_CONFIRM=0
BACKUP_DIR="/var/backups/network-config"
LOGFILE="/var/log/network-config.log"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
TEST_IPS=("8.8.8.8" "1.1.1.1")
MAX_BACKUPS=5

# Function to display usage
usage() {
  echo "Usage: $0 [--mode dhcp|static] [--ip IP_ADDRESS] [--netmask NETMASK]"
  echo "          [--gateway GATEWAY] [--dns DNS_SERVERS] [--hostname HOSTNAME]"
  echo "          [--interface INTERFACE] [--persistent] [--no-confirm]"
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
    --persistent) PERSISTENT=1 ;;
    --no-confirm) NO_CONFIRM=1 ;;
    *) echo "Unknown parameter passed: $1"; usage ;;
  esac
  shift
done

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
  log "Please run as root."
  exit 1
fi

# Function to list interfaces with IP addresses and configuration type
list_interfaces() {
  CONFIGURED_INTERFACES=()
  UNCONFIGURED_INTERFACES=()
  declare -A INTERFACE_IP_MAP
  declare -A INTERFACE_CONFIG_TYPE_MAP

  for IFACE in $(ls /sys/class/net/); do
    if [[ "$IFACE" == "lo" ]]; then
      continue
    fi
    IP_ADDR=$(ip -4 addr show "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}(/\d+)?' | head -n1)
    if [ -n "$IP_ADDR" ]; then
      DHCP_CHECK=$(pgrep -a dhclient | grep "$IFACE")
      if [ -n "$DHCP_CHECK" ]; then
        CONFIG_TYPE="DHCP"
      else
        CONFIG_TYPE="Static"
      fi
      CONFIGURED_INTERFACES+=("$IFACE")
      INTERFACE_IP_MAP["$IFACE"]="$IP_ADDR"
      INTERFACE_CONFIG_TYPE_MAP["$IFACE"]="$CONFIG_TYPE"
    else
      UNCONFIGURED_INTERFACES+=("$IFACE")
      INTERFACE_IP_MAP["$IFACE"]="N/A"
      INTERFACE_CONFIG_TYPE_MAP["$IFACE"]="Unconfigured"
    fi
  done

  # Combine configured and unconfigured interfaces
  INTERFACES_LIST=("${CONFIGURED_INTERFACES[@]}" "${UNCONFIGURED_INTERFACES[@]}")

  echo "Available network interfaces:"
  printf "%-5s %-15s %-20s %-15s\n" "Num" "Interface" "IP Address" "Configuration"
  echo "--------------------------------------------------------------"

  INTERFACE_NUMBERS=()
  i=1
  for IFACE in "${INTERFACES_LIST[@]}"; do
    INTERFACE_NUMBERS[$i]="$IFACE"
    IP_ADDR=${INTERFACE_IP_MAP["$IFACE"]}
    CONFIG_TYPE=${INTERFACE_CONFIG_TYPE_MAP["$IFACE"]}
    printf "%-5s %-15s %-20s %-15s\n" "[$i]" "$IFACE" "$IP_ADDR" "$CONFIG_TYPE"
    i=$((i+1))
  done
}

# Function to collect user inputs
collect_inputs() {
  # List existing interfaces
  list_interfaces

  # If interface not provided, prompt for it
  if [ -z "$INTERFACE" ]; then
    DEFAULT_INTERFACE=""
    DEFAULT_INTERFACE_NUM=""

    # Find vmbr0 if available
    for IDX in "${!INTERFACE_NUMBERS[@]}"; do
      IFACE="${INTERFACE_NUMBERS[$IDX]}"
      if [ "$IFACE" == "vmbr0" ]; then
        DEFAULT_INTERFACE_NUM="$IDX"
        DEFAULT_INTERFACE="vmbr0"
        break
      fi
    done

    if [ "$NO_CONFIRM" -eq 1 ]; then
      if [ -n "$DEFAULT_INTERFACE" ]; then
        INTERFACE="$DEFAULT_INTERFACE"
      else
        log "Interface not specified and vmbr0 not found. Exiting."
        exit 1
      fi
    else
      if [ -n "$DEFAULT_INTERFACE_NUM" ]; then
        read -p "Enter the number of the network interface to configure [$DEFAULT_INTERFACE_NUM]: " INTERFACE_NUM_INPUT
        INTERFACE_NUM=${INTERFACE_NUM_INPUT:-$DEFAULT_INTERFACE_NUM}
      else
        read -p "Enter the number of the network interface to configure: " INTERFACE_NUM
      fi
      if [ -z "$INTERFACE_NUM" ]; then
        log "No interface selected. Exiting."
        exit 1
      fi
      INTERFACE="${INTERFACE_NUMBERS[$INTERFACE_NUM]}"
    fi
  fi

  # Check if interface exists
  if ! ip link show "$INTERFACE" > /dev/null 2>&1; then
    log "Interface $INTERFACE does not exist."
    exit 1
  fi

  # Get current IP address
  CURRENT_IP=$(ip -4 addr show "$INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
  CURRENT_NETMASK=$(ip -o -f inet addr show "$INTERFACE" | awk '/scope global/ {print $4}' | cut -d'/' -f2)

  # Determine if interface is using DHCP
  DHCP_CHECK=$(pgrep -a dhclient | grep "$INTERFACE")
  if [ -n "$DHCP_CHECK" ]; then
    INTERFACE_CONFIG_TYPE="dhcp"
  else
    INTERFACE_CONFIG_TYPE="static"
  fi

  # Interactive mode if parameters are not provided
  if [ -z "$MODE" ]; then
    if [ "$NO_CONFIRM" -eq 1 ]; then
      log "Mode not specified. Exiting."
      exit 1
    else
      echo "Current configuration mode for $INTERFACE is $INTERFACE_CONFIG_TYPE."
      read -p "Enter mode [dhcp/static] [$INTERFACE_CONFIG_TYPE]: " INPUT_MODE
      MODE=${INPUT_MODE:-$INTERFACE_CONFIG_TYPE}
    fi
  fi

  if [ "$MODE" == "dhcp" ]; then
    :
  elif [ "$MODE" == "static" ]; then
    if [ -z "$IP_ADDRESS" ]; then
      if [ "$NO_CONFIRM" -eq 1 ]; then
        log "IP address not specified. Exiting."
        exit 1
      else
        read -p "Enter IP address [$CURRENT_IP]: " IP_ADDRESS
        IP_ADDRESS=${IP_ADDRESS:-$CURRENT_IP}
      fi
    fi

    if [ -z "$NETMASK" ]; then
      if [ "$NO_CONFIRM" -eq 1 ]; then
        log "Netmask not specified. Exiting."
        exit 1
      else
        read -p "Enter Netmask (CIDR notation, e.g., 24) [$CURRENT_NETMASK]: " NETMASK
        NETMASK=${NETMASK:-$CURRENT_NETMASK}
      fi
    fi

    if [ -z "$GATEWAY" ]; then
      DEFAULT_GATEWAY=$(ip route | awk '/default/ {print $3}')
      if [ "$NO_CONFIRM" -eq 1 ]; then
        GATEWAY="$DEFAULT_GATEWAY"
      else
        read -p "Enter Gateway [$DEFAULT_GATEWAY]: " GATEWAY
        GATEWAY=${GATEWAY:-$DEFAULT_GATEWAY}
      fi
    fi

    if [ -z "$DNS_SERVERS" ]; then
      CURRENT_DNS=$(grep 'nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')
      if [ "$NO_CONFIRM" -eq 1 ]; then
        log "DNS servers not specified. Exiting."
        exit 1
      else
        read -p "Enter DNS servers (space-separated) [$CURRENT_DNS]: " DNS_SERVERS
        DNS_SERVERS=${DNS_SERVERS:-$CURRENT_DNS}
      fi
    fi

    if [ -z "$HOSTNAME" ]; then
      CURRENT_HOSTNAME=$(hostname)
      if [ "$NO_CONFIRM" -eq 1 ]; then
        log "Hostname not specified. Exiting."
        exit 1
      else
        read -p "Enter Hostname [$CURRENT_HOSTNAME]: " HOSTNAME
        HOSTNAME=${HOSTNAME:-$CURRENT_HOSTNAME}
      fi
    fi
  else
    log "Invalid mode specified. Please choose 'dhcp' or 'static'."
    usage
  fi

  # Persistence option
  if [ "$PERSISTENT" -eq 0 ]; then
    if [ "$NO_CONFIRM" -eq 1 ]; then
      PERSISTENT=0
    else
      read -p "Do you want to make these changes persistent? [y/N]: " PERSISTENT_CHOICE
      if [[ "$PERSISTENT_CHOICE" =~ ^[Yy]$ ]]; then
        PERSISTENT=1
      else
        PERSISTENT=0
      fi
    fi
  fi

  # Confirm before proceeding
  if [ "$NO_CONFIRM" -ne 1 ]; then
    echo ""
    echo "Configuration Summary:"
    echo "Interface: $INTERFACE"
    echo "Mode: $MODE"
    if [ "$MODE" == "static" ]; then
      echo "IP Address: $IP_ADDRESS/$NETMASK"
      echo "Gateway: $GATEWAY"
      echo "DNS Servers: $DNS_SERVERS"
      echo "Hostname: $HOSTNAME"
    fi
    if [ "$PERSISTENT" -eq 1 ]; then
      echo "Changes will be made persistent."
    else
      echo "Changes will not be persistent."
    fi
    echo ""
    read -p "Proceed with the configuration? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
      log "Configuration cancelled by user."
      exit 0
    fi
  fi
}

# Function to backup configuration files
backup_configs() {
  mkdir -p "$BACKUP_DIR"
  BACKUP_TIMESTAMP=$(date +%Y%m%d%H%M%S)
  BACKUP_PATH="$BACKUP_DIR/backup_$BACKUP_TIMESTAMP"
  mkdir -p "$BACKUP_PATH"

  [ -f /etc/network/interfaces ] && cp /etc/network/interfaces "$BACKUP_PATH/interfaces.bak"
  [ -f /etc/hosts ] && cp /etc/hosts "$BACKUP_PATH/hosts.bak"
  [ -f /etc/resolv.conf ] && cp /etc/resolv.conf "$BACKUP_PATH/resolv.conf.bak"

  log "Backed up configuration files to $BACKUP_PATH."

  # Manage backups - keep only the original and the last 5 backups
  TOTAL_BACKUPS=$(ls -d $BACKUP_DIR/backup_* | wc -l)
  if [ "$TOTAL_BACKUPS" -gt "$MAX_BACKUPS" ]; then
    OLDEST_BACKUP=$(ls -d $BACKUP_DIR/backup_* | head -n 1)
    rm -rf "$OLDEST_BACKUP"
    log "Removed oldest backup: $OLDEST_BACKUP"
  fi
}

# Function to restore backups
restore_backups() {
  echo "Available backups:"
  BACKUP_OPTIONS=()
  i=1
  for BACKUP_PATH in $(ls -d $BACKUP_DIR/backup_* | sort -r); do
    BACKUP_OPTIONS[$i]="$BACKUP_PATH"
    echo "[$i] - $(basename $BACKUP_PATH)"
    i=$((i+1))
  done

  read -p "Enter the number of the backup to restore: " BACKUP_NUM
  SELECTED_BACKUP="${BACKUP_OPTIONS[$BACKUP_NUM]}"

  if [ -d "$SELECTED_BACKUP" ]; then
    [ -f "$SELECTED_BACKUP/interfaces.bak" ] && cp "$SELECTED_BACKUP/interfaces.bak" /etc/network/interfaces
    [ -f "$SELECTED_BACKUP/hosts.bak" ] && cp "$SELECTED_BACKUP/hosts.bak" /etc/hosts
    [ -f "$SELECTED_BACKUP/resolv.conf.bak" ] && cp "$SELECTED_BACKUP/resolv.conf.bak" /etc/resolv.conf
    log "Restored configuration files from $SELECTED_BACKUP."
    systemctl restart networking
    exit 0
  else
    log "Invalid backup selection."
    exit 1
  fi
}

# Check for existing backups and offer to restore
if [ -d "$BACKUP_DIR" ]; then
  echo "Existing backups detected."
  read -p "Do you want to restore a backup? [y/N]: " RESTORE_CHOICE
  if [[ "$RESTORE_CHOICE" =~ ^[Yy]$ ]]; then
    restore_backups
  fi
fi

# Collect inputs
collect_inputs

# Begin configuration
log "Starting network configuration."

if [ "$MODE" == "dhcp" ]; then
  # DHCP Mode
  log "Configuring $INTERFACE for DHCP."

  # Bring interface down
  ip link set dev "$INTERFACE" down

  # Release any existing DHCP leases
  dhclient -r "$INTERFACE" > /dev/null 2>&1

  # Flush IP addresses
  ip addr flush dev "$INTERFACE"

  # Bring interface up
  ip link set dev "$INTERFACE" up

  # Start DHCP client
  dhclient "$INTERFACE"

  log "$INTERFACE configured for DHCP."

elif [ "$MODE" == "static" ]; then
  # Static Mode
  log "Configuring $INTERFACE with static IP."

  # Stop DHCP client if running
  if pgrep -a dhclient | grep -q "$INTERFACE"; then
    dhclient -r "$INTERFACE"
    log "Stopped DHCP client on $INTERFACE."
  fi

  # Bring interface down
  ip link set dev "$INTERFACE" down

  # Flush IP addresses
  ip addr flush dev "$INTERFACE"

  # Configure IP address
  ip addr add "$IP_ADDRESS"/"$NETMASK" dev "$INTERFACE"

  # Configure Gateway
  ip route add default via "$GATEWAY" dev "$INTERFACE" || ip route replace default via "$GATEWAY" dev "$INTERFACE"

  # Bring interface up
  ip link set dev "$INTERFACE" up

  # Set DNS servers
  if command -v resolvconf >/dev/null 2>&1; then
    echo "nameserver $DNS_SERVERS" | resolvconf -a "$INTERFACE"
    log "Configured DNS servers for $INTERFACE using resolvconf."
  else
    echo "nameserver $DNS_SERVERS" > /etc/resolv.conf
    log "Configured DNS servers by modifying /etc/resolv.conf."
  fi

  # Set Hostname
  hostnamectl set-hostname "$HOSTNAME"
  log "Hostname set to $HOSTNAME."

  # Update /etc/hosts
  sed -i "s/127\.0\.1\.1.*/127.0.1.1 $HOSTNAME/" /etc/hosts
  log "Updated /etc/hosts with hostname."

  log "$INTERFACE configured with static IP $IP_ADDRESS/$NETMASK."

else
  log "Invalid mode specified. Exiting."
  exit 1
fi

# Test connectivity
test_connectivity() {
  for IP in "${TEST_IPS[@]}"; do
    log "Testing connectivity to $IP..."
    if ping -c 3 -W 2 "$IP" > /dev/null 2>&1; then
      log "Successfully reached $IP."
      return 0
    else
      log "Failed to reach $IP."
    fi
  done
  return 1
}

if test_connectivity; then
  log "Connectivity test passed."
else
  log "Connectivity test failed."
  if [ "$PERSISTENT" -eq 1 ]; then
    log "Restoring previous configuration from backup."
    restore_backups
  else
    log "Reboot the machine to revert to previous settings."
  fi
  exit 1
fi

# Make changes persistent if requested
if [ "$PERSISTENT" -eq 1 ]; then
  backup_configs

  # Modify /etc/network/interfaces
  sed -i "/auto $INTERFACE/,+5d" /etc/network/interfaces

  if [ "$MODE" == "dhcp" ]; then
    cat >> /etc/network/interfaces <<EOF

# Configuration for $INTERFACE
auto $INTERFACE
iface $INTERFACE inet dhcp
EOF
  elif [ "$MODE" == "static" ]; then
    cat >> /etc/network/interfaces <<EOF

# Configuration for $INTERFACE
auto $INTERFACE
iface $INTERFACE inet static
    address $IP_ADDRESS/$NETMASK
    gateway $GATEWAY
    dns-nameservers $DNS_SERVERS
EOF
  fi

  # Update /etc/hosts and /etc/resolv.conf already done in previous steps
  log "Changes have been made persistent."
else
  log "Changes are temporary and will not persist after a reboot."
fi

# Insert DHCP hook script if DHCP mode and persistent
if [ "$MODE" == "dhcp" ] && [ "$PERSISTENT" -eq 1 ]; then
  DHCP_HOOK_SCRIPT="/etc/dhcp/dhclient-exit-hooks.d/update-etc-hosts"
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
    log "Added DHCP client exit hook script to update /etc/hosts."
  fi
fi

log "Configuration complete."
