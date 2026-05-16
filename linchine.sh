#!/bin/bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

LINCHINE_USER="linchine"
LINCHINE_HOME="/home/${LINCHINE_USER}"
LINCHINE_DIR="/opt/linchine"
LINCHINE_CONFIG_DIR="${LINCHINE_DIR}/config"
LINCHINE_CONFIG="${LINCHINE_CONFIG_DIR}/linchine.conf"
OSX_DIR="${LINCHINE_DIR}/OSX-KVM-updated"
OSX_REPO="${OSX_REPO:-https://github.com/renatus777rr/OSX-KVM-updated.git}"
LOG_FILE="/var/log/linchine-install.log"

log() {
    echo "[Linchine] $*" | tee -a "$LOG_FILE"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script must be run as root."
        exit 1
    fi
}

check_required_admin_commands() {
    local missing=""
    local cmd

    for cmd in useradd usermod passwd getent install systemctl agetty; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="${missing} ${cmd}"
        fi
    done

    if [ -n "$missing" ]; then
        echo "Linchine is missing required admin commands:${missing}"
        echo
        echo "On Debian, install or reinstall the required base packages with:"
        echo "  apt update"
        echo "  apt install --reinstall -y passwd login coreutils systemd"
        echo
        echo "Current PATH is:"
        echo "  $PATH"
        exit 1
    fi
}


install_self() {
    local target="/usr/local/sbin/linchine.sh"
    local source

    mkdir -p /usr/local/sbin

    source="$(readlink -f "$0")"

    if [ "$source" != "$target" ]; then
        log "Installing Linchine script to ${target}..."
        install -m 755 "$source" "$target"
    else
        chmod 755 "$target"
    fi
}

ensure_user() {
    log "Configuring Linchine user..."

    if ! id "$LINCHINE_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$LINCHINE_USER"
    fi

    usermod -aG sudo "$LINCHINE_USER" || true

    if getent group kvm >/dev/null 2>&1; then
        usermod -aG kvm "$LINCHINE_USER" || true
    fi

    if getent group libvirt >/dev/null 2>&1; then
        usermod -aG libvirt "$LINCHINE_USER" || true
    fi

    if getent group input >/dev/null 2>&1; then
        usermod -aG input "$LINCHINE_USER" || true
    fi

    mkdir -p "$LINCHINE_HOME"
    chown "$LINCHINE_USER:$LINCHINE_USER" "$LINCHINE_HOME"

    passwd -l "$LINCHINE_USER" >/dev/null 2>&1 || true

    cat > /etc/sudoers.d/linchine <<EOF
${LINCHINE_USER} ALL=(ALL) NOPASSWD:ALL
EOF

    chmod 0440 /etc/sudoers.d/linchine
}

configure_autologin() {
    log "Configuring tty1 auto-login..."

    mkdir -p /etc/systemd/system/getty@tty1.service.d

    cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${LINCHINE_USER} --noclear %I \$TERM
EOF

    systemctl daemon-reload || true
}

configure_startx() {
    log "Configuring automatic startx..."

    cat > "${LINCHINE_HOME}/.bash_profile" <<'EOF'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    startx
fi
EOF

    cat > "${LINCHINE_HOME}/.xinitrc" <<'EOF'
xset -dpms >/dev/null 2>&1 || true
xset s off >/dev/null 2>&1 || true
xset s noblank >/dev/null 2>&1 || true

openbox-session &
sleep 1

/usr/local/bin/linchine-launcher

sudo poweroff
EOF

    chown "$LINCHINE_USER:$LINCHINE_USER" "${LINCHINE_HOME}/.bash_profile" "${LINCHINE_HOME}/.xinitrc"
    chmod +x "${LINCHINE_HOME}/.xinitrc"
}

write_firstboot_service() {
    log "Writing first-boot service..."

    cat > /etc/systemd/system/linchine-firstboot.service <<'EOF'
[Unit]
Description=Linchine first boot setup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/linchine.sh --firstboot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable linchine-firstboot.service || true
}

write_launcher() {
    log "Writing Linchine launcher..."

    cat > /usr/local/bin/linchine-launcher <<'EOF'
#!/bin/bash
set -euo pipefail

LINCHINE_DIR="/opt/linchine"
CONFIG_FILE="${LINCHINE_DIR}/config/linchine.conf"
OSX_DIR="${LINCHINE_DIR}/OSX-KVM-updated"

show_error() {
    xterm -fullscreen -e "echo 'Linchine error:'; echo \"$1\"; echo; echo 'Press Enter to open a shell.'; read; bash"
}

if [ ! -d "$OSX_DIR" ]; then
    xterm -fullscreen -e "echo 'Running Linchine first-boot setup...'; sudo /usr/local/sbin/linchine.sh --firstboot; echo; echo 'Done. Press Enter to continue.'; read"
fi

if [ ! -f "$CONFIG_FILE" ]; then
    xterm -fullscreen -e /usr/local/bin/linchine-setup
fi

if [ ! -d "$OSX_DIR" ]; then
    show_error "OSX-KVM-updated folder is missing. Check internet connection, then run: sudo /usr/local/sbin/linchine.sh --firstboot"
    exit 1
fi

cd "$OSX_DIR"

if [ ! -f "BaseSystem.img" ]; then
    xterm -fullscreen -e /usr/local/bin/linchine-setup
fi

if [ ! -f "mac_hdd_ng.img" ]; then
    xterm -fullscreen -e /usr/local/bin/linchine-setup
fi

if [ ! -f "OpenCore-Boot.sh" ]; then
    show_error "OpenCore-Boot.sh is missing."
    exit 1
fi

/usr/local/bin/linchine-patch-opencore || true

chmod +x OpenCore-Boot.sh

./OpenCore-Boot.sh
EOF

    chmod +x /usr/local/bin/linchine-launcher
}

write_patch_opencore() {
    log "Writing OpenCore patch helper..."

    cat > /usr/local/bin/linchine-patch-opencore <<'EOF'
#!/bin/bash
set -euo pipefail

LINCHINE_DIR="/opt/linchine"
CONFIG_FILE="${LINCHINE_DIR}/config/linchine.conf"
OSX_DIR="${LINCHINE_DIR}/OSX-KVM-updated"
BOOT_SCRIPT="${OSX_DIR}/OpenCore-Boot.sh"

[ -f "$BOOT_SCRIPT" ] || exit 0
[ -f "$CONFIG_FILE" ] || exit 0

cd "$OSX_DIR"

if [ ! -f "${BOOT_SCRIPT}.linchine.bak" ]; then
    cp "$BOOT_SCRIPT" "${BOOT_SCRIPT}.linchine.bak"
fi

source "$CONFIG_FILE"

RAM_MB="${RAM_MB:-8192}"
CPU_CORES="${CPU_CORES:-4}"

if grep -Eq '^ALLOCATED_RAM=' "$BOOT_SCRIPT"; then
    sed -i -E "s/^ALLOCATED_RAM=.*/ALLOCATED_RAM=\"${RAM_MB}\"/g" "$BOOT_SCRIPT"
fi

if grep -Eq '^CPU_CORES=' "$BOOT_SCRIPT"; then
    sed -i -E "s/^CPU_CORES=.*/CPU_CORES=\"${CPU_CORES}\"/g" "$BOOT_SCRIPT"
fi

if grep -Eq '^CPU_THREADS=' "$BOOT_SCRIPT"; then
    sed -i -E "s/^CPU_THREADS=.*/CPU_THREADS=\"${CPU_CORES}\"/g" "$BOOT_SCRIPT"
fi

if grep -Eq -- "-m [0-9]+" "$BOOT_SCRIPT"; then
    sed -i -E "s/-m [0-9]+/-m ${RAM_MB}/g" "$BOOT_SCRIPT"
fi

if grep -Eq -- "-smp [0-9]+" "$BOOT_SCRIPT"; then
    sed -i -E "s/-smp [0-9]+[^ ]*/-smp ${CPU_CORES},cores=${CPU_CORES}/g" "$BOOT_SCRIPT"
fi

if grep -q -- "-display gtk" "$BOOT_SCRIPT"; then
    sed -i -E 's/-display gtk[^ \\]*/-display gtk,full-screen=on,zoom-to-fit=on,show-menubar=off/g' "$BOOT_SCRIPT"
fi
EOF

    chmod +x /usr/local/bin/linchine-patch-opencore
}

write_setup_wizard() {
    log "Writing Linchine setup wizard..."

    cat > /usr/local/bin/linchine-setup <<'EOF'
#!/bin/bash
set -euo pipefail

LINCHINE_DIR="/opt/linchine"
CONFIG_DIR="${LINCHINE_DIR}/config"
CONFIG_FILE="${CONFIG_DIR}/linchine.conf"
OSX_DIR="${LINCHINE_DIR}/OSX-KVM-updated"

mkdir -p "$CONFIG_DIR"

cancelled() {
    clear
    echo "Linchine setup was cancelled."
    echo "You can run it again with: linchine-setup"
    sleep 3
    exit 1
}

need_whiptail() {
    if ! command -v whiptail >/dev/null 2>&1; then
        echo "whiptail is missing. Install it with: sudo apt install whiptail"
        exit 1
    fi
}

valid_size_or_cancel() {
    local size="$1"

    if [[ ! "$size" =~ ^[0-9]+[GgMm]$ ]]; then
        whiptail --title "Invalid size" --msgbox "Use a size like 80G, 128G, 256G, or 51200M." 10 64
        cancelled
    fi
}

cpu_has_flag() {
    local flag="$1"
    grep -m1 '^flags' /proc/cpuinfo | grep -qw "$flag"
}

check_cpu_requirements() {
    if ! grep -Eq '(vmx|svm)' /proc/cpuinfo; then
        whiptail --title "Virtualization Missing" --msgbox "This CPU or VM does not show Intel VT-x / AMD-V support.\n\nLinchine needs KVM acceleration for usable macOS performance." 12 72
        cancelled
    fi

    if ! cpu_has_flag "sse4_1"; then
        whiptail --title "SSE4.1 Missing" --msgbox "This CPU does not show SSE4.1 support.\n\nSSE4.1 is required for macOS Sierra and newer." 12 72
        cancelled
    fi
}

check_avx2_for_modern_macos() {
    local product="$1"

    case "$product" in
        6|7|8|9)
            if ! cpu_has_flag "avx2"; then
                whiptail --title "AVX2 Missing" --msgbox "This CPU does not show AVX2 support.\n\nAVX2 is required for macOS Ventura and newer.\n\nChoose Monterey or older instead." 14 72
                cancelled
            fi
            ;;
    esac
}

gpu_lines() {
    if command -v lspci >/dev/null 2>&1; then
        lspci | grep -Ei 'vga|3d|display' || true
    else
        true
    fi
}

has_nvidia_gpu() {
    gpu_lines | grep -Eiq 'nvidia'
}

has_non_nvidia_gpu() {
    gpu_lines | grep -Eiv 'nvidia' | grep -Eiq 'intel|amd|ati|radeon'
}

warn_about_nvidia_if_needed() {
    local product="$1"

    case "$product" in
        1|manual)
            return 0
            ;;
    esac

    if ! has_nvidia_gpu; then
        return 0
    fi

    local detected_gpus
    detected_gpus="$(gpu_lines)"

    if has_non_nvidia_gpu; then
        whiptail --title "Modern NVIDIA Warning" --yesno "Linchine detected an NVIDIA GPU.\n\nDetected graphics devices:\n\n${detected_gpus}\n\nModern NVIDIA GPUs generally only have proper macOS GPU acceleration on High Sierra.\n\nFor Mojave or newer, use integrated graphics or another compatible non-NVIDIA GPU for passthrough.\n\nIf you continue with this macOS version, graphics may be slow or unaccelerated.\n\nContinue anyway?" 22 78
        return $?
    else
        whiptail --title "NVIDIA-Only System Warning" --yesno "Linchine detected an NVIDIA GPU, but no obvious integrated/non-NVIDIA graphics device.\n\nDetected graphics devices:\n\n${detected_gpus}\n\nModern NVIDIA GPUs generally only have proper macOS GPU acceleration on High Sierra.\n\nIf you install Mojave or newer on an NVIDIA-only system, macOS graphics may be very slow or unaccelerated.\n\nRecommended choice: High Sierra.\n\nContinue anyway?" 23 78
        return $?
    fi
}

show_qemu_version_warning() {
    local qemu_version
    qemu_version="$(qemu-system-x86_64 --version 2>/dev/null | head -n1 || true)"

    whiptail --title "QEMU Version" --msgbox "Detected:\n${qemu_version}\n\nQEMU 8.2.2 or newer is recommended.\nIf booting fails, try a newer Debian release or newer QEMU package." 13 76
}

need_whiptail

whiptail --title "Linchine Setup" --msgbox "Welcome to Linchine.\n\nThis will prepare a macOS virtual machine using QEMU/KVM and OpenCore.\n\nIt will NOT erase your real system disk. It only creates a qcow2 virtual disk file for macOS." 15 76

if [ ! -d "$OSX_DIR" ]; then
    whiptail --title "Missing OSX-KVM-updated" --msgbox "The OSX-KVM-updated repo is missing.\n\nLinchine will try to run first-boot setup now." 10 70
    sudo /usr/local/sbin/linchine.sh --firstboot
fi

if [ ! -d "$OSX_DIR" ]; then
    whiptail --title "Setup Error" --msgbox "OSX-KVM-updated still could not be found.\nCheck your internet connection and try again." 10 70
    cancelled
fi

check_cpu_requirements
show_qemu_version_warning

while true; do
    MACOS_PRODUCT=$(whiptail --title "macOS Recovery" --menu "Choose macOS version:" 20 78 10 \
    "7" "Sonoma (14)" \
    "8" "Sequoia (15)" \
    "9" "Tahoe (26)" \
    "6" "Ventura (13)" \
    "5" "Monterey (12.6)" \
    "4" "Big Sur (11.7)" \
    "3" "Catalina (10.15)" \
    "2" "Mojave (10.14)" \
    "1" "High Sierra (10.13) - best for modern NVIDIA acceleration" \
    "manual" "I will add BaseSystem.img manually later" \
    3>&1 1>&2 2>&3) || cancelled

    if warn_about_nvidia_if_needed "$MACOS_PRODUCT"; then
        break
    else
        whiptail --title "Choose Again" --msgbox "Choose High Sierra, or choose another macOS version and accept the warning." 10 68
    fi
done

if [ "$MACOS_PRODUCT" != "manual" ]; then
    check_avx2_for_modern_macos "$MACOS_PRODUCT"
fi

DISK_SIZE=$(whiptail --title "macOS Storage" --menu "How much storage should macOS get?" 18 76 6 \
"80G" "Minimum comfortable size" \
"128G" "Good default" \
"256G" "Large" \
"512G" "Very large" \
"custom" "Type a custom size" \
3>&1 1>&2 2>&3) || cancelled

if [ "$DISK_SIZE" = "custom" ]; then
    DISK_SIZE=$(whiptail --title "Custom Storage" --inputbox "Enter disk size, example: 128G" 10 64 "128G" 3>&1 1>&2 2>&3) || cancelled
fi

valid_size_or_cancel "$DISK_SIZE"

RAM_MB=$(whiptail --title "macOS RAM" --menu "How much RAM should macOS get?" 18 76 5 \
"4096" "4 GB" \
"8192" "8 GB recommended" \
"12288" "12 GB" \
"16384" "16 GB" \
"custom" "Type custom MB amount" \
3>&1 1>&2 2>&3) || cancelled

if [ "$RAM_MB" = "custom" ]; then
    RAM_MB=$(whiptail --title "Custom RAM" --inputbox "Enter RAM in MB, example: 8192" 10 64 "8192" 3>&1 1>&2 2>&3) || cancelled
fi

if [[ ! "$RAM_MB" =~ ^[0-9]+$ ]]; then
    whiptail --title "Invalid RAM" --msgbox "RAM must be a number in MB, like 8192." 10 64
    cancelled
fi

CPU_CORES=$(whiptail --title "macOS CPU" --menu "How many CPU cores should macOS get?" 15 76 4 \
"2" "Low-end system" \
"4" "Recommended" \
"6" "Fast" \
"8" "High-end" \
3>&1 1>&2 2>&3) || cancelled

cat > "$CONFIG_FILE" <<CONF
MACOS_PRODUCT="$MACOS_PRODUCT"
DISK_SIZE="$DISK_SIZE"
RAM_MB="$RAM_MB"
CPU_CORES="$CPU_CORES"
CONF

cd "$OSX_DIR"

if [ ! -f "mac_hdd_ng.img" ]; then
    whiptail --title "Creating macOS Disk" --infobox "Creating mac_hdd_ng.img with size ${DISK_SIZE}..." 8 70
    qemu-img create -f qcow2 mac_hdd_ng.img "$DISK_SIZE"
fi

if [ "$MACOS_PRODUCT" != "manual" ]; then
    if [ ! -f "BaseSystem.img" ]; then
        if [ ! -f "fetch-macOS-v2.py" ]; then
            whiptail --title "Missing Downloader" --msgbox "fetch-macOS-v2.py was not found in ${OSX_DIR}." 10 70
            cancelled
        fi

        whiptail --title "Downloading Recovery" --infobox "Downloading macOS Recovery. This can take a while..." 8 72

        chmod +x ./fetch-macOS-v2.py

        if python3 fetch-macOS-v2.py --help 2>&1 | grep -q -- "--action"; then
            sudo python3 fetch-macOS-v2.py --action download --os-type default
        else
            printf "%s\n" "$MACOS_PRODUCT" | python3 ./fetch-macOS-v2.py
        fi

        if [ -f "BaseSystem.dmg" ]; then
            whiptail --title "Converting Recovery" --infobox "Converting BaseSystem.dmg to BaseSystem.img..." 8 72
            dmg2img -i BaseSystem.dmg BaseSystem.img
        elif [ -f "com.apple.recovery.boot/BaseSystem.dmg" ]; then
            whiptail --title "Converting Recovery" --infobox "Converting BaseSystem.dmg to BaseSystem.img..." 8 72
            dmg2img -i com.apple.recovery.boot/BaseSystem.dmg BaseSystem.img
        else
            whiptail --title "Recovery Missing" --msgbox "BaseSystem.dmg was not found after download." 10 70
            cancelled
        fi
    fi
fi

/usr/local/bin/linchine-patch-opencore || true

whiptail --title "Linchine Ready" --msgbox "Setup complete.\n\nLinchine will now boot OpenCore/macOS fullscreen." 11 70
EOF

    chmod +x /usr/local/bin/linchine-setup
}

configure_kvm() {
    log "Configuring KVM ignore_msrs..."

    modprobe kvm || true

    if [ -e /sys/module/kvm/parameters/ignore_msrs ]; then
        echo 1 > /sys/module/kvm/parameters/ignore_msrs || true
    fi

    CPU_VENDOR="$(lscpu 2>/dev/null | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/, "", $2); print $2}' || true)"

    case "$CPU_VENDOR" in
        AuthenticAMD)
            cat > /etc/modprobe.d/kvm.conf <<'EOF'
options kvm ignore_msrs=1
options kvm_amd nested=1
EOF
            ;;
        GenuineIntel)
            cat > /etc/modprobe.d/kvm.conf <<'EOF'
options kvm ignore_msrs=1
options kvm_intel nested=1
EOF
            ;;
        *)
            cat > /etc/modprobe.d/kvm.conf <<'EOF'
options kvm ignore_msrs=1
EOF
            ;;
    esac
}

firstboot_clone_osx_kvm() {
    log "Preparing OSX-KVM-updated..."

    mkdir -p "$LINCHINE_DIR"
    chown -R "$LINCHINE_USER:$LINCHINE_USER" "$LINCHINE_DIR"

    if [ ! -d "$OSX_DIR" ]; then
        log "Cloning OSX-KVM-updated from $OSX_REPO"
        sudo -u "$LINCHINE_USER" git clone --depth 1 --recursive "$OSX_REPO" "$OSX_DIR"
    else
        log "OSX-KVM-updated already exists."
    fi

    chown -R "$LINCHINE_USER:$LINCHINE_USER" "$LINCHINE_DIR"

    if [ -f "${OSX_DIR}/OpenCore-Boot.sh" ]; then
        chmod +x "${OSX_DIR}/OpenCore-Boot.sh"
    fi
}

install_mode() {
    require_root
    check_required_admin_commands

    log "Starting Linchine install mode..."

    install_self
    ensure_user
    configure_autologin
    configure_startx

    mkdir -p "$LINCHINE_CONFIG_DIR"
    chown -R "$LINCHINE_USER:$LINCHINE_USER" "$LINCHINE_DIR"

    write_launcher
    write_patch_opencore
    write_setup_wizard
    write_firstboot_service

    log "Linchine install mode complete."
}

firstboot_mode() {
    require_root
    check_required_admin_commands

    log "Starting Linchine first-boot mode..."

    configure_kvm
    firstboot_clone_osx_kvm

    systemctl disable linchine-firstboot.service || true

    log "Linchine first-boot mode complete."
}

case "${1:-}" in
    --install)
        install_mode
        ;;
    --firstboot)
        firstboot_mode
        ;;
    *)
        echo "Usage: $0 --install | --firstboot"
        exit 1
        ;;
esac
