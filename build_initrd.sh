#!/bin/bash
# Verlian Debian Installer — Build Modified Initrd
# Extracts the original d-i initrd, injects tools, patches init, and repacks.
#
# Usage: sudo ./build_initrd.sh
# Must run as root because cpio preserves file ownership.

set -e

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
UNPACKED="$BASEDIR/debian-unpacked"
ORIGINAL_INITRD="$UNPACKED/install.amd/initrd.gz.orig"
OUTPUT_INITRD="$UNPACKED/install.amd/initrd.gz"
WORKDIR="$BASEDIR/initrd_work"
UDEB_TMP="$BASEDIR/udeb_extract_tmp"
POOL="$UNPACKED/pool"

# Colors
PINK='\033[1;35m'
GREEN='\033[1;32m'
NC='\033[0m'

info() { echo -e "${PINK}[Verlian]${NC} $1"; }
ok()   { echo -e "${PINK}[OK]${NC}   $1"; }
fail() { echo -e "${PINK}[FAIL]${NC} $1"; exit 1; }

# ─── Sanity checks ───────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || fail "Must run as root (sudo ./build_initrd.sh)"
[ -f "$ORIGINAL_INITRD" ] || fail "Original initrd not found at $ORIGINAL_INITRD"

# ─── Step 1: Clean workspace ─────────────────────────────────────
info "Cleaning workspace..."
rm -rf "$WORKDIR" "$UDEB_TMP"
mkdir -p "$WORKDIR" "$UDEB_TMP"

# ─── Step 2: Extract original initrd ─────────────────────────────
info "Extracting original initrd..."
cd "$WORKDIR"
gunzip -c "$ORIGINAL_INITRD" | cpio -id --quiet 2>/dev/null
ok "Initrd extracted ($(du -sh "$WORKDIR" | cut -f1))"

# ─── Step 3: Extract and inject udeb packages ────────────────────
inject_udeb() {
    local udeb_path="$1"
    local udeb_name="$(basename "$udeb_path")"
    info "Injecting $udeb_name..."

    local tmp_dir="$UDEB_TMP/$udeb_name"
    mkdir -p "$tmp_dir"
    cd "$tmp_dir"
    ar x "$udeb_path"
    # data.tar may be .xz, .gz, .zst, or plain
    local data_tar=$(ls data.tar.* 2>/dev/null | head -1)
    [ -n "$data_tar" ] || fail "No data.tar found in $udeb_name"
    tar xf "$data_tar" --keep-directory-symlink -C "$WORKDIR"
    cd "$WORKDIR"
    ok "Injected $udeb_name"
}

# Function to easily inject a deb into the initrd
inject_deb() {
    local deb="$1"
    local deb_name=$(basename "$deb")
    
    [ -f "$deb" ] || fail "Deb package not found: $deb"
    info "Injecting $deb_name..."
    
    rm -rf "$UDEB_TMP"
    mkdir -p "$UDEB_TMP"
    cd "$UDEB_TMP"
    
    ar x "$deb"
    
    local data_tar=$(ls data.tar.* 2>/dev/null | head -n 1)
    [ -n "$data_tar" ] || fail "No data.tar found in $deb_name"
    tar xf "$data_tar" --keep-directory-symlink -C "$WORKDIR"
    cd "$WORKDIR"
    ok "Injected $deb_name"
}

# Core tools
inject_udeb "$POOL/main/d/debootstrap/debootstrap-udeb_1.0.141_all.udeb"
inject_udeb "$POOL/main/u/util-linux/fdisk-udeb_2.41-5_amd64.udeb"
inject_udeb "$POOL/main/e/e2fsprogs/e2fsprogs-udeb_1.47.2-3+b7_amd64.udeb"
inject_udeb "$POOL/main/g/gnupg2/gpgv-udeb_2.4.7-21+deb13u1+b1_amd64.udeb"
inject_udeb "$POOL/main/d/debian-archive-keyring/debian-archive-keyring-udeb_2025.1_all.udeb"

# Network modules (virtio_net, e1000, etc)
inject_udeb "$POOL/main/l/linux-signed-amd64/nic-modules-6.12.63+deb13-amd64-di_6.12.63-1_amd64.udeb"

# Inject perl-base (standard deb, not udeb) because debootstrap needs it to parse packages
inject_deb "$POOL/main/p/perl/perl-base_5.40.1-6_amd64.deb"

# Libraries needed by fdisk
inject_udeb "$POOL/main/u/util-linux/libfdisk1-udeb_2.41-5_amd64.udeb"
inject_udeb "$POOL/main/u/util-linux/libsmartcols1-udeb_2.41-5_amd64.udeb"

# Libraries needed by gpgv
inject_udeb "$POOL/main/libg/libgcrypt20/libgcrypt20-udeb_1.11.0-7_amd64.udeb"
inject_udeb "$POOL/main/libg/libgpg-error/libgpg-error0-udeb_1.51-4_amd64.udeb"

# Kernel modules for ext4 filesystem — inject directly to correct path
info "Injecting ext4 kernel modules..."
cd "$WORKDIR"
KVER="6.12.63+deb13-amd64"
MODDIR="usr/lib/modules/$KVER/kernel/fs"
mkdir -p "$MODDIR/ext4" "$MODDIR/jbd2"
# Extract just the module files from the udeb
UDEB="$POOL/main/l/linux-signed-amd64/ext4-modules-6.12.63+deb13-amd64-di_6.12.63-1_amd64.udeb"
tmp_ext4="$UDEB_TMP/ext4mod"
mkdir -p "$tmp_ext4"
cd "$tmp_ext4"
ar x "$UDEB"
tar xf data.tar.* 2>/dev/null
# Copy only the .ko.xz files to the initrd's module tree
cp -f lib/modules/$KVER/kernel/fs/ext4/ext4.ko.xz "$WORKDIR/$MODDIR/ext4/"
cp -f lib/modules/$KVER/kernel/fs/jbd2/jbd2.ko.xz "$WORKDIR/$MODDIR/jbd2/"
cd "$WORKDIR"
# Generate proper module indexes so modprobe works correctly
depmod -b "$WORKDIR/usr" "$KVER" 2>/dev/null || \
    depmod -b "$WORKDIR" "$KVER" 2>/dev/null || true
ok "ext4 + jbd2 modules injected and depmod executed"

# ─── Step 4: Create symlinks for mkfs variants ───────────────────
info "Creating filesystem tool symlinks..."
cd "$WORKDIR"
# mke2fs should already be injected, create convenience symlinks
for fs in mkfs.ext3 mkfs.ext4; do
    if [ ! -e "usr/sbin/$fs" ] && [ -e "usr/sbin/mke2fs" ]; then
        ln -sf mke2fs "usr/sbin/$fs"
    fi
done
ok "Filesystem symlinks created"

# ─── Step 5: Patch inittab ────────────────────────────────────────
info "Patching inittab..."
cat > "$WORKDIR/etc/inittab" << 'INITTAB'
# /etc/inittab
# Verlian Debian Installer — busybox init configuration

# Initialize system (hardware, network, cdrom)
::sysinit:/sbin/verlian-init

# Root shell on tty1 (main console)
tty1::respawn:-/bin/sh -l

# Extra shell on tty2
tty2::askfirst:-/bin/sh -l

# System log on tty3
tty3::respawn:/usr/bin/tail -f /var/log/syslog

# Clean shutdown
::ctrlaltdel:/sbin/shutdown > /dev/null 2>&1

# Re-exec init on SIGHUP
::restart:/sbin/init
INITTAB
ok "Inittab patched"

# ─── Step 6: Install Verlian scripts ────────────────────────────────
info "Installing Verlian scripts..."

# verlian-init
cp "$BASEDIR/verlian-init" "$WORKDIR/sbin/verlian-init"
chmod 755 "$WORKDIR/sbin/verlian-init"

# MOTD
cp "$BASEDIR/verlian-motd" "$WORKDIR/etc/motd"

# verlian-guide
cp "$BASEDIR/verlian-guide" "$WORKDIR/usr/bin/verlian-guide"
chmod 755 "$WORKDIR/usr/bin/verlian-guide"

# Profile
cp "$BASEDIR/verlian-profile" "$WORKDIR/etc/profile"

# Make sure /root exists
mkdir -p "$WORKDIR/root"

# Symlink /lib/modules → /usr/lib/modules so modprobe can find modules
if [ ! -e "$WORKDIR/lib/modules" ]; then
    ln -sf /usr/lib/modules "$WORKDIR/lib/modules"
fi

ok "Verlian scripts installed"

# ─── Step 6.5: Inject Custom Branding ────────────────────────────
info "Injecting OS Branding (verlian-debian-based v1.0.0)..."

# Brand the Live Installer environment
cat > "$WORKDIR/etc/os-release" << 'EOF'
PRETTY_NAME="verlian-debian-based v1.0.0"
NAME="verlian-debian-based"
VERSION_ID="v1.0.0"
VERSION="v1.0.0"
VERSION_CODENAME=trixie
ID=verlian
ID_LIKE=debian
HOME_URL="https://localhost"
SUPPORT_URL="https://localhost"
BUG_REPORT_URL="https://localhost"
EOF
echo "verlian-debian-based v1.0.0 \n \l" > "$WORKDIR/etc/issue"

# Create a payload script for the target system
cat > "$WORKDIR/bin/verlian-install-brand" << 'BRAND'
#!/bin/sh
PINK='\033[1;35m'
PURPLE='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

if [ ! -d "/mnt/etc" ]; then
    printf "${PINK}[Verlian]${NC} Error: Target system not mounted at /mnt\n"
    exit 1
fi

printf "${PINK}[Verlian]${NC} Applying OS branding...\n"

echo "verlian-debian-based v1.0.0 \n \l" > /mnt/etc/issue
echo "verlian-debian-based v1.0.0" > /mnt/etc/issue.net
cat > /mnt/etc/os-release << 'EOF'
PRETTY_NAME="verlian-debian-based v1.0.0"
NAME="verlian-debian-based"
VERSION_ID="v1.0.0"
VERSION="v1.0.0"
VERSION_CODENAME=trixie
ID=verlian
ID_LIKE=debian
HOME_URL="https://localhost"
SUPPORT_URL="https://localhost"
BUG_REPORT_URL="https://localhost"
EOF

# Install Verlian PS1 for all users
# Append to /etc/bash.bashrc so it runs AFTER Debian's default PS1 logic
# Colors: username=purple, @=pink, hostname=purple, path=white, $=pink
cat >> /mnt/etc/bash.bashrc << 'BASHRC'

# Verlian — pink/purple shell prompt
_verlian_pink='\[\033[1;35m\]'
_verlian_purple='\[\033[0;35m\]'
_verlian_nc='\[\033[0m\]'
if [ "$(id -u)" -eq 0 ]; then
    PS1="${_verlian_purple}\u${_verlian_pink}@${_verlian_purple}\h${_verlian_nc}:\w${_verlian_pink}#${_verlian_nc} "
else
    PS1="${_verlian_purple}\u${_verlian_pink}@${_verlian_purple}\h${_verlian_nc}:\w${_verlian_pink}\$${_verlian_nc} "
fi
BASHRC

# Append Verlian PS1 to /etc/skel/.bashrc so new users get colored prompt
if [ -f /mnt/etc/skel/.bashrc ]; then
    cat >> /mnt/etc/skel/.bashrc << 'SKEL_PROMPT'

# Verlian — pink/purple shell prompt
_vp='\[\033[1;35m\]'
_vu='\[\033[0;35m\]'
_nc='\[\033[0m\]'
PS1="${_vu}\u${_vp}@${_vu}\h${_nc}:\w${_vp}\$ ${_nc}"
SKEL_PROMPT
fi

# Install colored MOTD for the installed system
printf '\r\n \033[1;35m╔═══════════════════════════════════════════════════╗\033[0m\r\n \033[1;35m║\033[0m     \033[1;37mVerlian Installer — Root Shell\033[0m                \033[1;35m║\033[0m\r\n \033[1;35m║\033[0m     \033[1;37mverlian-debian-based v1.0.0\033[0m                   \033[1;35m║\033[0m\r\n \033[1;35m╚═══════════════════════════════════════════════════╝\033[0m\r\n\r\n' > /mnt/etc/motd
# Overwrite MOTD kernel string generation script to replace Debian branding
cat > /mnt/etc/update-motd.d/10-uname << 'UNAME_SCRIPT'
#!/bin/sh
#
uname -snrvm | sed 's/deb13/verlian/g' | sed 's/Debian/Verlian/g'
UNAME_SCRIPT
chmod +x /mnt/etc/update-motd.d/10-uname

# Lock the files using dpkg-divert so apt upgrade base-files doesn't overwrite
chroot /mnt dpkg-divert --add --rename --divert /etc/update-motd.d/10-uname.debian /etc/update-motd.d/10-uname >/dev/null 2>&1 || true
chroot /mnt dpkg-divert --add --rename --divert /etc/os-release.debian /etc/os-release >/dev/null 2>&1 || true
chroot /mnt dpkg-divert --add --rename --divert /etc/issue.debian /etc/issue >/dev/null 2>&1 || true
printf "${PINK}[Verlian]${NC} Target system branded as verlian-debian-based!\n"
BRAND
chmod +x "$WORKDIR/bin/verlian-install-brand"

# Create the master automated installer script
cat > "$WORKDIR/bin/install-verlian" << 'INSTALLER'
#!/bin/sh
set -e

# ── Colors ───────────────────────────────────────────────────────────────────
PINK='\033[1;35m'
PURPLE='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

step()   { printf "${PINK}[%s]${NC} %s\n" "$1" "$2"; }
warn()   { printf "${PINK}[!]${NC} ${WHITE}%s${NC}\n" "$1"; }

# ── BRUTE FORCE CLOCK SYNC (BusyBox compatible) ──────────────────────────────
# The VM hardware clock is out of sync; APT will refuse to run without the
# correct time. We fetch the real UTC time from Google's HTTP headers and set it
# IMMEDIATELY, before any other step.
_HDATE=$(wget -qSO- --max-redirect=0 http://google.com 2>&1 | grep -i "^ *date:" | head -1)
if [ -n "$_HDATE" ]; then
    _MON=$(echo "$_HDATE" | awk '{print $4}')
    _DD=$(echo "$_HDATE" | awk '{printf "%02d",$3}')
    _YY=$(echo "$_HDATE" | awk '{print $5}')
    _TM=$(echo "$_HDATE" | awk '{print $6}' | tr -d ':')
    _HH=$(echo "$_TM" | cut -c1-2)
    _MI=$(echo "$_TM" | cut -c3-4)
    _SS=$(echo "$_TM" | cut -c5-6)
    case "$_MON" in
        Jan) _M=01;; Feb) _M=02;; Mar) _M=03;; Apr) _M=04;;
        May) _M=05;; Jun) _M=06;; Jul) _M=07;; Aug) _M=08;;
        Sep) _M=09;; Oct) _M=10;; Nov) _M=11;; Dec) _M=12;;
        *) _M=01;;
    esac
    # BusyBox date format: MMDDHHmmYYYY.SS
    date "${_M}${_DD}${_HH}${_MI}${_YY}.${_SS}"
    printf "${PINK}[Verlian]${NC} System clock set to: $(date)\n"
fi
# ─────────────────────────────────────────────────────────────────────────────

printf "\n"
printf "${PINK}══════════════════════════════════════════════════════${NC}\n"
printf "${PINK}  Welcome to verlian-debian-based v1.0.0 installer!${NC}\n"
printf "${PINK}══════════════════════════════════════════════════════${NC}\n"
warn "This will absolutely DESTROY ALL DATA on /dev/vda"
printf "\n"

# Interactive setup — pink prompts
printf "${PINK}►${NC} Enter a HOSTNAME for your computer: "
read NEW_HOSTNAME
printf "${PINK}►${NC} Enter a lower-case USERNAME for your account: "
read NEW_USER
stty -echo
printf "${PINK}►${NC} Enter a PASSWORD for $NEW_USER: "
read NEW_PASS
printf "\n"
printf "${PINK}►${NC} Enter a ROOT PASSWORD: "
read ROOT_PASS
printf "\n"
stty echo
printf "\n"

printf "  Hostname: ${WHITE}$NEW_HOSTNAME${NC}\n"
printf "  Username: ${WHITE}$NEW_USER${NC}\n"
printf "\n"
printf "${PURPLE}Press ENTER to begin installation, or Ctrl+C to abort...${NC}"
read dummy
printf "\n"

step "1/7" "Partitioning /dev/vda..."
cat << 'EOF' | fdisk /dev/vda > /dev/null 2>&1
g
n
1

+2M
t
4
n
2

+2G
n
3


w
EOF

step "2/7" "Formatting filesystems..."
# Note: /dev/vda1 is a BIOS Boot Partition, it must NOT be formatted!
mkswap /dev/vda2 > /dev/null 2>&1
mkfs.ext4 -F /dev/vda3 > /dev/null 2>&1

step "3/7" "Mounting target partitions..."
mkdir -p /mnt
mount /dev/vda3 /mnt

step "4/7" "Downloading and installing base system (debootstrap)..."
debootstrap --components=main,contrib,non-free-firmware trixie /mnt http://deb.debian.org/debian

step "5/7" "Preparing chroot environment..."
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys
# Give chroot network access for apt
cp /etc/resolv.conf /mnt/etc/resolv.conf

# Sync the system clock BEFORE entering chroot (chroot shares the host kernel clock)
printf "${PINK}[Verlian]${NC} Synchronizing clock...\n"
RAW_DATE=$(wget -qSO- --max-redirect=0 google.com 2>&1 | grep -i '^ *date:' | head -n1 | sed -e 's/^ *date: *//i')
if [ -n "$RAW_DATE" ]; then
    FORMATTED_DATE=$(date -d "$RAW_DATE" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "")
    if [ -n "$FORMATTED_DATE" ]; then
        date -s "$FORMATTED_DATE"
        hwclock -w 2>/dev/null || true
        printf "${PINK}[Verlian]${NC} Clock synced to: $FORMATTED_DATE\n"
    fi
fi

step "6/7" "Configuring system inside chroot..."
cat > /mnt/tmp/chroot-setup.sh << EOF_CHROOT
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
echo "$NEW_HOSTNAME" > /etc/hostname
ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime

# Sources
echo "deb [trusted=yes] http://deb.debian.org/debian trixie main contrib non-free-firmware" > /etc/apt/sources.list
echo "deb [trusted=yes] http://deb.debian.org/debian-security trixie-security main contrib non-free-firmware" >> /etc/apt/sources.list

# Update apt
apt-get -o Acquire::Check-Valid-Until=false -o Acquire::Max-FutureTime=864000 update

# Install grub and kernel
apt-get install -y linux-image-amd64 grub-pc sudo vim openssh-server network-manager fastfetch >> /var/log/install.log 2>&1

# Install GRUB silently
echo "grub-pc grub-pc/install_devices multiselect /dev/vda" | debconf-set-selections
grub-install /dev/vda > /dev/null 2>&1
update-grub > /dev/null 2>&1

# Setup fstab
echo "/dev/vda3 / ext4 rw,relatime 0 1" > /etc/fstab
echo "/dev/vda2 none swap sw 0 0" >> /etc/fstab

# Create user
useradd -m -G sudo -s /bin/bash "$NEW_USER"
echo "$NEW_USER:$NEW_PASS" | chpasswd
echo "root:$ROOT_PASS" | chpasswd
EOF_CHROOT

chmod +x /mnt/tmp/chroot-setup.sh
chroot /mnt /tmp/chroot-setup.sh
rm /mnt/tmp/chroot-setup.sh

# Append Verlian PS1 to user and root .bashrc (runs last, overrides Debian defaults)
for RCFILE in "/mnt/home/$NEW_USER/.bashrc" "/mnt/root/.bashrc"; do
    if [ -f "$RCFILE" ]; then
        cat >> "$RCFILE" << 'VERLIAN_PROMPT'

# Verlian — pink/purple shell prompt
_vp='\[\033[1;35m\]'
_vu='\[\033[0;35m\]'
_nc='\[\033[0m\]'
PS1="${_vu}\u${_vp}@${_vu}\h${_nc}:\w${_vp}\$ ${_nc}"
VERLIAN_PROMPT
    fi
done

step "7/7" "Applying Verlian branding..."
verlian-install-brand

printf "\n"
printf "${PINK}══════════════════════════════════════════════════════${NC}\n"
printf "${PINK}  INSTALLATION COMPLETE!${NC}\n"
printf "${PINK}══════════════════════════════════════════════════════${NC}\n"
printf "  Username: ${WHITE}$NEW_USER${NC}\n"
printf "  Password: ${WHITE}(The one you entered)${NC}\n"
printf "\n"
printf "  Run ${PINK}reboot -f${NC} and disconnect the installation ISO.\n"
printf "\n"
INSTALLER
chmod +x "$WORKDIR/bin/install-verlian"

ok "Branding and installer injected"

# ─── Step 7: Update ld.so cache paths ────────────────────────────
info "Updating library paths..."
# Ensure the dynamic linker can find all libs
if [ ! -f "$WORKDIR/etc/ld.so.conf" ]; then
    echo "/usr/lib" > "$WORKDIR/etc/ld.so.conf"
    echo "/usr/lib/x86_64-linux-gnu" >> "$WORKDIR/etc/ld.so.conf"
    echo "/lib" >> "$WORKDIR/etc/ld.so.conf"
    echo "/lib/x86_64-linux-gnu" >> "$WORKDIR/etc/ld.so.conf"
else
    # Make sure our paths are included
    grep -q "usr/lib/x86_64-linux-gnu" "$WORKDIR/etc/ld.so.conf" || \
        echo "/usr/lib/x86_64-linux-gnu" >> "$WORKDIR/etc/ld.so.conf"
fi

# Also set LD_LIBRARY_PATH in profile as fallback
echo 'export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/lib:/lib/x86_64-linux-gnu:/lib' >> "$WORKDIR/etc/profile"

ok "Library paths configured"

# ─── Step 8: Patch busybox ───────────────────────────────────────
info "Patching busybox banner..."
cd "$WORKDIR"
sed -i 's/Debian 1:1.37.0-6+b5/Verlian-Based-v1.0.0/g' bin/busybox || true
sed -i 's/Debian 1:1.37.0-6+b5/Verlian-Based-v1.0.0/g' usr/bin/busybox || true
ok "BusyBox banner patched"

# ─── Step 9: Repack initrd ────────────────────────────────────────
info "Repacking initrd..."
cd "$WORKDIR"
find . | cpio -o -H newc --quiet 2>/dev/null | gzip -9 > "$OUTPUT_INITRD"
ok "Initrd repacked ($(du -sh "$OUTPUT_INITRD" | cut -f1))"

# ─── Step 9: Cleanup ─────────────────────────────────────────────
info "Cleaning up..."
rm -rf "$UDEB_TMP"
ok "Done! Modified initrd written to $OUTPUT_INITRD"

echo ""
echo -e "${PINK}═══════════════════════════════════════════${NC}"
echo -e "${PINK}  Initrd build complete!${NC}"
echo -e "${PINK}  Next: run ./build_iso.sh to build the ISO${NC}"
echo -e "${PINK}═══════════════════════════════════════════${NC}"
