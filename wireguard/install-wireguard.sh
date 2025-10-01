#!/bin/bash

set -e

echo "WireGuard-Go Installation Script"
echo "For Ubuntu 14.04"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
   echo "Please run as root (use sudo)"
   exit 1
fi

# Check if config file exists first
if [ ! -f "/etc/wireguard/wg0.conf" ]; then
    echo "ERROR: /etc/wireguard/wg0.conf not found!"
    echo "Please create this file first with your WireGuard configuration"
    echo "Example format:"
    echo "[Interface]"
    echo "PrivateKey = YOUR_PRIVATE_KEY"
    echo "Address = 10.10.10.102/32"
    echo ""
    echo "[Peer]"
    echo "PublicKey = PEER_PUBLIC_KEY"
    echo "Endpoint = PEER_IP:PORT"
    echo "AllowedIPs = 10.10.10.0/24"
    exit 1
fi

echo "[1/4] Installing dependencies..."
apt-get update
apt-get install -y git build-essential

# Install Go if not present
if ! command -v go &> /dev/null; then
    echo "[2/4] Installing Go 1.23.2..."
    cd /tmp
    wget -q https://dl.google.com/go/go1.23.2.linux-amd64.tar.gz
    tar -C /usr/local -xzf go1.23.2.linux-amd64.tar.gz
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
    export PATH=$PATH:/usr/local/go/bin
    rm go1.23.2.linux-amd64.tar.gz
else
    echo "[2/4] Go is already installed: $(go version)"
fi

echo "[3/4] Building WireGuard-Go..."
cd /tmp
rm -rf wireguard-go
git clone -q https://github.com/WireGuard/wireguard-go.git
cd wireguard-go
git checkout -q 0.0.20201118
go build -o wireguard-go
cp wireguard-go /usr/local/bin/
chmod +x /usr/local/bin/wireguard-go
cd /
rm -rf /tmp/wireguard-go

echo "[4/4] Creating startup script..."
cat > /usr/local/bin/wg-start << 'SCRIPT_END'
#!/bin/bash

CONFIG_FILE="/etc/wireguard/wg0.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: $CONFIG_FILE not found!"
    exit 1
fi

echo "Reading configuration from $CONFIG_FILE..."

# Function to extract value from config
extract_value() {
    local key="$1"
    local value=$(grep "^${key}" "$CONFIG_FILE" | sed "s/^${key}[[:space:]]*=[[:space:]]*//")
    echo "$value"
}

# Extract Address from the config file
ADDRESS=$(extract_value "Address")
if [ -z "$ADDRESS" ]; then
    echo "Error: No Address found in config file!"
    exit 1
fi

# Parse the Address field
IP_ADDR=$(echo $ADDRESS | cut -d'/' -f1)
SUBNET_MASK=$(echo $ADDRESS | grep -o '/[0-9]*' | tr -d '/')
if [ -z "$SUBNET_MASK" ]; then
    SUBNET_MASK="32"
fi

# Extract other optional values
MTU=$(extract_value "MTU")
[ -z "$MTU" ] && MTU="1420"

echo "Configuration extracted:"
echo "  Address: ${IP_ADDR}/${SUBNET_MASK}"
echo "  MTU: $MTU"

# Clean up any existing interface
echo "Cleaning up existing WireGuard interface..."
pkill -f wireguard-go 2>/dev/null || true
ip link del wg0 2>/dev/null || true

# Start WireGuard-Go
echo "Starting WireGuard-Go..."
/usr/local/bin/wireguard-go wg0 &
sleep 2

# Check if process started
if ! pgrep -f "wireguard-go wg0" > /dev/null; then
    echo "Error: Failed to start wireguard-go!"
    exit 1
fi

# Create temp config without fields that wg setconf doesn't accept
echo "Loading WireGuard configuration..."
grep -v "^Address\|^MTU\|^DNS\|^Table\|^PreUp\|^PostUp\|^PreDown\|^PostDown\|^SaveConfig" "$CONFIG_FILE" > /tmp/wg0-temp.conf

# Load configuration
wg setconf wg0 /tmp/wg0-temp.conf
rm -f /tmp/wg0-temp.conf

# Configure the network interface with extracted Address
echo "Configuring network interface..."
ip address add ${IP_ADDR}/${SUBNET_MASK} dev wg0
ip link set mtu $MTU dev wg0
ip link set wg0 up

# Extract and add routes for all AllowedIPs from peer sections
echo "Adding routes..."
ROUTES_ADDED=0
while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*(.*) ]]; then
        ALLOWED_IPS="${BASH_REMATCH[1]}"
        # Remove comments if any
        ALLOWED_IPS=$(echo "$ALLOWED_IPS" | sed 's/#.*//')
        # Handle multiple IPs separated by commas
        IFS=',' read -ra IPS <<< "$ALLOWED_IPS"
        for ip in "${IPS[@]}"; do
            ip=$(echo $ip | tr -d ' ')
            if [ ! -z "$ip" ] && [ "$ip" != "0.0.0.0/0" ]; then
                echo "  Adding route for $ip via wg0"
                ip route add $ip dev wg0 2>/dev/null || echo "    Route for $ip already exists or failed"
                ROUTES_ADDED=$((ROUTES_ADDED + 1))
            elif [ "$ip" = "0.0.0.0/0" ]; then
                echo "  Default route (0.0.0.0/0) detected - skipping (configure manually if needed)"
            fi
        done
    fi
done < "$CONFIG_FILE"

echo ""
echo "WireGuard started successfully!"
echo ""
wg show
echo ""
echo "Interface IP: ${IP_ADDR}/${SUBNET_MASK}"
echo "Routes added: $ROUTES_ADDED"
SCRIPT_END

chmod +x /usr/local/bin/wg-start

# Create stop script
cat > /usr/local/bin/wg-stop << 'SCRIPT_END'
#!/bin/bash
echo "Stopping WireGuard..."
pkill -f wireguard-go
ip link del wg0 2>/dev/null
echo "WireGuard stopped"
SCRIPT_END

chmod +x /usr/local/bin/wg-stop

# Create status script
cat > /usr/local/bin/wg-status << 'SCRIPT_END'
#!/bin/bash
if pgrep -f "wireguard-go wg0" > /dev/null; then
    echo "WireGuard is running"
    echo ""
    wg show
    echo ""
    echo "Interface details:"
    ip addr show wg0 2>/dev/null
    echo ""
    echo "Routes via wg0:"
    ip route | grep wg0
else
    echo "WireGuard is not running"
fi
SCRIPT_END

chmod +x /usr/local/bin/wg-status

echo ""
echo "Installation complete!"
echo ""
echo "Configuration found at: /etc/wireguard/wg0.conf"
echo ""
echo "Commands available:"
echo "  Start:   wg-start"
echo "  Stop:    wg-stop"
echo "  Status:  wg-status"
echo ""
echo "To start WireGuard now, run: wg-start"