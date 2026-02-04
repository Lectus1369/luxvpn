#!/bin/bash

# LuxVPN Professional Installer
# GitHub: https://github.com/Lectus1369/luxvpn/

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Config
REPO_URL="https://github.com/Lectus1369/luxvpn/raw/main/src.zip"
ZIP_PASS="mostafa_Bonyanteam1369"
INSTALL_DIR="/usr/local/bin"
TEMP_DIR="/tmp/luxvpn_install"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root"
        exit 1
    fi
}

install_deps() {
    log_info "Updating system and installing dependencies..."
    apt-get update -y
    apt-get install -y curl wget unzip ufw jq uuid-runtime
}

download_files() {
    log_info "Downloading source files..."
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    
    if ! wget -O "$TEMP_DIR/src.zip" "$REPO_URL"; then
        log_error "Failed to download src.zip"
        exit 1
    fi

    log_info "Extracting files..."
    if ! unzip -P "$ZIP_PASS" "$TEMP_DIR/src.zip" -d "$TEMP_DIR"; then
        log_error "Failed to unzip files. Check password or file integrity."
        exit 1
    fi
    
    # Check if files exist (adjust path based on zip structure, assuming flat or in src/)
    # If zip contains a folder (e.g. src/), move contents up
    if [ -d "$TEMP_DIR/src" ]; then
        mv "$TEMP_DIR/src/"* "$TEMP_DIR/"
    fi
}

setup_iran() {
    log_info "Setting up Iran (Bridge) Server..."
    
    # 1. Install Binary
    cp "$TEMP_DIR/bridge" "$INSTALL_DIR/lux-bridge"
    chmod +x "$INSTALL_DIR/lux-bridge"
    
    # 2. Config
    mkdir -p /etc/luxvpn
    cp "$TEMP_DIR/bridge/config.txt" /etc/luxvpn/bridge_config.txt
    
    # Check/Generate UUID
    if ! grep -q "uuid=" /etc/luxvpn/bridge_config.txt; then
        NEW_UUID=$(uuidgen)
        echo "" >> /etc/luxvpn/bridge_config.txt
        echo "uuid=$NEW_UUID" >> /etc/luxvpn/bridge_config.txt
        log_info "Generated new UUID: $NEW_UUID"
    fi
    
    # Read Config Values
    VLESS_PORT=$(grep "vless_listen_addr" /etc/luxvpn/bridge_config.txt | cut -d':' -f2)
    TUNNEL_PORT=$(grep "tunnel_listen_addr" /etc/luxvpn/bridge_config.txt | cut -d':' -f2)
    ADMIN_PORT=$(grep "admin_port" /etc/luxvpn/bridge_config.txt | cut -d'=' -f2)
    LIMIT_MODE=$(grep "limit" /etc/luxvpn/bridge_config.txt | cut -d'=' -f2 | tr -d '\r')

    # 3. Firewall
    log_info "Configuring Firewall..."
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw allow "$VLESS_PORT"/tcp
    ufw allow "$TUNNEL_PORT"/tcp
    
    if [[ "$LIMIT_MODE" != "true" ]]; then
        ufw allow "$ADMIN_PORT"/tcp
        log_info "Admin port $ADMIN_PORT allowed."
    else
        log_warning "Limit mode is enabled. Admin port $ADMIN_PORT is NOT allowed."
    fi
    
    ufw --force enable
    
    # 4. Service
    cat <<EOF > /etc/systemd/system/lux-bridge.service
[Unit]
Description=LuxVPN Bridge Service
After=network.target

[Service]
ExecStart=$INSTALL_DIR/lux-bridge
WorkingDirectory=/etc/luxvpn
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable lux-bridge
    systemctl start lux-bridge
    
    # 5. Output VLESS Config
    PUBLIC_IP=$(curl -s https://api.ipify.org)
    UUID=$(grep "uuid=" /etc/luxvpn/bridge_config.txt | cut -d'=' -f2 | tr -d '\r')
    
    log_success "Iran Server Setup Complete!"
    echo "========================================================"
    echo "VLESS Configuration:"
    echo "vless://$UUID@$PUBLIC_IP:$VLESS_PORT?encryption=none&security=none&type=tcp&headerType=none#default"
    echo "========================================================"
}

setup_foreign() {
    log_info "Setting up Foreign (Exit) Server..."
    
    # 1. Install Binary
    cp "$TEMP_DIR/exit" "$INSTALL_DIR/lux-exit"
    chmod +x "$INSTALL_DIR/lux-exit"
    
    # 2. Config
    mkdir -p /etc/luxvpn
    cp "$TEMP_DIR/exit/config.txt" /etc/luxvpn/exit_config.txt
    
    echo -n "Enter Iran Server IP: "
    read IRAN_IP
    
    # Assuming config has line like: bridge_url=ws://0.0.0.0:8081
    # We replace the IP part.
    # Reading default port from config to be safe, or assuming 8081 if simple replacement
    
    # Simple replacement of the whole URL if we construct it
    # OR regex replace the IP in the existing URL
    
    # Let's replace the whole bridge_url line
    sed -i "s|bridge_url=.*|bridge_url=ws://$IRAN_IP:8081|g" /etc/luxvpn/exit_config.txt
    
    # 3. Firewall
    log_info "Configuring Firewall..."
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw --force enable
    
    # 4. Service
    cat <<EOF > /etc/systemd/system/lux-exit.service
[Unit]
Description=LuxVPN Exit Service
After=network.target

[Service]
ExecStart=$INSTALL_DIR/lux-exit
WorkingDirectory=/etc/luxvpn
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable lux-exit
    systemctl start lux-exit
    
    log_success "Foreign Server Setup Complete!"
}

# Main Execution
check_root

echo "========================================"
echo "    LuxVPN Installer Details"
echo "========================================"
echo "1) Iran Server (Bridge)"
echo "2) Foreign Server (Exit)"
echo -n "Select installation type [1/2]: "
read CHOICE

install_deps
download_files

case $CHOICE in
    1)
        setup_iran
        ;;
    2)
        setup_foreign
        ;;
    *)
        log_error "Invalid selection. Exiting."
        exit 1
        ;;
esac
