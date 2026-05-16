#!/bin/bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

LINCHINE_SCRIPT_VERSION="2026.05.16-fix-xorg-boot"

LINCHINE_USER="linchine"
LINCHINE_HOME="/home/${LINCHINE_USER}"
LINCHINE_DIR="/opt/linchine"
LINCHINE_CONFIG_DIR="${LINCHINE_DIR}/config"
LINCHINE_CONFIG="${LINCHINE_CONFIG_DIR}/linchine.conf"
OSX_DIR="${LINCHINE_DIR}/OSX-KVM-updated"
OSX_REPO="${OSX_REPO:-https://github.com/renatus777rr/OSX-KVM-updated.git}"
LOG_FILE="/var/log/linchine-install.log"
SELF_UPDATE_URL_MAIN="${LINCHINE_SELF_UPDATE_URL:-https://raw.githubusercontent.com/ExoCore-Kernel/Linchine/main/linchine.sh}"
SELF_UPDATE_URL_MASTER="${LINCHINE_SELF_UPDATE_URL_MASTER:-https://raw.githubusercontent.com/ExoCore-Kernel/Linchine/master/linchine.sh}"

log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
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

fetch_url() {
    local url="$1"
    local out="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$out"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$out" "$url"
    else
        return 1
    fi
}

run_self_update() {
    # Best-effort self update. It never blocks install if the network/repo is unavailable.
    # Disable with: LINCHINE_SKIP_UPDATE=1 sudo ./linchine.sh --install
    if [ "${LINCHINE_SKIP_UPDATE:-0}" = "1" ]; then
        log "Self-update skipped by LINCHINE_SKIP_UPDATE=1."
        return 0
    fi

    if [ "${LINCHINE_ALREADY_UPDATED:-0}" = "1" ]; then
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        log "Self-update skipped because curl/wget is not installed yet."
        return 0
    fi

    local self
    local target
    local tmp

    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    target="/usr/local/sbin/linchine.sh"
    tmp="$(mktemp /tmp/linchine-update.XXXXXX)"

    if fetch_url "$SELF_UPDATE_URL_MAIN" "$tmp" || fetch_url "$SELF_UPDATE_URL_MASTER" "$tmp"; then
        if ! grep -q "LINCHINE_USER=" "$tmp" || ! bash -n "$tmp" >/dev/null 2>&1; then
            log "Self-update downloaded something invalid; ignoring it."
            rm -f "$tmp"
            return 0
        fi

        local downloaded_version
        downloaded_version="$(grep -E '^LINCHINE_SCRIPT_VERSION=' "$tmp" | head -n1 | cut -d= -f2- | tr -d '"' || true)"

        if [ -z "$downloaded_version" ]; then
            log "Self-update skipped because the online script has no LINCHINE_SCRIPT_VERSION marker."
            rm -f "$tmp"
            return 0
        fi

        if [ "$downloaded_version" = "${LINCHINE_SCRIPT_VERSION:-unknown}" ]; then
            log "Linchine is already at version ${LINCHINE_SCRIPT_VERSION}."
            rm -f "$tmp"
            return 0
        fi

        if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
            log "Linchine is already up to date."
            rm -f "$tmp"
            return 0
        fi

        log "Update found: ${LINCHINE_SCRIPT_VERSION:-unknown} -> ${downloaded_version}. Installing to ${target}..."
        install -m 755 "$tmp" "$target"
        rm -f "$tmp"

        if [ "$self" = "$target" ]; then
            log "Restarting into updated Linchine script..."
            LINCHINE_ALREADY_UPDATED=1 exec "$target" "$@"
        fi

        log "Updated installed script. Continuing this run."
    else
        log "Self-update check failed or no network is available. Continuing."
        rm -f "$tmp"
    fi
}

install_self() {
    local target="/usr/local/sbin/linchine.sh"
    local source

    mkdir -p /usr/local/sbin
    source="$(readlink -f "$0" 2>/dev/null || echo "$0")"

    if [ "$source" != "$target" ]; then
        log "Installing Linchine script to ${target}..."
        install -m 755 "$source" "$target"
    else
        chmod 755 "$target"
    fi
}

install_runtime_dependencies() {
    # Best-effort dependency repair for minimal Debian installs.
    # This fixes common issues such as missing useradd, missing Xorg drivers,
    # missing OpenBox/xterm, and QEMU GTK failing because the X stack is absent.
    if ! command -v apt-get >/dev/null 2>&1; then
        log "apt-get not found; skipping automatic dependency repair."
        return 0
    fi

    log "Installing/checking Linchine runtime dependencies..."

    export DEBIAN_FRONTEND=noninteractive
    apt-get update || true
    apt-get install -y \
        sudo \
        passwd \
        login \
        adduser \
        git \
        qemu-system-x86 \
        qemu-system-gui \
        qemu-utils \
        ovmf \
        uml-utilities \
        python3 \
        python3-pip \
        python3-venv \
        wget \
        curl \
        unzip \
        p7zip-full \
        make \
        dmg2img \
        genisoimage \
        net-tools \
        screen \
        vim \
        pciutils \
        xinit \
        xserver-xorg \
        xserver-xorg-core \
        xserver-xorg-video-all \
        xserver-xorg-video-intel \
        xserver-xorg-input-all \
        x11-xserver-utils \
        mesa-utils \
        openbox \
        dbus-x11 \
        xterm \
        whiptail || log "Some packages failed to install. Continuing so you can inspect/fix manually."
}

configure_xorg_safe_defaults() {
    log "Configuring safer Xorg defaults..."

    mkdir -p /etc/X11/xorg.conf.d

    # A stale /etc/X11/xorg.conf can force the old vesa driver, which causes:
    #   vesa: Ignoring device with a bound kernel driver
    #   no screens found
    if [ -f /etc/X11/xorg.conf ] && ! grep -q "Linchine" /etc/X11/xorg.conf 2>/dev/null; then
        mv /etc/X11/xorg.conf "/etc/X11/xorg.conf.linchine-backup.$(date +%s)" || true
    fi

    cat > /etc/X11/xorg.conf.d/20-linchine-modesetting.conf <<'EOF'
Section "Device"
    Identifier "Linchine Graphics"
    Driver "modesetting"
    Option "AccelMethod" "glamor"
EndSection
EOF

    # Keep input simple on tiny/minimal installs.
    cat > /etc/X11/xorg.conf.d/40-linchine-input.conf <<'EOF'
Section "InputClass"
    Identifier "Linchine libinput fallback"
    MatchIsPointer "on"
    Driver "libinput"
EndSection
EOF

    if getent group video >/dev/null 2>&1; then
        usermod -aG video "$LINCHINE_USER" || true
    fi

    if getent group render >/dev/null 2>&1; then
        usermod -aG render "$LINCHINE_USER" || true
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

    mkdir -p /var/log/linchine
    chown -R "$LINCHINE_USER:$LINCHINE_USER" /var/log/linchine || true
    chmod 0755 /var/log/linchine || true
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
    log "Configuring automatic Linchine boot on tty1..."

    cat > "${LINCHINE_HOME}/.bash_profile" <<'EOF'
# Auto-start Linchine only on tty1. Disable temporarily with:
#   export LINCHINE_NO_AUTOSTART=1
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ] && [ "${LINCHINE_NO_AUTOSTART:-0}" != "1" ]; then
    exec /usr/local/bin/linchine-boot
fi
EOF

    cat > "${LINCHINE_HOME}/.xinitrc" <<'EOF'
exec /usr/local/bin/linchine-session
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

write_gpu_helper() {
    log "Writing GPU helper..."

    cat > /usr/local/bin/linchine-gpu-helper <<'EOF'
#!/bin/bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

is_supported_high_sierra_nvidia_name() {
    local name
    name="$(echo "$1" | tr '[:upper:]' '[:lower:]')"

    # Explicitly reject NVIDIA generations that do not have useful macOS High Sierra acceleration.
    case "$name" in
        *"rtx"*|*"gtx 16"*|*"gtx1650"*|*"gtx 1650"*|*"gtx1660"*|*"gtx 1660"*|*"titan rtx"*|*"titan v"*|*"quadro rtx"*|*"tesla v"*|*"tesla t4"*|*"a100"*|*"l4"*|*"l40"*|*"rtx a"*)
            return 1
            ;;
    esac

    # Broad auto-allow list for High Sierra-era NVIDIA cards:
    # Kepler, Maxwell, Pascal, and related Quadro/Tesla K/M/P naming.
    case "$name" in
        *"gtx 6"*|*"gt 6"*|*"gtx 7"*|*"gt 7"*|*"gtx 8"*|*"gt 8"*|*"gtx 9"*|*"gtx 10"*|*"quadro k"*|*"quadro m"*|*"quadro p"*|*"tesla k"*|*"tesla m"*|*"tesla p"*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

device_id_for_bdf() {
    local bdf="$1"
    lspci -Dnn -s "$bdf" | grep -oE '\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\]' | tail -n1 | tr -d '[]'
}

audio_for_gpu_bdf() {
    local gpu_bdf="$1"
    local base
    base="${gpu_bdf%.*}"

    if lspci -Dnn -s "${base}.1" 2>/dev/null | grep -Eiq 'audio|hdmi'; then
        echo "${base}.1"
    fi
}

first_supported_nvidia() {
    local line
    local bdf
    local audio
    local gpu_id
    local audio_id

    while IFS= read -r line; do
        [ -n "$line" ] || continue

        if is_supported_high_sierra_nvidia_name "$line"; then
            bdf="$(echo "$line" | awk '{print $1}')"
            audio="$(audio_for_gpu_bdf "$bdf" || true)"
            gpu_id="$(device_id_for_bdf "$bdf" || true)"
            audio_id=""
            if [ -n "$audio" ]; then
                audio_id="$(device_id_for_bdf "$audio" || true)"
            fi

            echo "SUPPORTED=yes"
            echo "GPU_BDF=$bdf"
            echo "GPU_ID=$gpu_id"
            echo "AUDIO_BDF=$audio"
            echo "AUDIO_ID=$audio_id"
            echo "GPU_NAME=$(echo "$line" | cut -d' ' -f2-)"
            exit 0
        fi
    done < <(lspci -Dnn | grep -Ei 'nvidia.*(vga|3d|display)' || true)

    echo "SUPPORTED=no"
    exit 1
}

list_nvidia() {
    lspci -Dnn | grep -Ei 'nvidia.*(vga|3d|display|audio)' || true
}

configure_vfio() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This command must be run as root." >&2
        exit 1
    fi

    local ids="$1"
    local cpu_vendor
    local iommu_arg

    if [ -z "$ids" ]; then
        echo "No VFIO IDs were provided." >&2
        exit 1
    fi

    cpu_vendor="$(lscpu 2>/dev/null | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/, "", $2); print $2}' || true)"
    case "$cpu_vendor" in
        AuthenticAMD)
            iommu_arg="amd_iommu=on"
            ;;
        *)
            iommu_arg="intel_iommu=on"
            ;;
    esac

    modprobe vfio-pci || true

    cat > /etc/modprobe.d/linchine-vfio.conf <<CONF
options vfio-pci ids=${ids} disable_vga=1
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep nvidiafb pre: vfio-pci
softdep drm pre: vfio-pci
CONF

    mkdir -p /etc/default/grub.d
    cat > /etc/default/grub.d/99-linchine-vfio.cfg <<CONF
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT ${iommu_arg} iommu=pt kvm.ignore_msrs=1 vfio-pci.ids=${ids} video=efifb:off"
CONF

    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u || true
    fi

    if command -v update-grub >/dev/null 2>&1; then
        update-grub || true
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        grub-mkconfig -o /boot/grub/grub.cfg || true
    fi

    echo "VFIO configuration written for IDs: ${ids}"
    echo "A reboot is required before passthrough can work."
}

case "${1:-}" in
    --list-nvidia)
        list_nvidia
        ;;
    --first-supported-nvidia)
        first_supported_nvidia
        ;;
    --is-supported-name)
        is_supported_high_sierra_nvidia_name "${2:-}" && echo yes || echo no
        ;;
    --configure-vfio)
        configure_vfio "${2:-}"
        ;;
    *)
        echo "Usage:"
        echo "  linchine-gpu-helper --list-nvidia"
        echo "  linchine-gpu-helper --first-supported-nvidia"
        echo "  linchine-gpu-helper --configure-vfio 10de:xxxx,10de:yyyy"
        exit 1
        ;;
esac
EOF

    chmod +x /usr/local/bin/linchine-gpu-helper
}

write_launcher() {
    log "Writing Linchine launcher..."

    cat > /usr/local/bin/linchine-launcher <<'EOF'
#!/bin/bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# Compatibility wrapper for older Linchine installs.
# The real GUI session is handled by linchine-session now.
exec /usr/local/bin/linchine-session
EOF

    chmod +x /usr/local/bin/linchine-launcher
}

write_session_command() {
    log "Writing Linchine X session command..."

    cat > /usr/local/bin/linchine-session <<'EOF'
#!/bin/bash
set -u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

SESSION_LOG="${XDG_STATE_HOME:-$HOME/.local/state}/linchine/session.log"
mkdir -p "$(dirname "$SESSION_LOG")" 2>/dev/null || true

log() {
    echo "[Linchine Session] $*" | tee -a "$SESSION_LOG"
}

xset -dpms >/dev/null 2>&1 || true
xset s off >/dev/null 2>&1 || true
xset s noblank >/dev/null 2>&1 || true

if command -v openbox-session >/dev/null 2>&1; then
    openbox-session >/tmp/linchine-openbox.log 2>&1 &
    sleep 1
fi

log "Starting Linchine boot inside X session. DISPLAY=${DISPLAY:-none}"

if command -v xterm >/dev/null 2>&1; then
    xterm -title "Linchine Boot" -geometry 120x32+20+20 -e /usr/local/bin/linchine-boot --qemu-only
else
    /usr/local/bin/linchine-boot --qemu-only
fi

log "Linchine boot command exited. Keeping a shell open instead of shutting down."

if command -v xterm >/dev/null 2>&1; then
    exec xterm -fullscreen -e bash
else
    exec bash
fi
EOF

    chmod +x /usr/local/bin/linchine-session
}

write_boot_command() {
    log "Writing linchine-boot command..."

    cat > /usr/local/bin/linchine-boot <<'EOF'
#!/bin/bash
set -u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

LINCHINE_DIR="/opt/linchine"
CONFIG_FILE="${LINCHINE_DIR}/config/linchine.conf"
OSX_DIR="${LINCHINE_DIR}/OSX-KVM-updated"
MODE="${1:-}"

choose_log_file() {
    local preferred="/var/log/linchine/boot.log"
    if mkdir -p /var/log/linchine 2>/dev/null && touch "$preferred" 2>/dev/null; then
        echo "$preferred"
        return 0
    fi

    local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/linchine"
    mkdir -p "$state_dir" 2>/dev/null || true
    if touch "$state_dir/boot.log" 2>/dev/null; then
        echo "$state_dir/boot.log"
        return 0
    fi

    echo "/tmp/linchine-boot-$(id -u).log"
}

BOOT_LOG="$(choose_log_file)"

log() {
    echo "[Linchine Boot] $*" | tee -a "$BOOT_LOG"
}

show_xorg_help() {
    echo
    echo "Xorg failed to start, so QEMU GTK cannot open a window."
    echo
    echo "Most common fixes on Intel laptops:"
    echo "  sudo apt update"
    echo "  sudo apt install -y xserver-xorg xserver-xorg-video-all xserver-xorg-video-intel xserver-xorg-input-all x11-xserver-utils mesa-utils"
    echo "  sudo /usr/local/sbin/linchine.sh --fix-xorg"
    echo
    echo "Last Xorg log lines:"
    echo "------------------------------------------------------------"
    tail -n 80 /var/log/Xorg.0.log 2>/dev/null || true
    echo "------------------------------------------------------------"
}

fail_shell() {
    local status="${1:-1}"
    echo
    echo "Linchine boot failed with exit code ${status}."
    echo
    echo "Log file: ${BOOT_LOG}"
    echo
    echo "Last 120 log lines:"
    echo "------------------------------------------------------------"
    tail -n 120 "$BOOT_LOG" 2>/dev/null || true
    echo "------------------------------------------------------------"
    echo

    if [ -n "${DISPLAY:-}" ] && command -v xterm >/dev/null 2>&1; then
        echo "Opening a shell."
        exec bash
    fi

    echo "Press Enter to open a shell."
    read -r _ 2>/dev/null || true
    exec bash
}

run_setup_if_possible() {
    if [ -n "${DISPLAY:-}" ] && command -v xterm >/dev/null 2>&1; then
        xterm -fullscreen -e /usr/local/bin/linchine-setup
    else
        /usr/local/bin/linchine-setup
    fi
}

config_passthrough_enabled() {
    [ -f "$CONFIG_FILE" ] && grep -Eq '^GPU_PASSTHROUGH="?yes"?' "$CONFIG_FILE"
}

start_x_session() {
    if ! command -v startx >/dev/null 2>&1; then
        echo "startx is missing. Install xinit/xserver-xorg, then try again."
        exit 1
    fi

    log "No graphical DISPLAY found. Starting Xorg for Linchine..."
    log "This fixes the common QEMU error: gtk initialization failed."

    # Use a direct client instead of ~/.xinitrc so old broken files cannot power off the machine.
    startx /usr/local/bin/linchine-session -- :0 -nolisten tcp vt1 >> "$BOOT_LOG" 2>&1
    status="$?"

    if [ "$status" -ne 0 ]; then
        log "startx failed with exit code ${status}."
        show_xorg_help | tee -a "$BOOT_LOG"
        exit "$status"
    fi
}

# Backward compatibility with the older generated launcher.
if [ "$MODE" = "--boot-or-shell" ]; then
    MODE="--qemu-only"
fi

# If this is called manually from the text console, start X first unless passthrough is enabled.
if [ "$MODE" != "--qemu-only" ] && [ -z "${DISPLAY:-}" ]; then
    if config_passthrough_enabled; then
        MODE="--qemu-only"
    else
        start_x_session
        exit $?
    fi
fi

: > "$BOOT_LOG" 2>/dev/null || true
log "Starting Linchine boot."
log "Running as user: $(id -un 2>/dev/null || echo unknown)"
log "DISPLAY: ${DISPLAY:-none}"

if [ ! -f "$CONFIG_FILE" ]; then
    log "Missing config: $CONFIG_FILE"
    log "Launching setup wizard."
    run_setup_if_possible || fail_shell "$?"
fi

if [ ! -d "$OSX_DIR" ]; then
    log "Missing VM folder: $OSX_DIR"
    log "Trying first-boot setup now."
    sudo /usr/local/sbin/linchine.sh --firstboot || fail_shell "$?"
fi

if [ ! -d "$OSX_DIR" ]; then
    log "OSX-KVM folder is still missing."
    fail_shell 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

cd "$OSX_DIR" || fail_shell "$?"

if [ ! -f "BaseSystem.img" ] || [ ! -f "mac_hdd_ng.img" ]; then
    log "BaseSystem.img or mac_hdd_ng.img is missing. Launching setup wizard."
    run_setup_if_possible || fail_shell "$?"
fi

# Reload config in case setup created/changed it.
# shellcheck disable=SC1090
source "$CONFIG_FILE"

log "macOS product: ${MACOS_PRODUCT:-unknown}"
log "RAM_MB: ${RAM_MB:-unknown}"
log "CPU_CORES: ${CPU_CORES:-unknown}"
log "GPU_PASSTHROUGH: ${GPU_PASSTHROUGH:-no}"

if [ "${GPU_PASSTHROUGH:-no}" = "yes" ]; then
    if [ ! -f "boot-passthrough.sh" ]; then
        log "GPU passthrough is enabled, but boot-passthrough.sh is missing."
        fail_shell 1
    fi

    /usr/local/bin/linchine-patch-passthrough || true

    if [ -f "boot-linchine-passthrough.sh" ]; then
        chmod +x boot-linchine-passthrough.sh
        log "Booting QEMU with GPU passthrough using boot-linchine-passthrough.sh."
        bash ./boot-linchine-passthrough.sh >> "$BOOT_LOG" 2>&1 || fail_shell "$?"
    else
        chmod +x boot-passthrough.sh
        log "Booting QEMU with GPU passthrough using boot-passthrough.sh."
        bash ./boot-passthrough.sh >> "$BOOT_LOG" 2>&1 || fail_shell "$?"
    fi
else
    if [ -z "${DISPLAY:-}" ]; then
        log "No DISPLAY is available. QEMU GTK cannot start without Xorg."
        log "Run: linchine-boot"
        fail_shell 1
    fi

    if [ ! -f "OpenCore-Boot.sh" ]; then
        log "OpenCore-Boot.sh is missing."
        fail_shell 1
    fi

    /usr/local/bin/linchine-patch-opencore || true
    chmod +x OpenCore-Boot.sh
    log "Booting QEMU using OpenCore-Boot.sh."
    bash ./OpenCore-Boot.sh >> "$BOOT_LOG" 2>&1 || fail_shell "$?"
fi

log "QEMU exited normally."
EOF

    chmod +x /usr/local/bin/linchine-boot
}

write_patch_opencore() {
    log "Writing OpenCore patch helper..."

    cat > /usr/local/bin/linchine-patch-opencore <<'EOF'
#!/bin/bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

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
    sed -i -E "s/^ALLOCATED_RAM=.*/ALLOCATED_RAM=\"${RAM_MB}\" # MiB/g" "$BOOT_SCRIPT"
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

# Make sure the normal non-passthrough boot opens a visible fullscreen GTK window.
if grep -q -- "-display gtk" "$BOOT_SCRIPT"; then
    sed -i -E 's/-display gtk[^ \\]*/-display gtk,full-screen=on,zoom-to-fit=on,show-menubar=off/g' "$BOOT_SCRIPT"
elif ! grep -q -- "-display " "$BOOT_SCRIPT"; then
    # Insert a display line before vmware-svga in args=(...) based scripts.
    sed -i '/-device vmware-svga/i\  -display gtk,full-screen=on,zoom-to-fit=on,show-menubar=off' "$BOOT_SCRIPT"
fi
EOF

    chmod +x /usr/local/bin/linchine-patch-opencore
}

write_patch_passthrough() {
    log "Writing passthrough patch helper..."

    cat > /usr/local/bin/linchine-patch-passthrough <<'EOF'
#!/bin/bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

LINCHINE_DIR="/opt/linchine"
CONFIG_FILE="${LINCHINE_DIR}/config/linchine.conf"
OSX_DIR="${LINCHINE_DIR}/OSX-KVM-updated"
SOURCE_SCRIPT="${OSX_DIR}/boot-passthrough.sh"
OUT_SCRIPT="${OSX_DIR}/boot-linchine-passthrough.sh"

[ -f "$SOURCE_SCRIPT" ] || exit 0
[ -f "$CONFIG_FILE" ] || exit 0

source "$CONFIG_FILE"

[ "${GPU_PASSTHROUGH:-no}" = "yes" ] || exit 0
[ -n "${GPU_BDF:-}" ] || exit 0

RAM_MB="${RAM_MB:-8192}"
CPU_CORES="${CPU_CORES:-4}"
AUDIO_BDF="${AUDIO_BDF:-}"

cd "$OSX_DIR"

cp "$SOURCE_SCRIPT" "$OUT_SCRIPT"

if grep -Eq '^ALLOCATED_RAM=' "$OUT_SCRIPT"; then
    sed -i -E "s/^ALLOCATED_RAM=.*/ALLOCATED_RAM=\"${RAM_MB}\" # MiB/g" "$OUT_SCRIPT"
fi

if grep -Eq '^CPU_CORES=' "$OUT_SCRIPT"; then
    sed -i -E "s/^CPU_CORES=.*/CPU_CORES=\"${CPU_CORES}\"/g" "$OUT_SCRIPT"
fi

if grep -Eq '^CPU_THREADS=' "$OUT_SCRIPT"; then
    sed -i -E "s/^CPU_THREADS=.*/CPU_THREADS=\"${CPU_CORES}\"/g" "$OUT_SCRIPT"
fi

if [ -f "OVMF_CODE_4M.fd" ]; then
    sed -i 's/OVMF_CODE.fd/OVMF_CODE_4M.fd/g' "$OUT_SCRIPT"
fi

if [ -f "OVMF_VARS-1920x1080.fd" ]; then
    sed -i 's/OVMF_VARS-1024x768.fd/OVMF_VARS-1920x1080.fd/g' "$OUT_SCRIPT"
fi

# Replace the first passthrough GPU line and optional audio line.
awk -v gpu="$GPU_BDF" -v audio="$AUDIO_BDF" '
BEGIN { gpu_done=0; audio_done=0 }
/-device vfio-pci,host=.*multifunction=on/ && gpu_done==0 {
    print "  -device vfio-pci,host=" gpu ",multifunction=on,x-no-kvm-intx=on"
    gpu_done=1
    next
}
/-device vfio-pci,host=.*01:00\.1/ && audio_done==0 {
    if (audio != "") print "  -device vfio-pci,host=" audio
    audio_done=1
    next
}
{ print }
' "$OUT_SCRIPT" > "${OUT_SCRIPT}.tmp"

mv "${OUT_SCRIPT}.tmp" "$OUT_SCRIPT"
chmod +x "$OUT_SCRIPT"
EOF

    chmod +x /usr/local/bin/linchine-patch-passthrough
}

write_setup_wizard() {
    log "Writing Linchine setup wizard..."

    cat > /usr/local/bin/linchine-setup <<'EOF'
#!/bin/bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

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

detect_supported_nvidia_passthrough() {
    local detection
    local ids
    local gpu_bdf
    local audio_bdf
    local gpu_id
    local audio_id
    local gpu_name

    GPU_PASSTHROUGH="no"
    GPU_BDF=""
    AUDIO_BDF=""
    GPU_ID=""
    AUDIO_ID=""

    [ "$MACOS_PRODUCT" = "1" ] || return 0
    command -v linchine-gpu-helper >/dev/null 2>&1 || return 0

    detection="$(linchine-gpu-helper --first-supported-nvidia 2>/dev/null || true)"
    echo "$detection" | grep -q '^SUPPORTED=yes' || return 0

    gpu_bdf="$(echo "$detection" | awk -F= '/^GPU_BDF=/ {print $2; exit}')"
    audio_bdf="$(echo "$detection" | awk -F= '/^AUDIO_BDF=/ {print $2; exit}')"
    gpu_id="$(echo "$detection" | awk -F= '/^GPU_ID=/ {print $2; exit}')"
    audio_id="$(echo "$detection" | awk -F= '/^AUDIO_ID=/ {print $2; exit}')"
    gpu_name="$(echo "$detection" | awk -F= '/^GPU_NAME=/ {$1=""; sub(/^=/,""); print; exit}')"

    if [ -z "$gpu_bdf" ] || [ -z "$gpu_id" ]; then
        return 0
    fi

    if [ -n "$audio_id" ]; then
        ids="${gpu_id},${audio_id}"
    else
        ids="${gpu_id}"
    fi

    if whiptail --title "NVIDIA High Sierra Passthrough" --yesno "Linchine detected a likely High Sierra-compatible NVIDIA GPU:\n\n${gpu_name}\n\nGPU: ${gpu_bdf} (${gpu_id})\nAudio: ${audio_bdf:-none} ${audio_id:-}\n\nEnable GPU passthrough mode?\n\nImportant:\n- Use this after installing macOS normally first.\n- Your monitor should be connected to this NVIDIA card.\n- A reboot is required after VFIO setup.\n- High Sierra may still need NVIDIA Web Drivers inside macOS." 22 78; then
        GPU_PASSTHROUGH="yes"
        GPU_BDF="$gpu_bdf"
        AUDIO_BDF="$audio_bdf"
        GPU_ID="$gpu_id"
        AUDIO_ID="$audio_id"

        sudo linchine-gpu-helper --configure-vfio "$ids" || true

        whiptail --title "Reboot Required" --msgbox "GPU passthrough mode has been enabled in Linchine.\n\nVFIO/IOMMU settings were written for:\n${ids}\n\nReboot before trying passthrough.\n\nAfter reboot, use:\nlinchine-boot\n\nIf passthrough fails, edit:\n${CONFIG_FILE}\n\nand set:\nGPU_PASSTHROUGH=\"no\"" 17 76
    fi
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
    "1" "High Sierra (10.13) - best for supported NVIDIA passthrough" \
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

GPU_PASSTHROUGH="no"
GPU_BDF=""
AUDIO_BDF=""
GPU_ID=""
AUDIO_ID=""
detect_supported_nvidia_passthrough

cat > "$CONFIG_FILE" <<CONF
MACOS_PRODUCT="$MACOS_PRODUCT"
DISK_SIZE="$DISK_SIZE"
RAM_MB="$RAM_MB"
CPU_CORES="$CPU_CORES"
GPU_PASSTHROUGH="$GPU_PASSTHROUGH"
GPU_BDF="$GPU_BDF"
AUDIO_BDF="$AUDIO_BDF"
GPU_ID="$GPU_ID"
AUDIO_ID="$AUDIO_ID"
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

        case "$MACOS_PRODUCT" in
            1) MACOS_SHORTNAME="high-sierra" ;;
            2) MACOS_SHORTNAME="mojave" ;;
            3) MACOS_SHORTNAME="catalina" ;;
            4) MACOS_SHORTNAME="big-sur" ;;
            5) MACOS_SHORTNAME="monterey" ;;
            6) MACOS_SHORTNAME="ventura" ;;
            7) MACOS_SHORTNAME="sonoma" ;;
            8) MACOS_SHORTNAME="sequoia" ;;
            9) MACOS_SHORTNAME="tahoe" ;;
            *) MACOS_SHORTNAME="" ;;
        esac

        rm -f BaseSystem.img BaseSystem.dmg RecoveryImage.dmg InstallESD.dmg *.chunklist || true
        rm -rf com.apple.recovery.boot || true

        if [ -n "$MACOS_SHORTNAME" ] && python3 ./fetch-macOS-v2.py --help 2>&1 | grep -q -- "--shortname"; then
            python3 ./fetch-macOS-v2.py --shortname "$MACOS_SHORTNAME"
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
/usr/local/bin/linchine-patch-passthrough || true

whiptail --title "Linchine Ready" --msgbox "Setup complete.\n\nTo boot manually, run:\nlinchine-boot\n\nLinchine will now boot OpenCore/macOS." 13 70
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
        if [ -d "${OSX_DIR}/.git" ]; then
            log "Updating OSX-KVM-updated..."
            sudo -u "$LINCHINE_USER" git -C "$OSX_DIR" pull --ff-only || true
            sudo -u "$LINCHINE_USER" git -C "$OSX_DIR" submodule update --init --recursive || true
        fi
    fi

    chown -R "$LINCHINE_USER:$LINCHINE_USER" "$LINCHINE_DIR"

    if [ -f "${OSX_DIR}/OpenCore-Boot.sh" ]; then
        chmod +x "${OSX_DIR}/OpenCore-Boot.sh"
    fi

    if [ -f "${OSX_DIR}/boot-passthrough.sh" ]; then
        chmod +x "${OSX_DIR}/boot-passthrough.sh"
    fi
}

install_mode() {
    require_root

    log "Starting Linchine install mode..."

    run_self_update "$@"
    install_self
    install_runtime_dependencies
    check_required_admin_commands
    ensure_user
    configure_xorg_safe_defaults
    configure_autologin
    configure_startx

    mkdir -p "$LINCHINE_CONFIG_DIR"
    chown -R "$LINCHINE_USER:$LINCHINE_USER" "$LINCHINE_DIR"

    write_gpu_helper
    write_launcher
    write_session_command
    write_boot_command
    write_patch_opencore
    write_patch_passthrough
    write_setup_wizard
    write_firstboot_service

    log "Linchine install mode complete."
    log "After setup, users can boot manually with: linchine-boot"
}

firstboot_mode() {
    require_root

    log "Starting Linchine first-boot mode..."

    run_self_update "$@"
    check_required_admin_commands
    configure_kvm
    firstboot_clone_osx_kvm

    systemctl disable linchine-firstboot.service || true

    log "Linchine first-boot mode complete."
}

case "${1:-}" in
    --install)
        install_mode "$@"
        ;;
    --firstboot)
        firstboot_mode "$@"
        ;;
    --fix-xorg)
        require_root
        install_runtime_dependencies
        if ! id "$LINCHINE_USER" >/dev/null 2>&1; then
            useradd -m -s /bin/bash "$LINCHINE_USER"
        fi
        configure_xorg_safe_defaults
        ;;
    --boot)
        exec /usr/local/bin/linchine-boot
        ;;
    --no-update-install)
        LINCHINE_SKIP_UPDATE=1 install_mode "$@"
        ;;
    --no-update-firstboot)
        LINCHINE_SKIP_UPDATE=1 firstboot_mode "$@"
        ;;
    *)
        echo "Usage: $0 --install | --firstboot | --fix-xorg | --boot"
        echo
        echo "Environment options:"
        echo "  LINCHINE_SKIP_UPDATE=1    Disable automatic self-update"
        echo "  LINCHINE_SELF_UPDATE_URL=  Override update URL"
        exit 1
        ;;
esac
