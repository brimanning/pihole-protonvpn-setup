#!/bin/bash

# ProtonVPN Uninstall Script for Raspberry Pi
# Reverses the setup performed by setup-protonvpn.sh
# Run with sudo: sudo ./uninstall-protonvpn.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}========================================${NC}"
echo -e "${RED}ProtonVPN Uninstall Script${NC}"
echo -e "${RED}========================================${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (sudo)${NC}"
   exit 1
fi

echo -e "${YELLOW}This will remove ProtonVPN configuration from your Raspberry Pi.${NC}"
echo ""
read -p "Are you sure you want to continue? (y/n): " confirm
if [[ $confirm != "y" ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

# Step 1: Stop and disable OpenVPN service
echo -e "${GREEN}Step 1: Stopping OpenVPN service...${NC}"
if systemctl is-active --quiet openvpn@protonvpn; then
    systemctl stop openvpn@protonvpn
    echo "  - Service stopped"
else
    echo "  - Service was not running"
fi

if systemctl is-enabled --quiet openvpn@protonvpn 2>/dev/null; then
    systemctl disable openvpn@protonvpn
    echo "  - Service disabled"
else
    echo "  - Service was not enabled"
fi

# Step 2: Remove ProtonVPN configuration files
echo -e "${GREEN}Step 2: Removing ProtonVPN configuration files...${NC}"

if [[ -f /etc/openvpn/protonvpn.conf ]]; then
    rm /etc/openvpn/protonvpn.conf
    echo "  - Removed protonvpn.conf"
fi

if [[ -f /etc/openvpn/credentials.txt ]]; then
    # Securely delete credentials
    shred -u /etc/openvpn/credentials.txt 2>/dev/null || rm /etc/openvpn/credentials.txt
    echo "  - Securely removed credentials.txt"
fi

if [[ -f /etc/openvpn/update-resolv-conf ]]; then
    rm /etc/openvpn/update-resolv-conf
    echo "  - Removed update-resolv-conf"
fi

# Step 3: Remove downloaded ProtonVPN server configs
echo -e "${GREEN}Step 3: Removing ProtonVPN server configs...${NC}"
read -p "Remove all downloaded .ovpn files from /etc/openvpn? (y/n): " remove_ovpn
if [[ $remove_ovpn == "y" ]]; then
    rm -f /etc/openvpn/*.ovpn 2>/dev/null || true
    rm -f /etc/openvpn/*.protonvpn.*.ovpn 2>/dev/null || true
    echo "  - Removed .ovpn files"
else
    echo "  - Skipped (keeping .ovpn files)"
fi

# Step 4: Reset iptables (if kill switch was enabled)
echo -e "${GREEN}Step 4: Resetting firewall rules...${NC}"
read -p "Reset iptables rules to default (allow all)? (y/n): " reset_iptables
if [[ $reset_iptables == "y" ]]; then
    iptables -F
    iptables -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT

    # Clear saved rules if they exist
    rm -f /etc/iptables/rules.v4 2>/dev/null || true

    echo "  - iptables reset to defaults"
else
    echo "  - Skipped (keeping current firewall rules)"
fi

# Step 5: Reset Pi-hole DNS listening setting
echo -e "${GREEN}Step 5: Checking Pi-hole configuration...${NC}"
if [[ -f /etc/pihole/setupVars.conf ]]; then
    read -p "Reset Pi-hole DNSMASQ_LISTENING to 'local'? (y/n): " reset_pihole
    if [[ $reset_pihole == "y" ]]; then
        sed -i 's/DNSMASQ_LISTENING=all/DNSMASQ_LISTENING=local/' /etc/pihole/setupVars.conf
        pihole restartdns
        echo "  - Pi-hole DNS listening reset to local"
    else
        echo "  - Skipped (keeping Pi-hole settings)"
    fi
else
    echo "  - Pi-hole not detected, skipping"
fi

# Step 6: Optionally remove OpenVPN package
echo -e "${GREEN}Step 6: OpenVPN package...${NC}"
read -p "Remove OpenVPN package completely? (y/n): " remove_openvpn
if [[ $remove_openvpn == "y" ]]; then
    apt remove -y openvpn
    apt autoremove -y
    echo "  - OpenVPN package removed"
else
    echo "  - Skipped (keeping OpenVPN installed)"
fi

# Step 7: Restore original resolv.conf if needed
echo -e "${GREEN}Step 7: Restoring DNS configuration...${NC}"
if command -v resolvconf &> /dev/null; then
    resolvconf -u
    echo "  - DNS configuration refreshed"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Uninstall Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "ProtonVPN has been removed from your system."
echo ""
echo "If you experience any issues:"
echo "  - Restart your Pi: sudo reboot"
echo "  - Check DNS: cat /etc/resolv.conf"
echo "  - Verify internet: ping -c 3 google.com"
echo ""
echo -e "${YELLOW}Pi-hole should continue working normally for DNS filtering.${NC}"
