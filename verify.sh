#!/bin/bash
# chromebook-linux-postinstall — Verification script
# Usage: sudo ./verify.sh
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
TOTAL=0

pass() { PASSED=$((PASSED + 1)); echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; }
skip() { echo -e "  ${YELLOW}[SKIP]${NC} $1"; }

check() {
    local name="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$actual" == "$expected" ]]; then
        pass "$name"
    else
        fail "$name — expected: $expected, actual: $actual"
    fi
}

check_contains() {
    local name="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$actual" | grep -q "$expected"; then
        pass "$name"
    else
        fail "$name — expected to contain: $expected, actual: $actual"
    fi
}

echo "============================================"
echo " Chromebook Linux Post-Install — Verification"
echo "============================================"
echo ""

# Step 1: Audio (prerequisite)
if [[ -x /usr/local/bin/chromebook-linux-audio-setup.py ]]; then
    pass "Audio script exists and executable"
elif [[ -x /usr/local/bin/chromebook-linux-audio/setup-audio ]]; then
    pass "Audio script exists (cloned repo)"
else
    skip "Audio script not installed — prerequisite not met"
fi

# Step 2: Keyboard (prerequisite)
if systemctl is-active keyd &>/dev/null; then
    pass "keyd service is running"
else
    skip "keyd service not running — prerequisite not met"
fi

# Step 3: eMMC mount tuning
FSTAB=$(cat /etc/fstab 2>/dev/null || echo "")
check_contains "fstab has noatime" "noatime" "$FSTAB"
ROOT_FSTYPE=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "ext4")
if [[ "$ROOT_FSTYPE" == "btrfs" ]]; then
    check_contains "fstab has discard (btrfs)" "discard" "$FSTAB"
else
    check_contains "fstab has nodiratime" "nodiratime" "$FSTAB"
    check_contains "fstab has commit=60" "commit=60" "$FSTAB"
    check_contains "fstab has discard" "discard" "$FSTAB"
fi

# Step 4: Zram
if [[ -f /etc/systemd/zram-generator.conf ]]; then
    ZRAM_CONTENT=$(cat /etc/systemd/zram-generator.conf)
    check_contains "zram size 4096" "4096" "$ZRAM_CONTENT"
    check_contains "zram algorithm lz4" "lz4" "$ZRAM_CONTENT"
else
    if swapon --show=NAME --noheadings 2>/dev/null | grep -q "zram"; then
        pass "Zram already active (kernel-configured)"
    else
        fail "zram-generator.conf missing and no zram active"
    fi
fi
DISK_SWAP=$(swapon --show=NAME,TYPE --noheadings 2>/dev/null | grep -v "zram" | awk '{print $1}' || true)
if [[ -z "$DISK_SWAP" ]]; then
    pass "No swap-on-disk active"
else
    fail "Swap-on-disk still active: $DISK_SWAP"
fi
if grep -q "^[^#].*swap" /etc/fstab 2>/dev/null; then
    fail "Swap entries still in /etc/fstab"
else
    pass "No swap entries in /etc/fstab"
fi

# Step 5: Touchpad
if [[ -f /etc/X11/xorg.conf.d/30-touchpad.conf ]]; then
    TP_CONTENT=$(cat /etc/X11/xorg.conf.d/30-touchpad.conf)
    check_contains "NaturalScrolling enabled" "NaturalScrolling" "$TP_CONTENT"
    check_contains "Tapping enabled" "Tapping" "$TP_CONTENT"
    check_contains "PalmDetection enabled" "PalmDetection" "$TP_CONTENT"
else
    fail "30-touchpad.conf missing"
fi

# Step 6: VAAPI
if rpm -q intel-media-driver &>/dev/null; then
    pass "intel-media-driver installed"
else
    fail "intel-media-driver not installed"
fi
if command -v vainfo &>/dev/null; then
    pass "vainfo installed"
else
    fail "vainfo not installed"
fi

# Step 7: Brightnessctl
if command -v brightnessctl &>/dev/null; then
    pass "brightnessctl installed"
else
    fail "brightnessctl not installed"
fi
if [[ -f /etc/udev/rules.d/40-backlight.rules ]]; then
    pass "40-backlight.rules exists"
else
    fail "40-backlight.rules missing"
fi

# Step 8: Xrandr
if command -v xrandr &>/dev/null; then
    pass "xrandr installed"
else
    fail "xrandr not installed"
fi

# Step 9: Screen rotation
if [[ -x /usr/local/bin/xfce-rotate.sh ]]; then
    pass "xfce-rotate.sh exists and executable"
else
    fail "xfce-rotate.sh missing or not executable"
fi
if [[ -f /usr/lib/systemd/user/xfce-rotate.service ]]; then
    pass "xfce-rotate.service exists"
else
    fail "xfce-rotate.service missing"
fi

# Step 10: Tablet mode
if [[ -x /usr/local/bin/tablet-mode-toggle.sh ]]; then
    pass "tablet-mode-toggle.sh exists and executable"
else
    fail "tablet-mode-toggle.sh missing or not executable"
fi
if [[ -f /etc/udev/rules.d/99-tablet-mode-keyboard.rules ]]; then
    pass "99-tablet-mode-keyboard.rules exists"
else
    fail "99-tablet-mode-keyboard.rules missing"
fi

# Step 11: Journald limits
if [[ -f /etc/systemd/journald.conf.d/limits.conf ]]; then
    JOURNAL_CONTENT=$(cat /etc/systemd/journald.conf.d/limits.conf)
    check_contains "SystemMaxUse=50M" "SystemMaxUse=50M" "$JOURNAL_CONTENT"
    check_contains "RuntimeMaxUse=25M" "RuntimeMaxUse=25M" "$JOURNAL_CONTENT"
else
    fail "journald limits.conf missing"
fi

# Step 12: TRIM timer
TRIM_STATUS=$(systemctl is-enabled fstrim.timer 2>/dev/null || echo "missing")
check "fstrim.timer enabled" "enabled" "$TRIM_STATUS"

echo ""
echo "============================================"
echo -e " Results: ${GREEN}${PASSED}${NC}/${TOTAL} passed"
if [[ $PASSED -eq $TOTAL ]]; then
    echo -e " ${GREEN}All checks passed!${NC}"
else
    echo -e " ${RED}$((TOTAL - PASSED)) check(s) failed.${NC}"
fi
echo "============================================"
