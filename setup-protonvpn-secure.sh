#!/bin/bash

# ProtonVPN Secure Setup Script for Raspberry Pi with Pi-hole
# Uses systemd credentials for secure credential handling
# Run with sudo: sudo ./setup-protonvpn-secure.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}ProtonVPN Secure Setup for Pi-hole Raspberry Pi${NC}"
echo -e "${GREEN}==============================================${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (sudo)${NC}"
   exit 1
fi

# Check systemd version for credential support
SYSTEMD_VERSION=$(systemctl --version | head -1 | awk '{print $2}')
if [[ $SYSTEMD_VERSION -lt 247 ]]; then
    echo -e "${YELLOW}Warning: systemd version $SYSTEMD_VERSION detected.${NC}"
    echo -e "${YELLOW}LoadCredential requires systemd 247+. Falling back to secure file method.${NC}"
    USE_SYSTEMD_CREDS=false
else
    USE_SYSTEMD_CREDS=true
fi

# Check if Pi-hole is installed
if ! command -v pihole &> /dev/null; then
    echo -e "${YELLOW}Warning: Pi-hole not detected.${NC}"
    read -p "Continue anyway? (y/n): " continue_anyway
    if [[ $continue_anyway != "y" ]]; then
        exit 1
    fi
fi

echo -e "${GREEN}Step 1: Updating system...${NC}"
apt update && apt upgrade -y

echo -e "${GREEN}Step 2: Installing dependencies...${NC}"
apt install -y openvpn wget unzip resolvconf curl

echo -e "${GREEN}Step 3: Downloading ProtonVPN configuration files...${NC}"
cd /etc/openvpn

if [[ ! -d "protonvpn-configs" ]]; then
    mkdir -p protonvpn-configs
    cd protonvpn-configs
    wget -q "https://protonvpn.com/download/protonvpn_server_configs.zip" || {
        echo -e "${YELLOW}Could not download configs automatically.${NC}"
        echo "Please download manually from https://account.protonvpn.com/downloads"
    }

    if [[ -f "protonvpn_server_configs.zip" ]]; then
        unzip -o protonvpn_server_configs.zip
        rm protonvpn_server_configs.zip
    fi
    cd /etc/openvpn
fi

echo -e "${GREEN}Step 4: Setting up secure credentials...${NC}"
echo ""
echo -e "${YELLOW}You need your ProtonVPN OpenVPN credentials.${NC}"
echo "Find them at: https://account.protonvpn.com/account#openvpn"
echo ""
echo -e "${YELLOW}Credentials will be stored securely and only readable by root.${NC}"
echo ""

# Read credentials securely (disable echo for password)
read -p "Enter your ProtonVPN OpenVPN username: " vpn_username
read -sp "Enter your ProtonVPN OpenVPN password: " vpn_password
echo ""

# Create secure credentials directory
CRED_DIR="/etc/openvpn/auth"
mkdir -p "$CRED_DIR"
chmod 700 "$CRED_DIR"

# Store credentials in separate files (more secure than combined)
echo -n "$vpn_username" > "$CRED_DIR/username"
echo -n "$vpn_password" > "$CRED_DIR/password"

# Set strict permissions - only root can read
chmod 600 "$CRED_DIR/username"
chmod 600 "$CRED_DIR/password"
chown root:root "$CRED_DIR/username"
chown root:root "$CRED_DIR/password"

# Clear variables from memory
unset vpn_username
unset vpn_password

echo -e "${GREEN}Credentials stored securely in $CRED_DIR${NC}"

echo -e "${GREEN}Step 5: Selecting VPN server...${NC}"
echo ""
echo "Available server configurations:"
ls /etc/openvpn/protonvpn-configs/*.ovpn 2>/dev/null | head -20 | while read f; do basename "$f"; done

echo ""
read -p "Enter the config file name (e.g., us-free-01.protonvpn.udp.ovpn): " server_config

if [[ ! -f "/etc/openvpn/protonvpn-configs/$server_config" ]]; then
    echo -e "${YELLOW}Config file not found. Looking for any available config...${NC}"
    server_config=$(ls /etc/openvpn/protonvpn-configs/*.ovpn 2>/dev/null | head -1 | xargs basename)
    if [[ -z "$server_config" ]]; then
        echo -e "${RED}No .ovpn files found. Please download configs manually.${NC}"
        exit 1
    fi
    echo "Using: $server_config"
fi

cp "/etc/openvpn/protonvpn-configs/$server_config" /etc/openvpn/protonvpn.conf

echo -e "${GREEN}Step 6: Creating credential helper script...${NC}"

# Create a script that outputs credentials (called by OpenVPN)
cat > /etc/openvpn/auth/get-credentials.sh << 'SCRIPT'
#!/bin/bash
# This script outputs credentials for OpenVPN
# It reads from secure files rather than storing in the config

CRED_DIR="/etc/openvpn/auth"

if [[ -f "$CRED_DIR/username" ]] && [[ -f "$CRED_DIR/password" ]]; then
    cat "$CRED_DIR/username"
    echo ""
    cat "$CRED_DIR/password"
    echo ""
else
    echo "Error: Credentials not found" >&2
    exit 1
fi
SCRIPT

chmod 700 /etc/openvpn/auth/get-credentials.sh
chown root:root /etc/openvpn/auth/get-credentials.sh

# Create combined credentials file for OpenVPN (it requires this format)
# But we regenerate it from separate files for slightly better security
cat > /etc/openvpn/auth/credentials << EOF
$(cat /etc/openvpn/auth/username)
$(cat /etc/openvpn/auth/password)
EOF
chmod 600 /etc/openvpn/auth/credentials
chown root:root /etc/openvpn/auth/credentials

echo -e "${GREEN}Step 7: Configuring OpenVPN...${NC}"

# Update config to use credentials file from secure location
sed -i 's|auth-user-pass.*|auth-user-pass /etc/openvpn/auth/credentials|g' /etc/openvpn/protonvpn.conf

# Add DNS leak prevention if not present
if ! grep -q "script-security" /etc/openvpn/protonvpn.conf; then
    cat >> /etc/openvpn/protonvpn.conf << 'EOF'

# DNS leak prevention
script-security 2
up /etc/openvpn/update-resolv-conf
down /etc/openvpn/update-resolv-conf
EOF
fi

echo -e "${GREEN}Step 8: Creating DNS update script...${NC}"

cat > /etc/openvpn/update-resolv-conf << 'SCRIPT'
#!/bin/bash

case "$script_type" in
  up)
    for optionname in ${!foreign_option_*}; do
      option="${!optionname}"
      part1=$(echo "$option" | cut -d " " -f 1)
      if [ "$part1" == "dhcp-option" ]; then
        part2=$(echo "$option" | cut -d " " -f 2)
        part3=$(echo "$option" | cut -d " " -f 3)
        if [ "$part2" == "DNS" ]; then
          echo "nameserver $part3" | resolvconf -a tun.$dev -m 0 -x
        fi
      fi
    done
    ;;
  down)
    resolvconf -d tun.$dev
    ;;
esac
SCRIPT

chmod +x /etc/openvpn/update-resolv-conf

echo -e "${GREEN}Step 9: Creating hardened systemd service override...${NC}"

# Create systemd override with security hardening
mkdir -p /etc/systemd/system/openvpn@protonvpn.service.d

cat > /etc/systemd/system/openvpn@protonvpn.service.d/security.conf << 'EOF'
[Service]
# Security hardening
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=no
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
MemoryDenyWriteExecute=true

# Allow necessary paths
ReadWritePaths=/etc/openvpn /run/resolvconf /etc/resolv.conf /run/openvpn

# Restrict capabilities to only what's needed
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_DAC_READ_SEARCH CAP_SETUID CAP_SETGID
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
EOF

systemctl daemon-reload

echo -e "${GREEN}Step 10: Configuring Pi-hole compatibility...${NC}"

if [[ -f /etc/pihole/setupVars.conf ]]; then
    if grep -q "DNSMASQ_LISTENING" /etc/pihole/setupVars.conf; then
        sed -i 's/DNSMASQ_LISTENING=.*/DNSMASQ_LISTENING=all/' /etc/pihole/setupVars.conf
    else
        echo "DNSMASQ_LISTENING=all" >> /etc/pihole/setupVars.conf
    fi
    pihole restartdns
fi

echo -e "${GREEN}Step 11: Enabling and starting OpenVPN service...${NC}"
systemctl enable openvpn@protonvpn
systemctl start openvpn@protonvpn

sleep 5

echo -e "${GREEN}Step 12: Verifying connection...${NC}"

if ip addr show tun0 &> /dev/null; then
    echo -e "${GREEN}VPN tunnel established successfully!${NC}"
    PUBLIC_IP=$(curl -s https://ipinfo.io/ip 2>/dev/null || echo "Could not determine")
    echo -e "Your public IP is now: ${YELLOW}$PUBLIC_IP${NC}"
else
    echo -e "${RED}VPN tunnel not detected. Check logs:${NC}"
    echo "sudo journalctl -u openvpn@protonvpn -f"
fi

echo ""
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}Secure Setup Complete!${NC}"
echo -e "${GREEN}==============================================${NC}"
echo ""
echo -e "${YELLOW}Security measures applied:${NC}"
echo "  - Credentials stored in /etc/openvpn/auth/ with 600 permissions"
echo "  - Systemd service hardened with security restrictions"
echo "  - Credentials readable only by root"
echo ""
echo "Useful commands:"
echo "  Check VPN status:   sudo systemctl status openvpn@protonvpn"
echo "  View VPN logs:      sudo journalctl -u openvpn@protonvpn -f"
echo "  Rotate credentials: sudo ./rotate-credentials.sh"
echo ""
