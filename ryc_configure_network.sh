#!/bin/bash

# Script to configure network interfaces dynamically using ip command and dhclient
# Does not modify configuration files
# Usage: ./network-config.sh [--mode dhcp|static] [--ip IP_ADDRESS] [--netmask NETMASK]
#        [--gateway GATEWAY] [--interface INTERFACE] [--no-confirm]

# Default variables
MODE=""
IP_ADDRESS=""
NETMASK=""
GATEWAY=""
INTERFACE=""
NO_CONFIRM=0

# Function to display usage
usage() {
  echo "Usage: $0 [--mode dhcp|static] [--ip IP_ADDRESS] [--netmask NETMASK]"
  echo "          [--gateway GATEWAY] [--interface INTERFACE] [--no-confirm]"
  exit 1
}

# Function to log messages
log() {
  MESSAGE="$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $MESSAGE"
  logger -t network-config.sh "$MESSAGE"
}

# Parse parameters
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --mode) MODE="$2"; shift ;;
    --ip) IP_ADDRESS="$2"; shift ;;
    --netmask) NETMASK="$2"; shift ;;
    --gateway) GATEWAY="$2"; shift ;;
    --interface) INTERFACE="$2"; shift ;;
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
    INTERFACE_NUMBERS+=("$IFACE")
    IP_ADDR=${INTERFACE_IP_MAP["$IFACE"]}
    CONFIG_TYPE=${INTERFACE_CONFIG_TYPE_MAP["$IFACE"]}
    printf "%-5s %-15s %-20s %-15s\n" "[$i]" "$IFACE" "$IP_ADDR" "$CONFIG_TYPE"
    i=$((i+1))
  done
}

# Function to test connectivity
test_connectivity() {
  TEST_IPS=("8.8.8.8" "1.1.1.1")
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

# Collect user inputs before making changes
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
        DEFAULT_INTERFACE_NUM=$((IDX+1))
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
      INTERFACE_INDEX=$((INTERFACE_NUM-1))
      INTERFACE="${INTERFACE_NUMBERS[$INTERFACE_INDEX]}"
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
    # DHCP Mode Inputs
    :
  elif [ "$MODE" == "static" ]; then
    # Static Mode Inputs
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

  else
    log "Invalid mode specified. Please choose 'dhcp' or 'static'."
    usage
  fi

  # Confirm before proceeding (if not in no-confirm mode)
  if [ "$NO_CONFIRM" -ne 1 ]; then
    echo ""
    echo "Configuration Summary:"
    echo "Interface: $INTERFACE"
    echo "Mode: $MODE"
    if [ "$MODE" == "static" ]; then
      echo "IP Address: $IP_ADDRESS/$NETMASK"
      echo "Gateway: $GATEWAY"
    fi
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

  log "Interface $INTERFACE configured for DHCP."

elif [ "$MODE" == "static" ]; then
  # Static IP Mode
  log "Configuring network interface $INTERFACE with a static IP."

  # Stop DHCP client if running
  if pgrep -a dhclient | grep -q "$INTERFACE"; then
    dhclient -r "$INTERFACE"
    log "Stopped DHCP client on $INTERFACE."
  fi

  # Bring interface down
  ip link set dev "$INTERFACE" down

  # Flush existing IP addresses
  ip addr flush dev "$INTERFACE"

  # Configure IP address
  ip addr add "$IP_ADDRESS"/"$NETMASK" dev "$INTERFACE"

  # Configure Gateway
  ip route add default via "$GATEWAY" dev "$INTERFACE" || ip route replace default via "$GATEWAY" dev "$INTERFACE"

  # Bring interface up
  ip link set dev "$INTERFACE" up

  log "Interface $INTERFACE configured with static IP $IP_ADDRESS/$NETMASK and gateway $GATEWAY."

else
  log "Invalid mode specified. Exiting."
  exit 1
fi

# Test connectivity
if test_connectivity; then
  log "Connectivity test passed."
else
  log "Connectivity test failed."
  exit 1
fi

log "Configuration complete."
