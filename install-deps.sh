#!/bin/sh
set -eu

# Linchine dependency installer
# Works when run as:
#   ./install-deps.sh
#   sudo ./install-deps.sh
#   su -c ./install-deps.sh

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
else
    echo "Error: this script needs root permissions."
    echo "Run it as root, or install sudo and run it as a user with sudo access."
    exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
    echo "Error: apt was not found."
    echo "This installer is made for Debian/Ubuntu-based systems."
    exit 1
fi

echo "[Linchine] Updating package lists..."
$SUDO apt update

echo "[Linchine] Installing dependencies..."
$SUDO apt install -y \
    sudo \
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
    xterm \
    openbox \
    dbus-x11 \
    whiptail

echo "[Linchine] Dependency installation complete."
