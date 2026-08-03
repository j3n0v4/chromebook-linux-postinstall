#!/bin/bash
# chromebook-linux-postinstall — Post-install configuration for Fedora on Chromebook (coreboot)
# Only hardware-specific fixes. No desktop environment configuration.
# Usage: sudo ./postinstall.sh [--dry-run]
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo -e "${YELLOW}[DRY RUN]${NC} No changes will be made."
    echo ""
fi

do_cmd() {
    local desc="$1"
    shift
    if $DRY_RUN; then
        echo -e "  ${YELLOW}[DRY RUN]${NC} $desc"
        echo "    would run: $*"
    else
        echo -e "  ${GREEN}[EXEC]${NC} $desc"
        "$@"
    fi
}

step_ok()   { echo -e "  ${GREEN}[OK]${NC} $1"; }
step_skip() { echo -e "  ${YELLOW}[SKIP]${NC} $1"; }
step_fail() { echo -e "  ${RED}[FAIL]${NC} $1"; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This script must be run as root.${NC}" >&2
        exit 1
    fi
}

TOTAL=12
CONFIG_DIR="$(cd "$(dirname "$0")" && pwd)/configs"

echo "============================================"
echo " Chromebook Linux Post-Install"
echo " 12 steps — $( $DRY_RUN && echo 'DRY RUN' || echo 'LIVE' )"
echo "============================================"
echo ""

if ! $DRY_RUN; then
    require_root
fi

# ------------------------------------------------------------------
# Step 1 — Audio: chrultrabook audio setup (PREREQUISITE check)
# ------------------------------------------------------------------
echo -e "\n${GREEN}[STEP 1/${TOTAL}]${NC} Audio — chrultrabook audio setup"

AUDIO_SCRIPT="/usr/local/bin/chromebook-linux-audio-setup.py"
if [[ -f "$AUDIO_SCRIPT" ]]; then
    step_ok "Audio script found at $AUDIO_SCRIPT"
elif [[ -f "/usr/local/bin/chromebook-linux-audio/setup-audio" ]]; then
    step_ok "Audio script found at /usr/local/bin/chromebook-linux-audio/setup-audio"
else
    step_skip "Audio script not installed — see INSTALL.md for prerequisite steps"
fi

# ------------------------------------------------------------------
# Step 2 — Keyboard: keyd/cros-keyboard-map (PREREQUISITE check)
# ------------------------------------------------------------------
echo -e "\n${GREEN}[STEP 2/${TOTAL}]${NC} Keyboard — keyd remapping"

if systemctl is-active keyd &>/dev/null; then
    step_ok "keyd service is running"
else
    step_skip "keyd service not running — see INSTALL.md for prerequisite steps"
fi

# ------------------------------------------------------------------
# Step 3 — eMMC: Mount option tuning (noatime, discard)
# ------------------------------------------------------------------
echo -e "\n${GREEN}[STEP 3/${TOTAL}]${NC} eMMC — Mount option tuning"

ROOT_FSTYPE=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "ext4")

if grep -q "noatime" /etc/fstab 2>/dev/null; then
    step_skip "noatime already set in /etc/fstab"
else
    if [[ "$ROOT_FSTYPE" == "btrfs" ]]; then
        do_cmd "Add noatime,discard to btrfs root in /etc/fstab" \
            bash -c "sed -i 's|\(subvol=root,compress=zstd:1\)|subvol=root,compress=zstd:1,noatime,discard|' /etc/fstab"
    else
        do_cmd "Add noatime,nodiratime,commit=60,discard to /etc/fstab" \
            bash -c "sed -i 's|\(defaults\)|defaults,noatime,nodiratime,commit=60,discard|' /etc/fstab"
    fi
fi

# ------------------------------------------------------------------
# Step 4 — Zram: compressed swap in RAM (4 GB, lz4)
# ------------------------------------------------------------------
echo -e "\n${GREEN}[STEP 4/${TOTAL}]${NC} Zram — Compressed swap in RAM"

if swapon --show=NAME --noheadings 2>/dev/null | grep -q "zram"; then
    ZRAM_SIZE=$(swapon --show=SIZE --noheadings 2>/dev/null | head -1 | awk '{print $1}' || echo "unknown")
    step_skip "Zram already active (${ZRAM_SIZE} swap)"
elif [[ -f /etc/systemd/zram-generator.conf ]]; then
    step_skip "zram-generator.conf already exists"
else
    do_cmd "Copy zram-generator.conf" cp "$CONFIG_DIR/zram-generator.conf" /etc/systemd/zram-generator.conf
fi

DISK_SWAP=$(swapon --show=NAME,TYPE --noheadings 2>/dev/null | grep -v "zram" | awk '{print $1}' || true)
if [[ -z "$DISK_SWAP" ]]; then
    step_skip "No swap-on-disk devices found"
else
    for dev in $DISK_SWAP; do
        do_cmd "Disable swap on $dev" swapoff "$dev"
    done
    if grep -q "swap" /etc/fstab 2>/dev/null; then
        do_cmd "Remove disk swap entries from /etc/fstab" bash -c "sed -i '/swap/d' /etc/fstab"
    fi
fi

# ------------------------------------------------------------------
# Step 5 — Touchpad: libinput config (natural scroll, tap-to-click)
# ------------------------------------------------------------------
echo -e "\n${GREEN}[STEP 5/${TOTAL}]${NC} Touchpad — libinput configuration"

TOUCHPAD_CONF="/etc/X11/xorg.conf.d/30-touchpad.conf"
if [[ -f "$TOUCHPAD_CONF" ]]; then
    step_skip "Touchpad config already exists"
else
    do_cmd "Create X11 config directory" mkdir -p /etc/X11/xorg.conf.d
    do_cmd "Copy 30-touchpad.conf" cp "$CONFIG_DIR/30-touchpad.conf" "$TOUCHPAD_CONF"
fi

# ------------------------------------------------------------------
# Step 6 — VAAPI: Intel hardware video decode
# ------------------------------------------------------------------
echo -e "\n${GREEN}[STEP 6/${TOTAL}]${NC} VAAPI — Intel hardware video decode"

if rpm -q intel-media-driver &>/dev/null; then
    step_skip "intel-media-driver already installed"
else
    do_cmd "Install intel-media-driver" dnf install -y intel-media-driver
fi

if command -v vainfo &>/dev/null; then
    step_skip "vainfo already installed"
else
    do_cmd "Install vainfo" dnf install -y vainfo
fi

# ------------------------------------------------------------------
# Step 7 — Brightnessctl: backlight control + udev permissions
# ------------------------------------------------------------------
echo -e "\n${GREEN}[STEP 7/${TOTAL}]${NC} Brightnessctl — Backlight control"

if command -v brightnessctl &>/dev/null; then
    step_skip "brightnessctl already installed"
else
    do_cmd "Install brightnessctl" dnf install -y brightnessctl
fi

BACKLIGHT_UDEV="/etc/udev/rules.d/40-backlight.rules"
if [[ -f "$BACKLIGHT_UDEV" ]]; then
    step_skip "40-backlight.rules already exists"
else
    do_cmd "Copy 40-backlight.rules" cp "$CONFIG_DIR/40-backlight.rules" "$BACKLIGHT_UDEV"
    do_cmd "Reload udev rules" udevadm control --reload-rules
fi

# ------------------------------------------------------------------
# Step 8 — Xrandr: needed by rotation script
# ------------------------------------------------------------------
echo -e "\n${GREEN}[STEP 8/${TOTAL}]${NC} Xrandr — Display rotation support"

if command -v xrandr &>/dev/null; then
    step_skip "xrandr already installed"
else
    do_cmd "Install xrandr" dnf install -y xrandr
fi

# ------------------------------------------------------------------
# Step 9 — Screen rotation: systemd user service (NOT udev)
# ------------------------------------------------------------------
echo -e "\n${GREEN}[STEP 9/${TOTAL}]${NC} Screen rotation — systemd user service"

ROTATE_SCRIPT="/usr/local/bin/xfce-rotate.sh"
if [[ -f "$ROTATE_SCRIPT" ]]; then
    step_skip "xfce-rotate.sh already installed"
else
    do_cmd "Copy xfce-rotate.sh" cp "$CONFIG_DIR/xfce-rotate.sh" "$ROTATE_SCRIPT"
    do_cmd "Make executable" chmod +x "$ROTATE_SCRIPT"
fi

ROTATE_SERVICE_DIR="/usr/lib/systemd/user"
ROTATE_SERVICE="$ROTATE_SERVICE_DIR/xfce-rotate.service"
if [[ -f "$ROTATE_SERVICE" ]]; then
    step_skip "xfce-rotate.service already installed"
else
    do_cmd "Copy xfce-rotate.service" cp "$CONFIG_DIR/xfce-rotate.service" "$ROTATE_SERVICE"
fi

# ------------------------------------------------------------------
# Step 10 — Tablet mode: disable keyboard when lid flipped past 360°
# ------------------------------------------------------------------
echo -e "\n${GREEN}[STEP 10/${TOTAL}]${NC} Tablet mode — Keyboard disable on lid flip"

TABLET_SCRIPT="/usr/local/bin/tablet-mode-toggle.sh"
if [[ -f "$TABLET_SCRIPT" ]]; then
    step_skip "tablet-mode-toggle.sh already installed"
else
    do_cmd "Copy tablet-mode-toggle.sh" cp "$CONFIG_DIR/tablet-mode-toggle.sh" "$TABLET_SCRIPT"
    do_cmd "Make executable" chmod +x "$TABLET_SCRIPT"
fi

TABLET_UDEV="/etc/udev/rules.d/99-tablet-mode-keyboard.rules"
if [[ -f "$TABLET_UDEV" ]]; then
    step_skip "Tablet mode udev rule already exists"
else
    do_cmd "Copy 99-tablet-mode-keyboard.rules" cp "$CONFIG_DIR/99-tablet-mode-keyboard.rules" "$TABLET_UDEV"
    do_cmd "Reload udev rules" udevadm control --reload-rules
fi

# ------------------------------------------------------------------
# Step 11 — Journald: limit log volume to reduce eMMC writes
# ------------------------------------------------------------------
echo -e "\n${GREEN}[STEP 11/${TOTAL}]${NC} Journald — Log volume limits"

JOURNALD_CONF="/etc/systemd/journald.conf.d/limits.conf"
if [[ -f "$JOURNALD_CONF" ]]; then
    step_skip "Journald limits config already exists"
else
    do_cmd "Create journald.conf.d directory" mkdir -p /etc/systemd/journald.conf.d
    do_cmd "Copy limits.conf" cp "$CONFIG_DIR/limits.conf" "$JOURNALD_CONF"
    do_cmd "Restart systemd-journald" systemctl restart systemd-journald
fi

# ------------------------------------------------------------------
# Step 12 — TRIM: weekly fstrim for eMMC
# ------------------------------------------------------------------
echo -e "\n${GREEN}[STEP 12/${TOTAL}]${NC} TRIM — Weekly fstrim"

if systemctl is-enabled fstrim.timer &>/dev/null 2>&1; then
    step_skip "fstrim.timer already enabled"
else
    do_cmd "Enable fstrim.timer" systemctl enable --now fstrim.timer
fi

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo -e "\n${GREEN}[DONE]${NC} All steps complete."
echo ""
echo "============================================"
echo " Changes applied:"
echo "============================================"
echo ""
echo "  1. Audio — chrultrabook audio script (prerequisite, checked)"
echo "  2. Keyboard — keyd remapping (prerequisite, checked)"
echo "  3. eMMC — noatime,discard in fstab (btrfs) or noatime,nodiratime,commit=60,discard (ext4)"
echo "  4. Zram — 4 GB lz4, swap-on-disk disabled"
echo "  5. Touchpad — libinput config (natural scroll, tap-to-click)"
echo "  6. VAAPI — intel-media-driver installed"
echo "  7. Brightnessctl — backlight control + udev permissions"
echo "  8. Xrandr — display rotation support"
echo "  9. Screen rotation — systemd user service (dynamic device discovery)"
echo "  10. Tablet mode — keyboard disable udev rule (dynamic device discovery)"
echo "  11. Journald — 50M system / 25M runtime limits"
echo "  12. TRIM — weekly fstrim enabled"
echo ""
echo "============================================"
echo " Post-install complete!"
if $DRY_RUN; then
    echo " This was a dry run — no changes were made."
    echo " Run without --dry-run to apply changes."
fi
echo "============================================"
echo ""
echo -e "${YELLOW}After reboot:${NC}"
echo "  1. Enable rotation service: systemctl --user enable --now xfce-rotate.service"
echo "  2. Run verify.sh to confirm all settings"
echo ""
