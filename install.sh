#!/usr/bin/env bash
set -e

# ------------------------------
# Player2 Installer (Bash Version)
# ------------------------------

# Config
INSTALL_DIR="$HOME/player2"
VERSIONS_JSON_URL="https://nachlorid.github.io/p2ip/versions.json"
UNINSTALL_SCRIPT="/usr/local/bin/p2uninstall"
MONITOR_DIR="/etc/p2monitor"
MONITOR_SERVICE="/etc/systemd/system/p2monitor.service"

# Ensure sudo
if [[ $EUID -ne 0 ]]; then
    echo "Please run this installer with sudo"
    exit 1
fi

# Ensure dependencies
function install_dependencies() {
    echo "Checking dependencies..."
    DEPS=(curl jq)
    for dep in "${DEPS[@]}"; do
        if ! command -v $dep >/dev/null 2>&1; then
            echo "Installing $dep..."
            if command -v apt >/dev/null 2>&1; then
                apt update && apt install -y $dep
            elif command -v pacman >/dev/null 2>&1; then
                pacman -Syu --noconfirm $dep
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y $dep
            elif command -v zypper >/dev/null 2>&1; then
                zypper install -y $dep
            else
                echo "No supported package manager found for $dep"
                exit 1
            fi
        fi
    done
}

# ------------------------------
# Version Selection
# ------------------------------
function select_version() {
    TEMP_JSON=$(mktemp)
    curl -fsSL "$VERSIONS_JSON_URL" -o "$TEMP_JSON" || { echo "Failed to download versions.json"; exit 1; }

    mapfile -t VERSION_NAMES < <(jq -r '.versions[].name' "$TEMP_JSON")
    mapfile -t VERSION_URLS < <(jq -r '.versions[].url' "$TEMP_JSON")

    MENU_ITEMS=()
    for i in "${!VERSION_NAMES[@]}"; do
        MENU_ITEMS+=("$i" "${VERSION_NAMES[$i]}")
    done

    CHOICE=$(whiptail --title "Select Player2 Version" \
        --menu "Choose a version to install:" 15 60 4 \
        "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3) || exit 1

    SELECTED_NAME="${VERSION_NAMES[$CHOICE]}"
    SELECTED_URL="${VERSION_URLS[$CHOICE]}"
    echo "Selected version: $SELECTED_NAME"
}

# ------------------------------
# Installation Options
# ------------------------------
function select_options() {
    OPTIONS=("Install Player2" ON
             "Apply WebKit Patches" ON
             "Install P2Monitor Service" OFF)

    CHOICES=$(whiptail --title "Installation Options" \
        --checklist "Select components to install:" 15 60 5 \
        "${OPTIONS[@]}" 3>&1 1>&2 2>&3)

    # strip quotes (whiptail surrounds options with ")
    CHOICES=$(echo $CHOICES | sed 's/"//g')

    INSTALL_APP=false
    INSTALL_PATCHES=false
    INSTALL_MONITOR=false

    for choice in $CHOICES; do
        case $choice in
            Install\ Player2) INSTALL_APP=true ;;
            Apply\ WebKit\ Patches) INSTALL_PATCHES=true ;;
            Install\ P2Monitor\ Service) INSTALL_MONITOR=true ;;
        esac
    done
}

# ------------------------------
# Install Player2 AppImage
# ------------------------------
function install_player2() {
    echo "Installing Player2..."
    mkdir -p "$INSTALL_DIR"
    curl -L "$SELECTED_URL" -o "$INSTALL_DIR/Player2.AppImage"
    chmod +x "$INSTALL_DIR/Player2.AppImage"
    echo "Player2 installed to $INSTALL_DIR"
}

# ------------------------------
# Apply WebKit patches
# ------------------------------
function apply_patches() {
    echo "Applying WebKit patches..."
    ENV_LINE="export WEBKIT_DISABLE_DMABUF_RENDERER=1"
    SHELL_FILES=("$HOME/.bashrc" "$HOME/.zshrc")

    for FILE in "${SHELL_FILES[@]}"; do
        [[ -f $FILE ]] || touch "$FILE"
        if ! grep -Fxq "$ENV_LINE" "$FILE"; then
            echo -e "\n# Added by Player2 Installer\n$ENV_LINE" >> "$FILE"
            echo "Patch applied to $FILE"
        else
            echo "Patch already exists in $FILE"
        fi
    done
}

# ------------------------------
# Setup P2Monitor
# ------------------------------
function setup_monitor() {
    echo "Setting up P2Monitor service..."
    mkdir -p "$MONITOR_DIR"

    cat > "$MONITOR_DIR/monitor.py" <<'EOF'
#!/usr/bin/env python3
import os, time
from pathlib import Path

WARNING_TEXT = "--- Player2 Log --\nThis is ok. -- OptimiDev\n!!! WARNING !!!\nDO NOT REPORT THIS TO PLAYER2, REPORT TO P2Installer\n"

def monitor_logs():
    log_dir = Path.home() / ".config/game.player2.client.playground/logs"
    while True:
        if log_dir.exists():
            for log_file in log_dir.glob("*"):
                if log_file.is_file():
                    try:
                        with open(log_file, "r+") as f:
                            content = f.read()
                            if WARNING_TEXT not in content:
                                f.seek(0, 0)
                                f.write(WARNING_TEXT + "\n" + content)
                    except:
                        pass
        time.sleep(5)

if __name__ == "__main__":
    monitor_logs()
EOF

    chmod +x "$MONITOR_DIR/monitor.py"

    cat > "$MONITOR_SERVICE" <<EOF
[Unit]
Description=Player2 Log Monitor
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $MONITOR_DIR/monitor.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now p2monitor
    echo "P2Monitor installed and started"
}

# ------------------------------
# Create desktop entry
# ------------------------------
function create_desktop_entry() {
    DESKTOP_DIR="$HOME/.local/share/applications"
    mkdir -p "$DESKTOP_DIR"
    ICON_PATH="$INSTALL_DIR/player2-icon.png"

    [[ ! -f $ICON_PATH ]] && curl -L -o "$ICON_PATH" "https://cdn.optimihost.com/player2-icon.png"

    cat > "$DESKTOP_DIR/player2.desktop" <<EOF
[Desktop Entry]
Name=Player2
Comment=Player2 Linux Client
Exec=$INSTALL_DIR/Player2.AppImage
Icon=$ICON_PATH
Terminal=false
Type=Application
Categories=Game;Utility;
EOF

    chmod +x "$DESKTOP_DIR/player2.desktop"
    echo "Desktop entry created"
}

# ------------------------------
# Create uninstaller
# ------------------------------
function create_uninstaller() {
    cat > "$UNINSTALL_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -e

INSTALL_DIR="$HOME/player2"
MONITOR_DIR="/etc/p2monitor"
MONITOR_SERVICE="/etc/systemd/system/p2monitor.service"

echo "Uninstalling Player2..."

[[ -d $INSTALL_DIR ]] && rm -rf "$INSTALL_DIR" && echo "Removed Player2 directory"

SHELL_FILES=("$HOME/.bashrc" "$HOME/.zshrc")
for FILE in "${SHELL_FILES[@]}"; do
    [[ -f $FILE ]] && sed -i '/WEBKIT_DISABLE_DMABUF_RENDERER/d' "$FILE"
done
echo "Removed WebKit patches"

if systemctl is-active --quiet p2monitor; then
    systemctl stop p2monitor
    systemctl disable p2monitor
    [[ -f $MONITOR_SERVICE ]] && rm -f "$MONITOR_SERVICE"
    [[ -d $MONITOR_DIR ]] && rm -rf "$MONITOR_DIR"
    systemctl daemon-reload
    echo "Removed P2Monitor"
fi

echo "Uninstallation complete"
EOF

    chmod +x "$UNINSTALL_SCRIPT"
    echo "Created uninstaller at $UNINSTALL_SCRIPT"
}

# ------------------------------
# Main Execution
# ------------------------------
install_dependencies
select_version
select_options

$INSTALL_APP && install_player2
$INSTALL_PATCHES && apply_patches
$INSTALL_MONITOR && setup_monitor
$INSTALL_APP && create_desktop_entry
create_uninstaller

echo "Installation completed successfully!"
