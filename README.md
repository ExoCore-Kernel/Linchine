# Linchine

**A lightweight Debian-based macOS virtualization setup for computers that are not compatible with native Hackintosh installs.**

Linchine lets you run macOS in QEMU/KVM using a minimal Debian host system.

It is designed for people who want to try macOS on unsupported hardware without setting up a full native Hackintosh installation.

Linchine supports macOS recovery setup for versions from **High Sierra** through newer releases such as **Sonoma, Sequoia, and Tahoe**, depending on your hardware support.

---

## What Linchine Does

Linchine turns a minimal Debian installation into a dedicated macOS virtual machine launcher.

Instead of running macOS inside VMware or VirtualBox on a full Windows or Linux desktop, Linchine uses a stripped-down Debian system with only the components needed to launch QEMU.

This helps reduce wasted background resources and gives more CPU, RAM, and storage performance to the macOS virtual machine.

Linchine automatically:

- Creates a dedicated `linchine` user
- Enables automatic login on `tty1`
- Starts a minimal X11 session automatically
- Launches OpenBox and QEMU fullscreen
- Clones the required `OSX-KVM-updated` files
- Runs a setup wizard using `whiptail`
- Downloads or prepares macOS recovery media
- Creates the macOS virtual disk
- Applies CPU and RAM settings to the OpenCore boot script
- Configures KVM options such as `ignore_msrs`

---

## Why Not Just Use VMware or VirtualBox?

You can run macOS VMs on other systems, but they often run on top of a full desktop OS with lots of extra services, background apps, and graphical overhead.

Linchine avoids that by using a minimal Debian installation with no heavy desktop environment like GNOME, KDE, or Cinnamon.

That means:

- Less bloat
- More resources available for QEMU
- Better performance on lower-end systems
- A cleaner appliance-like boot experience
- Fullscreen macOS VM startup after boot

Linchine is not a native Hackintosh. It runs macOS in a virtual machine.

---

## System Requirements

Minimum requirements:

- x86_64 computer
- Debian 12 or later
- No desktop environment installed
- Intel VT-x or AMD-V enabled in BIOS/UEFI
- SSE4.1-capable CPU
- At least 8 GB RAM recommended
- SSD or NVMe storage recommended
- Internet connection during first setup

For newer macOS versions such as Ventura or later, an AVX2-capable CPU may be required.

---

## GPU Notes

Modern NVIDIA GPUs usually do not have proper macOS graphics acceleration on Mojave or newer.

Linchine will warn you if it detects an NVIDIA GPU.

Recommended choices:

- **High Sierra** for older NVIDIA acceleration support
- **Monterey or older** for systems without AVX2
- **Ventura or newer** only on supported modern CPUs

Graphics performance depends heavily on your hardware and VM configuration.

---

## Installation

### 1. Install Debian

Install **Debian 12 or later** using a minimal installation.

During Debian setup, do **not** install a desktop environment.

Recommended Debian install options:

- Standard system utilities
- SSH server optional
- No GNOME
- No KDE
- No XFCE
- No Cinnamon

---

### 2. Clone Linchine

```bash
git clone https://github.com/ExoCore-Kernel/Linchine
cd Linchine
```

---

### 3. Install Dependencies

```bash
sudo apt update
sudo apt install -y sudo git qemu-system-x86 qemu-system-gui qemu-utils ovmf uml-utilities python3 python3-pip python3-venv wget curl unzip p7zip-full make dmg2img genisoimage net-tools screen vim pciutils xinit xserver-xorg xterm openbox dbus-x11 whiptail
```

---

### 4. Run the Installer

```bash
sudo ./linchine.sh --install
```

The installer configures the Linchine user, auto-login, startup scripts, setup wizard, launcher, and first-boot service.

> **Note**
>
> Your script should copy itself to `/usr/local/sbin/linchine.sh` during install because the first-boot systemd service calls that path.
>
> If your script does not already do this, add this line inside `install_mode()` after `require_root`:
>
> ```bash
> install -m 755 "$0" /usr/local/sbin/linchine.sh
> ```

---

### 5. Reboot

```bash
sudo reboot
```

On the next boot, Linchine will automatically run first-boot setup, clone the required macOS VM files, and launch the setup wizard.

---

## Setup Wizard

The Linchine setup wizard lets you choose:

- macOS version
- Virtual disk size
- RAM allocation
- CPU core count
- Manual recovery image mode

The wizard can create the virtual disk automatically and download macOS recovery files where supported.

Default recommended choices:

- Disk: `128G`
- RAM: `8192`
- CPU cores: `4`

---

## Manual Recovery Mode

If you already have a `BaseSystem.img`, or want to prepare one yourself, choose:

```text
I will add BaseSystem.img manually later
```

Then place the file inside:

```bash
/opt/linchine/OSX-KVM-updated/BaseSystem.img
```

After that, run:

```bash
linchine-setup
```

---

## Useful Commands

Run first-boot setup manually:

```bash
sudo /usr/local/sbin/linchine.sh --firstboot
```

Run the setup wizard again:

```bash
linchine-setup
```

View install logs:

```bash
sudo cat /var/log/linchine-install.log
```

Open the Linchine VM launcher:

```bash
linchine-launcher
```

---

## File Locations

Linchine stores its files in:

```bash
/opt/linchine
```

Configuration file:

```bash
/opt/linchine/config/linchine.conf
```

macOS VM files:

```bash
/opt/linchine/OSX-KVM-updated
```

Main launcher:

```bash
/usr/local/bin/linchine-launcher
```

Setup wizard:

```bash
/usr/local/bin/linchine-setup
```

Main install script:

```bash
/usr/local/sbin/linchine.sh
```

---

## Troubleshooting

### Permission denied when running the script

Run:

```bash
chmod +x linchine.sh
```

Then run the installer again:

```bash
sudo ./linchine.sh --install
```

### First boot fails because `/usr/local/sbin/linchine.sh` is missing

Install the script manually:

```bash
sudo install -m 755 linchine.sh /usr/local/sbin/linchine.sh
```

Then run:

```bash
sudo systemctl restart linchine-firstboot.service
```

### Virtualization missing

Make sure Intel VT-x or AMD-V is enabled in your BIOS/UEFI settings.

### macOS boots slowly

Try giving the VM more RAM or CPU cores.

Recommended:

```text
RAM: 8192 MB or more
CPU: 4 cores or more
Storage: SSD/NVMe
```

### Newer macOS versions fail to boot

Your CPU may not support AVX2.

Try Monterey or older.

### NVIDIA graphics are slow

Modern NVIDIA GPUs usually do not work well with newer macOS versions.

Try High Sierra, or use supported integrated/AMD graphics where possible.

---

## Disclaimer

Linchine does not turn your computer into a real Mac.

It runs macOS inside a virtual machine using QEMU/KVM and OpenCore-related tooling.

This project is intended for educational and experimental use. Make sure you understand and follow Apple's macOS license terms and any laws that apply in your region.

---

## Credits

Linchine uses and prepares files from `OSX-KVM-updated`.

Default upstream repository:

```text
https://github.com/renatus777rr/OSX-KVM-updated.git
```

---

## Repository

```text
https://github.com/ExoCore-Kernel/Linchine
```
