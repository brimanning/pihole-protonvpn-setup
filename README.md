# Pi-hole + ProtonVPN Setup for Raspberry Pi

This guide covers setting up ProtonVPN alongside Pi-hole on the same Raspberry Pi, allowing you to route all your DNS traffic through Pi-hole while optionally routing internet traffic through ProtonVPN.

## Prerequisites

- Raspberry Pi (3B+, 4, or newer recommended) with Raspberry Pi OS (Debian-based)
- Pi-hole already installed and running
- ProtonVPN account (Free tier works, but Plus/Unlimited recommended for better speeds)
- SSH access to your Raspberry Pi
- Static IP configured on your Pi

## Architecture Overview

```
[Devices] → [Pi-hole (DNS)] → [ProtonVPN Tunnel] → [Internet]
```

Pi-hole handles DNS filtering while ProtonVPN encrypts outbound traffic.

---

## Step 1: Update Your System

```bash
sudo apt update && sudo apt upgrade -y
```

## Step 2: Install Required Dependencies

```bash
sudo apt install -y openvpn wget unzip resolvconf
```

## Step 3: Get ProtonVPN OpenVPN Configuration Files

1. Log into your ProtonVPN account at https://account.protonvpn.com
2. Navigate to **Downloads** → **OpenVPN configuration files**
3. Select your platform: **GNU/Linux**
4. Choose your preferred protocol: **UDP** (recommended) or **TCP**
5. Download configuration files for your desired servers

Alternatively, download all configs:

```bash
cd /etc/openvpn
sudo wget "https://protonvpn.com/download/protonvpn_server_configs.zip"
sudo unzip protonvpn_server_configs.zip
sudo rm protonvpn_server_configs.zip
```

## Step 4: Create ProtonVPN Credentials File

Create a file to store your OpenVPN credentials:

```bash
sudo nano /etc/openvpn/credentials.txt
```

Add your ProtonVPN OpenVPN credentials (found in your ProtonVPN account dashboard under **Account** → **OpenVPN / IKEv2 username**):

```
your_openvpn_username
your_openvpn_password
```

Secure the file:

```bash
sudo chmod 600 /etc/openvpn/credentials.txt
```

## Step 5: Configure OpenVPN Client

Choose a server config file and copy it:

```bash
sudo cp /etc/openvpn/us-free-01.protonvpn.udp.ovpn /etc/openvpn/protonvpn.conf
```

Edit the configuration to use your credentials file:

```bash
sudo nano /etc/openvpn/protonvpn.conf
```

Find the line `auth-user-pass` and change it to:

```
auth-user-pass /etc/openvpn/credentials.txt
```

Add these lines to prevent DNS leaks and work with Pi-hole:

```
script-security 2
up /etc/openvpn/update-resolv-conf
down /etc/openvpn/update-resolv-conf
```

## Step 6: Configure Pi-hole to Work with VPN

### Option A: Pi-hole DNS Only (Recommended for most users)

Keep Pi-hole handling local DNS while the Pi itself uses VPN:

Edit Pi-hole's DNS settings:

```bash
sudo nano /etc/pihole/setupVars.conf
```

Ensure your upstream DNS is set (ProtonVPN's DNS or your preference):

```
PIHOLE_DNS_1=10.8.8.1
PIHOLE_DNS_2=1.1.1.1
```

### Option B: Route All Traffic Through VPN

If you want the Pi itself to route through VPN:

```bash
sudo nano /etc/openvpn/protonvpn.conf
```

Ensure these lines exist:

```
redirect-gateway def1
```

## Step 7: Prevent DNS Leaks

Create a script to update DNS properly:

```bash
sudo nano /etc/openvpn/update-resolv-conf
```

```bash
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
```

Make it executable:

```bash
sudo chmod +x /etc/openvpn/update-resolv-conf
```

## Step 8: Enable and Start OpenVPN Service

```bash
sudo systemctl enable openvpn@protonvpn
sudo systemctl start openvpn@protonvpn
```

Check the status:

```bash
sudo systemctl status openvpn@protonvpn
```

## Step 9: Verify VPN Connection

Check your public IP:

```bash
curl https://ipinfo.io/ip
```

This should show the VPN server's IP, not your home IP.

Check the tunnel interface:

```bash
ip addr show tun0
```

## Step 10: Configure Firewall (Optional but Recommended)

Install and configure UFW to prevent leaks:

```bash
sudo apt install -y ufw

# Allow SSH
sudo ufw allow 22/tcp

# Allow Pi-hole DNS (from local network only)
sudo ufw allow from 192.168.1.0/24 to any port 53

# Allow Pi-hole Web Interface
sudo ufw allow from 192.168.1.0/24 to any port 80

# Allow established connections
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Enable firewall
sudo ufw enable
```

## Step 11: Create Kill Switch (Optional)

Prevent traffic if VPN drops:

```bash
sudo nano /etc/openvpn/killswitch.sh
```

```bash
#!/bin/bash

# Get default interface
DEFAULT_IF=$(ip route | grep default | awk '{print $5}')

# Kill switch - block all traffic except VPN and local
iptables -F
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -i tun0 -j ACCEPT
iptables -A OUTPUT -o tun0 -j ACCEPT
iptables -A INPUT -s 192.168.1.0/24 -j ACCEPT
iptables -A OUTPUT -d 192.168.1.0/24 -j ACCEPT
iptables -A OUTPUT -o $DEFAULT_IF -p udp --dport 1194 -j ACCEPT
iptables -A INPUT -i $DEFAULT_IF -p udp --sport 1194 -j ACCEPT
iptables -A INPUT -j DROP
iptables -A OUTPUT -j DROP
```

```bash
sudo chmod +x /etc/openvpn/killswitch.sh
```

---

## Troubleshooting

### VPN won't connect

Check logs:
```bash
sudo journalctl -u openvpn@protonvpn -f
```

### Pi-hole stops working after VPN connects

Ensure Pi-hole is listening on all interfaces:
```bash
sudo nano /etc/pihole/setupVars.conf
```

Set:
```
DNSMASQ_LISTENING=all
```

Then restart:
```bash
pihole restartdns
```

### DNS leaks detected

Verify resolvconf is working:
```bash
cat /etc/resolv.conf
```

Should show VPN DNS servers when connected.

### Slow speeds

Try different ProtonVPN servers or switch between UDP/TCP protocols.

---

## Quick Setup Script

A convenience script is provided in this repo:

```bash
sudo ./setup-protonvpn.sh
```

---

## Files in This Repository

- `README.md` - This documentation
- `setup-protonvpn.sh` - Automated setup script
- `killswitch.sh` - VPN kill switch script
- `update-resolv-conf` - DNS update script for OpenVPN

## License

MIT License - Feel free to use and modify.

## Contributing

Pull requests welcome! Please test on Raspberry Pi before submitting.
