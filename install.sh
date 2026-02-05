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

    echo "========================================================"
    echo -n "Enter Security Code (ZIP Password): "
    read -r SECURITY_CODE
    echo "========================================================"

    log_info "Extracting files..."
    if ! unzip -P "$SECURITY_CODE" "$TEMP_DIR/src.zip" -d "$TEMP_DIR"; then
        log_error "Failed to unzip files. Incorrect Security Code or corrupt file."
        exit 1
    fi
    
    # Check if files exist (adjust path based on zip structure, assuming flat or in src/)
    # If zip contains a folder (e.g. src/), move contents up
    if [ -d "$TEMP_DIR/src" ]; then
        mv "$TEMP_DIR/src/"* "$TEMP_DIR/"
    fi
    
    # Build from source or use pre-compiled
    cd "$TEMP_DIR"
    
    # Check for binaries (lux-bridge/lux-exit which user renamed, or original bridge/exit)
    if { [ -f "lux-bridge" ] && [ -f "lux-exit" ]; }; then
        log_info "Pre-compiled binaries (lux-bridge, lux-exit) found. Skipping build."
        cp lux-bridge bridge # Normalize standard names for logic below if needed, or just use them
        cp lux-exit exit
    elif { [ -f "bridge" ] && [ -f "exit" ]; }; then
        log_info "Pre-compiled binaries (bridge, exit) found. Skipping build."
        chmod +x bridge exit
    else
        log_info "Binaries not found. Starting build from source..."
        
        # Check Rust only if building
        if ! command -v cargo &> /dev/null; then
             source "$HOME/.cargo/env"
        fi

        # Ensure dependencies are available in current shell
        # source "$HOME/.cargo/env" # Already sourced or checked
        
        if ! cargo build --release; then
            log_error "Build failed! Checking for common issues..."
            log_warning "Please check if the server has enough RAM (at least 1GB recommended)."
            exit 1
        fi
        log_success "Build successful!"
    fi
}

setup_iran() {
    log_info "Setting up Iran (Bridge) Server..."
    
    # 1. Install Binary
    # Check pre-compiled binaries (both standard "bridge" and user-renamed "lux-bridge")
    
    if [ -f "$TEMP_DIR/lux-bridge" ]; then
         cp "$TEMP_DIR/lux-bridge" "$INSTALL_DIR/lux-bridge"
    elif [ -f "$TEMP_DIR/bridge" ]; then
         cp "$TEMP_DIR/bridge" "$INSTALL_DIR/lux-bridge"
    elif [ -f "$TEMP_DIR/target/release/bridge" ]; then
        cp "$TEMP_DIR/target/release/bridge" "$INSTALL_DIR/lux-bridge"
    elif [ -f "$TEMP_DIR/target/release/lux-bridge" ]; then
         cp "$TEMP_DIR/target/release/lux-bridge" "$INSTALL_DIR/lux-bridge"
    else
        # Try finding it if name is different
        log_error "Binary 'bridge' or 'lux-bridge' not found in $TEMP_DIR"
        exit 1
    fi

    chmod +x "$INSTALL_DIR/lux-bridge"
    
    # 2. Config
    mkdir -p /etc/luxvpn
    # Assuming config is in the source root or specific folder. 
    # Using 'bridge/config.txt' based on previous structure, but check root too.
    if [ -f "$TEMP_DIR/bridge/config.txt" ]; then
         cp "$TEMP_DIR/bridge/config.txt" /etc/luxvpn/config.txt
    elif [ -f "$TEMP_DIR/config.txt" ]; then
         cp "$TEMP_DIR/config.txt" /etc/luxvpn/config.txt
        else
         log_error "Config file for bridge not found."
         exit 1
    fi
    
    # Check/Generate UUID
    if ! grep -q "uuid=" /etc/luxvpn/config.txt; then
        NEW_UUID=$(uuidgen)
        # Ensure newline before appending
        echo "" >> /etc/luxvpn/config.txt
        echo "uuid=$NEW_UUID" >> /etc/luxvpn/config.txt
        log_info "Generated new UUID: $NEW_UUID"
    fi
    
    # Read Config Values
    # Sanitizing input to remove \r and whitespace
    VLESS_PORT=$(grep "vless_listen_addr" /etc/luxvpn/config.txt | cut -d':' -f2 | tr -d '\r' | tr -d ' ')
    TUNNEL_PORT=$(grep "tunnel_listen_addr" /etc/luxvpn/config.txt | cut -d':' -f2 | tr -d '\r' | tr -d ' ')
    ADMIN_PORT=$(grep "admin_port" /etc/luxvpn/config.txt | cut -d'=' -f2 | tr -d '\r' | tr -d ' ')
    LIMIT_MODE=$(grep "limit" /etc/luxvpn/config.txt | cut -d'=' -f2 | tr -d '\r' | tr -d ' ')

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
    
    # SSL Setup
    echo "========================================================"
    echo "Do you want to enable SSL (WSS) using Certbot & Nginx? [y/N]"
    read -r ENABLE_SSL
    if [[ "$ENABLE_SSL" =~ ^[Yy]$ ]]; then
        log_info "Installing Nginx and Certbot..."
        apt-get install -y nginx certbot python3-certbot-nginx
        
        echo -n "Enter the Domain for this server (Iran) (e.g., bridge.example.com): "
        read BRIDGE_DOMAIN
        
        if [ -z "$BRIDGE_DOMAIN" ]; then
             log_error "Domain is required for SSL."
             exit 1
        fi
        
        # Open ports for Certbot
        ufw allow 80/tcp
        ufw allow 443/tcp
        
        # Stop Nginx to avoid conflicts during cert generation if using standalone (but we use --nginx)
        systemctl stop nginx
        
        # Run Certbot
        log_info "Obtaining SSL Certificate..."
        certbot certonly --standalone -d "$BRIDGE_DOMAIN" --non-interactive --agree-tos -m admin@"$BRIDGE_DOMAIN"
        
        # Write Nginx Config
        cat <<NGINX > /etc/nginx/sites-available/luxvpn
server {
    listen 80;
    server_name $BRIDGE_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $BRIDGE_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$BRIDGE_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$BRIDGE_DOMAIN/privkey.pem;

    location /ws {
        proxy_pass http://127.0.0.1:$TUNNEL_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$host;
        
        # Increase timeouts for WebSocket
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 3600s;
    }
}
NGINX

        ln -sf /etc/nginx/sites-available/luxvpn /etc/nginx/sites-enabled/
        rm -f /etc/nginx/sites-enabled/default
        
        systemctl restart nginx
        log_success "SSL Configured with Nginx!"
    else
        log_info "Skipping SSL setup."
    fi

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
    UUID=$(grep "uuid=" /etc/luxvpn/config.txt | cut -d'=' -f2 | tr -d '\r' | tr -d ' ')
    
    log_success "Iran Server Setup Complete!"
    echo "========================================================"
    echo "VLESS Configuration:"
    # Output config
    if [[ "$ENABLE_SSL" =~ ^[Yy]$ ]]; then
        # WSS Config
        printf "vless://%s@%s:443?encryption=none&security=tls&type=ws&host=%s&path=%%2Fws#default\n" "$UUID" "$BRIDGE_DOMAIN" "$BRIDGE_DOMAIN"
    else
        # TCP Config
        printf "vless://%s@%s:%s?encryption=none&security=none&type=tcp&headerType=none#default\n" "$UUID" "$PUBLIC_IP" "$VLESS_PORT"
    fi
    echo "========================================================"
    
    # Cleanup Proxy
    if [ -f /etc/apt/apt.conf.d/99luxvpn-proxy ]; then
        rm /etc/apt/apt.conf.d/99luxvpn-proxy
        log_info "Temporary APT proxy configuration removed."
    fi
}

setup_foreign() {
    log_info "Setting up Foreign (Exit) Server..."

    # Prompts first (Before installation steps)
    echo "========================================================"
    echo "To connect via WSS (Secure), enter the Iran Domain."
    echo "To connect via WS (Insecure/Test), leave Domain empty and enter IP next."
    echo -n "Enter the Iran Server Domain (e.g., bridge.example.com): "
    read IRAN_DOMAIN
    
    echo -n "Enter Iran Server IP (Required if Domain is empty): "
    read IRAN_IP
    echo "========================================================"

    if [ -z "$IRAN_DOMAIN" ] && [ -z "$IRAN_IP" ]; then
        log_error "You must provide either a Domain or an IP."
        exit 1
    fi
     
    # ... (Binary Install) ...


    
    # 1. Install Binary
    if [ -f "$TEMP_DIR/lux-exit" ]; then
         cp "$TEMP_DIR/lux-exit" "$INSTALL_DIR/lux-exit"
    elif [ -f "$TEMP_DIR/exit" ]; then
         cp "$TEMP_DIR/exit" "$INSTALL_DIR/lux-exit"
    elif [ -f "$TEMP_DIR/target/release/exit" ]; then
        cp "$TEMP_DIR/target/release/exit" "$INSTALL_DIR/lux-exit"
    elif [ -f "$TEMP_DIR/target/release/lux-exit" ]; then
         cp "$TEMP_DIR/target/release/lux-exit" "$INSTALL_DIR/lux-exit"
    else
        log_error "Binary 'exit' or 'lux-exit' not found in $TEMP_DIR"
        exit 1
    fi
    chmod +x "$INSTALL_DIR/lux-exit"
    
    # 2. Config
    mkdir -p /etc/luxvpn
    if [ -f "$TEMP_DIR/exit/config.txt" ]; then
         cp "$TEMP_DIR/exit/config.txt" /etc/luxvpn/config.txt
    elif [ -f "$TEMP_DIR/config_exit.txt" ]; then
         cp "$TEMP_DIR/config_exit.txt" /etc/luxvpn/config.txt
    else
         # Fallback try to copy from bridge location if structure is odd, but ideally fail
          log_error "Config file for exit not found."
          exit 1
    fi
    
    # Update config to use WSS or WS
    if [ -n "$IRAN_DOMAIN" ]; then
        log_info "Configuring connection to Iran: wss://$IRAN_DOMAIN/ws"
        if [ -n "$IRAN_IP" ]; then
             log_warning "Note: IP $IRAN_IP was provided but Domain is prioritized for WSS."
             # Ideally add to /etc/hosts, skipping for now
        fi
        sed -i "s|bridge_url=.*|bridge_url=wss://$IRAN_DOMAIN/ws|g" /etc/luxvpn/config.txt
    else
        log_info "Configuring connection to Iran: ws://$IRAN_IP:8081"
        sed -i "s|bridge_url=.*|bridge_url=ws://$IRAN_IP:8081|g" /etc/luxvpn/config.txt
    fi
    
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
        # Proxy Prompt for Iran
        echo "========================================================"
        echo "Internet in Iran might be slow or restricted."
        echo "Do you want to use a temporary HTTP Proxy for installation? [y/N]"
        read -r USE_PROXY
        if [[ "$USE_PROXY" =~ ^[Yy]$ ]]; then
            echo -n "Enter Proxy URL (e.g., http://127.0.0.1:10809): "
            read PROXY_URL
            if [ -n "$PROXY_URL" ]; then
                log_info "Using Proxy: $PROXY_URL"
                export http_proxy="$PROXY_URL"
                export https_proxy="$PROXY_URL"
                export ALL_PROXY="$PROXY_URL"
                
                # Configure apt to use proxy
                echo "Acquire::http::Proxy \"$PROXY_URL\";" > /etc/apt/apt.conf.d/99luxvpn-proxy
                echo "Acquire::https::Proxy \"$PROXY_URL\";" >> /etc/apt/apt.conf.d/99luxvpn-proxy
                log_info "APT proxy configured."
                
                # Configure git just in case Cargo uses it
                git config --global http.proxy "$PROXY_URL"
            fi
        fi
        
        install_deps
        download_files
        setup_iran
        ;;
    2)
        install_deps
        download_files
        setup_foreign
        ;;
    *)
        log_error "Invalid selection. Exiting."
        exit 1
        ;;
esac
