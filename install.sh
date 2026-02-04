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
    apt-get install -y curl wget unzip ufw jq uuid-runtime file build-essential pkg-config libssl-dev
    
    # Check for Rust
    if ! command -v cargo &> /dev/null; then
        log_info "Rust not found. Installing Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    else
        log_info "Rust is already installed."
    fi
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
    
    # Build from source
    log_info "Building Bridge and Exit services (This may take a while)..."
    cd "$TEMP_DIR"
    
    # Ensure dependencies are available in current shell
    source "$HOME/.cargo/env"
    
    if ! cargo build --release; then
        log_error "Build failed! Checking for common issues..."
        # Fallback or detailed error
        log_warning "Please check if the server has enough RAM (at least 1GB recommended)."
        exit 1
    fi
    
    log_success "Build successful!"
}

setup_iran() {
    log_info "Setting up Iran (Bridge) Server..."
    
    # 1. Install Binary
    # Assuming the project is a workspace or single crate with binaries. 
    # Usually output is in target/release/
    
    if [ -f "$TEMP_DIR/target/release/bridge" ]; then
        cp "$TEMP_DIR/target/release/bridge" "$INSTALL_DIR/lux-bridge"
    elif [ -f "$TEMP_DIR/target/release/lux-bridge" ]; then
         cp "$TEMP_DIR/target/release/lux-bridge" "$INSTALL_DIR/lux-bridge"
    else
        # Try finding it if name is different
        log_error "Compiled binary 'bridge' not found in target/release/"
        exit 1
    fi

    chmod +x "$INSTALL_DIR/lux-bridge"
    
    # 2. Config
    mkdir -p /etc/luxvpn
    # Assuming config is in the source root or specific folder. 
    # Using 'bridge/config.txt' based on previous structure, but check root too.
    if [ -f "$TEMP_DIR/bridge/config.txt" ]; then
         cp "$TEMP_DIR/bridge/config.txt" /etc/luxvpn/bridge_config.txt
    elif [ -f "$TEMP_DIR/config.txt" ]; then
         cp "$TEMP_DIR/config.txt" /etc/luxvpn/bridge_config.txt
    else
         log_error "Config file for bridge not found."
         exit 1
    fi
    
    # Check/Generate UUID
    if ! grep -q "uuid=" /etc/luxvpn/bridge_config.txt; then
        NEW_UUID=$(uuidgen)
        # Ensure newline before appending
        echo "" >> /etc/luxvpn/bridge_config.txt
        echo "uuid=$NEW_UUID" >> /etc/luxvpn/bridge_config.txt
        log_info "Generated new UUID: $NEW_UUID"
    fi
    
    # Read Config Values
    # Sanitizing input to remove \r and whitespace
    VLESS_PORT=$(grep "vless_listen_addr" /etc/luxvpn/bridge_config.txt | cut -d':' -f2 | tr -d '\r' | tr -d ' ')
    TUNNEL_PORT=$(grep "tunnel_listen_addr" /etc/luxvpn/bridge_config.txt | cut -d':' -f2 | tr -d '\r' | tr -d ' ')
    ADMIN_PORT=$(grep "admin_port" /etc/luxvpn/bridge_config.txt | cut -d'=' -f2 | tr -d '\r' | tr -d ' ')
    LIMIT_MODE=$(grep "limit" /etc/luxvpn/bridge_config.txt | cut -d'=' -f2 | tr -d '\r' | tr -d ' ')

    # Verify Binary
    if [ ! -f "$INSTALL_DIR/lux-bridge" ]; then
        log_error "Binary not found at $INSTALL_DIR/lux-bridge"
        exit 1
    fi
    
    # Since we just compiled it, it should be correct. But we can keep the check.
    BIN_TYPE=$(file "$INSTALL_DIR/lux-bridge")
    log_info "Binary info: $BIN_TYPE"


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
    PUBLIC_IP=$(curl -s https://api.ipify.org | tr -d '\r' | tr -d ' ')
    UUID=$(grep "uuid=" /etc/luxvpn/bridge_config.txt | cut -d'=' -f2 | tr -d '\r' | tr -d ' ')
    
    log_success "Iran Server Setup Complete!"
    echo "========================================================"
    echo "VLESS Configuration:"
    printf "vless://%s@%s:%s?encryption=none&security=none&type=tcp&headerType=none#default\n" "$UUID" "$PUBLIC_IP" "$VLESS_PORT"
    echo "========================================================"
}

setup_foreign() {
    log_info "Setting up Foreign (Exit) Server..."
    
    # 1. Install Binary
    if [ -f "$TEMP_DIR/target/release/exit" ]; then
        cp "$TEMP_DIR/target/release/exit" "$INSTALL_DIR/lux-exit"
    elif [ -f "$TEMP_DIR/target/release/lux-exit" ]; then
         cp "$TEMP_DIR/target/release/lux-exit" "$INSTALL_DIR/lux-exit"
    else
        log_error "Compiled binary 'exit' not found in target/release/"
        exit 1
    fi
    chmod +x "$INSTALL_DIR/lux-exit"
    
    # 2. Config
    mkdir -p /etc/luxvpn
    if [ -f "$TEMP_DIR/exit/config.txt" ]; then
         cp "$TEMP_DIR/exit/config.txt" /etc/luxvpn/exit_config.txt
    elif [ -f "$TEMP_DIR/config_exit.txt" ]; then
         cp "$TEMP_DIR/config_exit.txt" /etc/luxvpn/exit_config.txt
    else
         # Fallback try to copy from bridge location if structure is odd, but ideally fail
          log_error "Config file for exit not found."
          exit 1
    fi
    
    echo "========================================================"
    log_warning "ACTION REQUIRED: A-Record Setup"
    echo "Please go to your DNS provider (e.g., Cloudflare) and create an 'A' record."
    echo "Name: your-subdomain (e.g., 'fin')"
    echo "Content/IP: <IP_ADDRESS_OF_IRAN_SERVER>"
    echo "Proxy status: DNS Only (Disabled)"
    echo "========================================================"
    echo ""
    echo -n "Enter the Domain you set (e.g., fin.hairdware.com): "
    read IRAN_DOMAIN
    
    if [ -z "$IRAN_DOMAIN" ]; then
        log_error "Domain cannot be empty."
        exit 1
    fi
    
    log_info "Configuring connection to: ws://$IRAN_DOMAIN:8081"
    
    # Update config
    sed -i "s|bridge_url=.*|bridge_url=ws://$IRAN_DOMAIN:8081|g" /etc/luxvpn/exit_config.txt
    
    # Verify Binary
    if [ ! -f "$INSTALL_DIR/lux-exit" ]; then
        log_error "Binary not found at $INSTALL_DIR/lux-exit"
        exit 1
    fi
    
    BIN_TYPE=$(file "$INSTALL_DIR/lux-exit")
    log_info "Binary info: $BIN_TYPE"
    
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
