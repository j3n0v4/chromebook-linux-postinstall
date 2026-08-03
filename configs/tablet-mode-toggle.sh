#!/bin/bash
# Enable/disable internal keyboard based on lid angle
# Called by udev rule on cros-ec-accel change
# Dynamically finds the display accelerometer by mount matrix signature
# When lid is flipped past ~360° (tablet mode), inhibit keyboard

# Find the display accelerometer: the one with mount matrix "0, 1, 0" in the Y row
find_display_accel() {
    for dev in /sys/bus/iio/devices/iio:device*; do
        name=$(cat "$dev/name" 2>/dev/null)
        if [[ "$name" != "cros-ec-accel" ]]; then
            continue
        fi
        matrix=$(udevadm info "$dev" 2>/dev/null | grep "ACCEL_MOUNT_MATRIX=" | sed 's/.*ACCEL_MOUNT_MATRIX=//')
        if echo "$matrix" | grep -q "0, 1, 0"; then
            echo "$dev"
            return 0
        fi
    done
    return 1
}

ACCEL_PATH=$(find_display_accel)
if [[ -z "$ACCEL_PATH" ]]; then
    exit 0
fi

Z_RAW=$(cat "${ACCEL_PATH}/in_accel_z_raw" 2>/dev/null || echo "0")

KEYBOARD=$(grep -rl "AT Translated Set 2 keyboard" /sys/class/input/input*/name 2>/dev/null | head -1 | grep -oP 'input\d+')

if [[ -z "$KEYBOARD" ]]; then
    exit 0
fi

INHIBIT_FILE="/sys/class/input/$KEYBOARD/inhibited"
if [[ ! -f "$INHIBIT_FILE" ]]; then
    exit 0
fi

# Z < -5000 = lid flipped past horizontal = tablet mode
if (( Z_RAW < -5000 )); then
    echo "1" > "$INHIBIT_FILE"
else
    echo "0" > "$INHIBIT_FILE"
fi
