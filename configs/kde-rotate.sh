#!/bin/bash
# KDE Wayland screen rotation for ASUS Chromebook Flip C434
# Polls the cros-ec-accel display accelerometer and rotates the screen
# Uses kscreen-doctor for KDE Plasma 6 Wayland rotation
# Dynamically finds the display accelerometer by mount matrix signature

# Wait for KDE Plasma to be ready
for i in $(seq 1 30); do
    if command -v kscreen-doctor &>/dev/null; then
        break
    fi
    sleep 1
done

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
    echo "ERROR: Could not find display accelerometer" >&2
    exit 1
fi

ACCEL_X="${ACCEL_PATH}/in_accel_x_raw"
ACCEL_Y="${ACCEL_PATH}/in_accel_y_raw"
ACCEL_Z="${ACCEL_PATH}/in_accel_z_raw"

if [[ ! -f "$ACCEL_X" || ! -f "$ACCEL_Y" || ! -f "$ACCEL_Z" ]]; then
    echo "ERROR: Accelerometer files not found at $ACCEL_PATH" >&2
    exit 1
fi

THRESHOLD=5000
POLL_INTERVAL=1

# Orientation mapping verified by physical testing:
# Mount matrix: -1,0,0; 0,1,0; 0,0,1
# Flat (screen up):    X≈-165,  Y≈520,   Z≈16174 → normal
# Tilted right (CW):   X≈16174, Y≈459,   Z≈-704  → X dominant, positive → right
# Tilted left (CCW):   X≈-16174,Y≈-459,  Z≈704   → X dominant, negative → left
# Inverted (screen down): X≈165, Y≈-520, Z≈-16174 → Z negative → inverted

get_orientation() {
    local x y z
    x=$(cat "$ACCEL_X" 2>/dev/null) || return 1
    y=$(cat "$ACCEL_Y" 2>/dev/null) || return 1
    z=$(cat "$ACCEL_Z" 2>/dev/null) || return 1

    local abs_x=${x#-}
    local abs_y=${y#-}
    local abs_z=${z#-}

    # X axis is the primary rotation axis on this Chromebook
    if (( abs_x >= abs_z && abs_x >= abs_y )); then
        # X-axis dominant: device tilted sideways
        if (( x > 0 )); then
            echo "right"
        else
            echo "left"
        fi
    elif (( abs_z >= abs_y )); then
        # Z-axis dominant: flat or inverted
        if (( z > 0 )); then
            echo "normal"
        else
            echo "inverted"
        fi
    else
        # Y-axis dominant (unlikely on this device)
        if (( y > 0 )); then
            echo "normal"
        else
            echo "inverted"
        fi
    fi
}

current_rotation="normal"

while true; do
    new_rotation=$(get_orientation)
    if [[ -n "$new_rotation" && "$new_rotation" != "$current_rotation" ]]; then
        case "$new_rotation" in
            normal)   kscreen-doctor output.*.rotation.normal 2>/dev/null ;;
            left)     kscreen-doctor output.*.rotation.left 2>/dev/null ;;
            right)    kscreen-doctor output.*.rotation.right 2>/dev/null ;;
            inverted) kscreen-doctor output.*.rotation.inverted 2>/dev/null ;;
        esac
        if [[ $? -eq 0 ]]; then
            current_rotation="$new_rotation"
        fi
    fi
    sleep "$POLL_INTERVAL"
done
