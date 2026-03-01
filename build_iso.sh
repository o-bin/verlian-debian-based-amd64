#!/bin/bash
# Verlian Debian Installer — Build ISO
# Rebuilds the modified Debian ISO using xorriso with the same flags Debian used.
#
# Usage: sudo ./build_iso.sh
# (Needs sudo for initrd build, then ISO build)

set -e

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
UNPACKED="$BASEDIR/debian-unpacked"
OUTPUT="$BASEDIR/verlian-debian-based-amd64.iso"
ISOHDPFX="/usr/lib/ISOLINUX/isohdpfx.bin"

# Colors
PINK='\033[1;35m'
GREEN='\033[1;32m'
NC='\033[0m'

info() { echo -e "${PINK}[Verlian]${NC} $1"; }
ok()   { echo -e "${PINK}[OK]${NC}   $1"; }
fail() { echo -e "${PINK}[FAIL]${NC} $1"; exit 1; }

# ─── Sanity checks ───────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || fail "Must run as root (sudo ./build_iso.sh)"
[ -d "$UNPACKED" ] || fail "Unpacked ISO not found at $UNPACKED"
[ -f "$ISOHDPFX" ] || fail "isohdpfx.bin not found. Install: apt install isolinux"
command -v xorriso >/dev/null || fail "xorriso not found. Install: apt install xorriso"

# ─── Step 1: Build modified initrd ───────────────────────────────
info "Phase 1: Building modified initrd..."
bash "$BASEDIR/build_initrd.sh"
echo ""

# ─── Step 2: Regenerate checksums ─────────────────────────────────
info "Phase 2: Regenerating checksums..."
cd "$UNPACKED"
find . -follow -type f \
    ! -name md5sum.txt \
    ! -path './isolinux/isolinux.bin' \
    ! -path './boot.catalog' \
    -print0 | xargs -0 md5sum > md5sum.txt 2>/dev/null
ok "Checksums regenerated ($(wc -l < md5sum.txt) files)"

# ─── Step 3: Build ISO ───────────────────────────────────────────
info "Phase 3: Building ISO image..."
xorriso -as mkisofs \
    -r \
    -V 'verlian-debian-based v1.0.0' \
    -o "$OUTPUT" \
    -isohybrid-mbr "$ISOHDPFX" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -boot-load-size 4 \
    -boot-info-table \
    -no-emul-boot \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -isohybrid-apm-hfsplus \
    "$UNPACKED"

ok "ISO built: $OUTPUT"

# ─── Step 4: Show results ────────────────────────────────────────
echo ""
echo -e "${PINK}═══════════════════════════════════════════════════${NC}"
echo -e "${PINK}  Verlian Debian ISO built successfully!${NC}"
echo -e "${PINK}═══════════════════════════════════════════════════${NC}"
echo ""
ls -lh "$OUTPUT"
echo ""
echo "  To test in QEMU (BIOS):"
echo "    qemu-system-x86_64 -m 2048 -cdrom $OUTPUT"
echo ""
echo "  To test in QEMU (UEFI, requires OVMF):"
echo "    qemu-system-x86_64 -m 2048 -bios /usr/share/OVMF/OVMF_CODE.fd -cdrom $OUTPUT"
echo ""
echo "  To write to USB:"
echo "    sudo dd if=$OUTPUT of=/dev/sdX bs=4M status=progress"
echo ""
