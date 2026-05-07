#!/bin/bash

# ProtonVPN Credential Rotation Script
# Securely updates credentials without exposing them
# Run with sudo: sudo ./rotate-credentials.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CRED_DIR="/etc/openvpn/auth"

echo -e "${GREEN}ProtonVPN Credential Rotation${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (sudo)${NC}"
   exit 1
fi

# Check if credentials directory exists
if [[ ! -d "$CRED_DIR" ]]; then
    echo -e "${RED}Credentials directory not found. Run setup-protonvpn-secure.sh first.${NC}"
    exit 1
fi

echo -e "${YELLOW}Enter new ProtonVPN OpenVPN credentials.${NC}"
echo "Find them at: https://account.protonvpn.com/account#openvpn"
echo ""

# Read new credentials securely
read -p "Enter your ProtonVPN OpenVPN username: " new_username
read -sp "Enter your ProtonVPN OpenVPN password: " new_password
echo ""

# Validate input
if [[ -z "$new_username" ]] || [[ -z "$new_password" ]]; then
    echo -e "${RED}Username and password cannot be empty.${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}Stopping VPN service...${NC}"
systemctl stop openvpn@protonvpn || true

# Securely overwrite old credentials
echo -e "${YELLOW}Securely removing old credentials...${NC}"
if [[ -f "$CRED_DIR/username" ]]; then
    shred -u "$CRED_DIR/username" 2>/dev/null || rm -f "$CRED_DIR/username"
fi
if [[ -f "$CRED_DIR/password" ]]; then
    shred -u "$CRED_DIR/password" 2>/dev/null || rm -f "$CRED_DIR/password"
fi
if [[ -f "$CRED_DIR/credentials" ]]; then
    shred -u "$CRED_DIR/credentials" 2>/dev/null || rm -f "$CRED_DIR/credentials"
fi

# Write new credentials
echo -e "${YELLOW}Writing new credentials...${NC}"
echo -n "$new_username" > "$CRED_DIR/username"
echo -n "$new_password" > "$CRED_DIR/password"

# Create combined file for OpenVPN
cat > "$CRED_DIR/credentials" << EOF
$new_username
$new_password
EOF

# Set strict permissions
chmod 600 "$CRED_DIR/username"
chmod 600 "$CRED_DIR/password"
chmod 600 "$CRED_DIR/credentials"
chown root:root "$CRED_DIR/username"
chown root:root "$CRED_DIR/password"
chown root:root "$CRED_DIR/credentials"

# Clear variables from memory
unset new_username
unset new_password

echo -e "${YELLOW}Restarting VPN service...${NC}"
systemctl start openvpn@protonvpn

sleep 3

# Verify connection
if ip addr show tun0 &> /dev/null; then
    echo -e "${GREEN}Credentials rotated successfully! VPN connected.${NC}"
    PUBLIC_IP=$(curl -s https://ipinfo.io/ip 2>/dev/null || echo "Could not determine")
    echo -e "Your public IP: ${YELLOW}$PUBLIC_IP${NC}"
else
    echo -e "${RED}VPN connection failed. Check credentials and logs:${NC}"
    echo "sudo journalctl -u openvpn@protonvpn -f"
    exit 1
fi
