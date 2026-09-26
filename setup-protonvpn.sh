#!/bin/bash

# ProtonVPN Setup Script for Raspberry Pi with Pi-hole
# Run with sudo: sudo ./setup-protonvpn.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}ProtonVPN Setup for Pi-hole Raspberry Pi${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (sudo)${NC}"
   exit 1
fi

# Check if Pi-hole is installed
if ! command -v pihole &> /dev/null; then
    echo -e "${YELLOW}Warning: Pi-hole not detected. This script is designed to work alongside Pi-hole.${NC}"
    read -p "Continue anyway? (y/n): " continue_anyway
    if [[ $continue_anyway != "y" ]]; then
        exit 1
    fi
fi

echo -e "${GREEN}Step 1: Updating system...${NC}"
apt update && apt upgrade -y

echo -e "${GREEN}Step 2: Installing dependencies...${NC}"
apt install -y openvpn wget unzip resolvconf curl

echo -e "${GREEN}Step 3: Checking for ProtonVPN configuration files...${NC}"
cd /etc/openvpn

# Proton no longer publishes a bulk config zip; configs must be downloaded from the dashboard
if ! ls /etc/openvpn/*.ovpn &> /dev/null; then
    echo -e "${YELLOW}Download .ovpn files from https://account.protonvpn.com/downloads${NC}"
    echo "(OpenVPN configuration files → GNU/Linux) and copy them to /etc/openvpn/"
    echo "Then re-run this script."
    exit 1
fi

echo -e "${GREEN}Step 4: Setting up credentials...${NC}"
echo ""
echo -e "${YELLOW}You need your ProtonVPN OpenVPN credentials.${NC}"
echo "Find them at: https://account.protonvpn.com/account#openvpn"
echo ""

read -p "Enter your ProtonVPN OpenVPN username: " vpn_username
read -sp "Enter your ProtonVPN OpenVPN password: " vpn_password
echo ""

cat > /etc/openvpn/credentials.txt << EOF
$vpn_username
$vpn_password
EOF

chmod 600 /etc/openvpn/credentials.txt
echo -e "${GREEN}Credentials saved securely.${NC}"

echo -e "${GREEN}Step 5: Selecting VPN server...${NC}"
echo ""
echo "Available server configurations:"
ls /etc/openvpn/*.ovpn 2>/dev/null | head -20 | while read f; do basename "$f"; done

echo ""
read -p "Enter the config file name (e.g., de-123.protonvpn.udp.ovpn): " server_config

if [[ ! -f "/etc/openvpn/$server_config" ]]; then
    echo -e "${RED}Config file not found: /etc/openvpn/$server_config${NC}"
    exit 1
fi

cp "/etc/openvpn/$server_config" /etc/openvpn/protonvpn.conf

echo -e "${GREEN}Step 6: Configuring OpenVPN...${NC}"

# Update config to use credentials file
sed -i 's|auth-user-pass|auth-user-pass /etc/openvpn/credentials.txt|g' /etc/openvpn/protonvpn.conf

# Add DNS leak prevention
if ! grep -q "script-security" /etc/openvpn/protonvpn.conf; then
    cat >> /etc/openvpn/protonvpn.conf << 'EOF'

# DNS leak prevention
script-security 2
up /etc/openvpn/update-resolv-conf
down /etc/openvpn/update-resolv-conf
EOF
fi

echo -e "${GREEN}Step 7: Creating DNS update script...${NC}"

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

echo -e "${GREEN}Step 8: Configuring Pi-hole compatibility...${NC}"

# Ensure Pi-hole listens on all interfaces
# Pi-hole v6 stores settings in pihole.toml; v5 used setupVars.conf
if [[ -f /etc/pihole/pihole.toml ]]; then
    pihole-FTL --config dns.listeningMode ALL
    pihole restartdns
elif [[ -f /etc/pihole/setupVars.conf ]]; then
    if grep -q "DNSMASQ_LISTENING" /etc/pihole/setupVars.conf; then
        sed -i 's/DNSMASQ_LISTENING=.*/DNSMASQ_LISTENING=all/' /etc/pihole/setupVars.conf
    else
        echo "DNSMASQ_LISTENING=all" >> /etc/pihole/setupVars.conf
    fi

    # Restart Pi-hole DNS
    pihole restartdns
fi

echo -e "${GREEN}Step 9: Enabling and starting OpenVPN service...${NC}"
systemctl enable openvpn@protonvpn
systemctl start openvpn@protonvpn

# Wait for connection
echo "Waiting for VPN connection..."
sleep 5

echo -e "${GREEN}Step 10: Verifying connection...${NC}"

# Check if tun0 exists
if ip addr show tun0 &> /dev/null; then
    echo -e "${GREEN}VPN tunnel established successfully!${NC}"

    # Get public IP
    PUBLIC_IP=$(curl -s https://ipinfo.io/ip 2>/dev/null || echo "Could not determine")
    echo -e "Your public IP is now: ${YELLOW}$PUBLIC_IP${NC}"
else
    echo -e "${RED}VPN tunnel not detected. Check logs with:${NC}"
    echo "sudo journalctl -u openvpn@protonvpn -f"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Useful commands:"
echo "  Check VPN status:   sudo systemctl status openvpn@protonvpn"
echo "  View VPN logs:      sudo journalctl -u openvpn@protonvpn -f"
echo "  Restart VPN:        sudo systemctl restart openvpn@protonvpn"
echo "  Stop VPN:           sudo systemctl stop openvpn@protonvpn"
echo "  Check public IP:    curl https://ipinfo.io/ip"
echo ""
echo -e "${YELLOW}Note: Your local devices should still use Pi-hole for DNS.${NC}"
echo -e "${YELLOW}The VPN encrypts traffic from the Pi itself.${NC}"
