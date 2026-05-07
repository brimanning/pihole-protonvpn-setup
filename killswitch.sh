#!/bin/bash

# ProtonVPN Kill Switch for Raspberry Pi
# Prevents traffic leaks if VPN connection drops
# Run with sudo: sudo ./killswitch.sh [enable|disable]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (sudo)${NC}"
   exit 1
fi

# Get local network (adjust if different)
LOCAL_NETWORK="192.168.1.0/24"

# Get default interface
DEFAULT_IF=$(ip route | grep default | awk '{print $5}' | head -1)

# ProtonVPN server ports
VPN_PORT_UDP="1194"
VPN_PORT_TCP="443"

enable_killswitch() {
    echo -e "${YELLOW}Enabling VPN Kill Switch...${NC}"

    # Flush existing rules
    iptables -F
    iptables -X

    # Default policies
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT DROP

    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT

    # Allow VPN tunnel
    iptables -A INPUT -i tun0 -j ACCEPT
    iptables -A OUTPUT -o tun0 -j ACCEPT

    # Allow local network (for Pi-hole DNS and web interface)
    iptables -A INPUT -s $LOCAL_NETWORK -j ACCEPT
    iptables -A OUTPUT -d $LOCAL_NETWORK -j ACCEPT

    # Allow VPN connection establishment
    iptables -A OUTPUT -o $DEFAULT_IF -p udp --dport $VPN_PORT_UDP -j ACCEPT
    iptables -A INPUT -i $DEFAULT_IF -p udp --sport $VPN_PORT_UDP -j ACCEPT
    iptables -A OUTPUT -o $DEFAULT_IF -p tcp --dport $VPN_PORT_TCP -j ACCEPT
    iptables -A INPUT -i $DEFAULT_IF -p tcp --sport $VPN_PORT_TCP -j ACCEPT

    # Allow DHCP
    iptables -A OUTPUT -o $DEFAULT_IF -p udp --dport 67:68 -j ACCEPT
    iptables -A INPUT -i $DEFAULT_IF -p udp --sport 67:68 -j ACCEPT

    # Allow established connections
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Save rules
    if command -v iptables-save &> /dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

    echo -e "${GREEN}Kill switch enabled!${NC}"
    echo -e "${YELLOW}Traffic will be blocked if VPN disconnects.${NC}"
}

disable_killswitch() {
    echo -e "${YELLOW}Disabling VPN Kill Switch...${NC}"

    # Flush all rules
    iptables -F
    iptables -X

    # Reset default policies to ACCEPT
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT

    echo -e "${GREEN}Kill switch disabled. Normal traffic restored.${NC}"
}

show_status() {
    echo -e "${YELLOW}Current iptables rules:${NC}"
    iptables -L -n -v
}

case "$1" in
    enable)
        enable_killswitch
        ;;
    disable)
        disable_killswitch
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 {enable|disable|status}"
        echo ""
        echo "  enable  - Activate kill switch (blocks traffic if VPN drops)"
        echo "  disable - Deactivate kill switch (allow normal traffic)"
        echo "  status  - Show current firewall rules"
        exit 1
        ;;
esac
