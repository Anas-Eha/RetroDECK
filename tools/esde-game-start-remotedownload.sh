#!/bin/bash

# ES-DE Custom Event Script for Remote ROM Downloads - MINIMAL VERSION
# Documentation: https://gitlab.com/es-de/emulationstation-de/-/blob/master/INSTALL.md#custom-event-scripts
#
# Installation:
#   mkdir -p ~/.var/app/net.retrodeck.retrodeck/config/ES-DE/scripts/game-start
#   cp remotedownload.sh ~/.var/app/net.retrodeck.retrodeck/config/ES-DE/scripts/game-start/game-start.sh
#   chmod +x ~/.var/app/net.retrodeck.retrodeck/config/ES-DE/scripts/game-start/game-start.sh

# Arguments from ES-DE (game-start/ directory):
# $1 = ROM path, $2 = game name, $3 = system short name, $4 = system full name

rom_path="$1"
system_name="$3"
echo "ES-DE Remote Download Script Triggered for ROM: $rom_path (System: $system_name)"

# Only process remote paths
[[ "$rom_path" != */remote/* ]] && exit 0

# Paths
roms_path="${HOME}/retrodeck/roms"
echo "Local ROMs path: $roms_path"
if [[ -z "$system_name" ]]; then
    system_name=$(echo "$rom_path" | grep -oP '(?<=roms/)[^/]+')
    echo "Extracted system name from path: $system_name"
fi
# Unescape the ROM path (ES-DE escapes special characters)
rom_path_unescaped=$(echo "$rom_path" | sed 's/\\ / /g; s/\\(/(/g; s/\\)/)/g; s/\\\[/\[/g; s/\\\]/\]/g')
rom_name=$(basename "$rom_path_unescaped")
echo "ROM name (unescaped): $rom_name"
local_rom_path="$roms_path/$system_name/$rom_name"
echo "Expected local ROM path: $local_rom_path"
echo "Using unescaped path for operations: $rom_path_unescaped"
rclone_config="${HOME}/.var/app/net.retrodeck.retrodeck/config/retrodeck/rclone/rclone.conf"
echo "Expected rclone config path: $rclone_config"
# Find rclone binary - check multiple locations
# 1. Inside Flatpak runtime (/app/bin)
# 2. User's local Flatpak installation
# 3. System PATH
if [[ -x "/app/bin/rclone" ]]; then
    rclone_bin="/app/bin/rclone"
    echo "Found rclone in Flatpak runtime: $rclone_bin"
elif [[ -x "${HOME}/.local/share/flatpak/app/net.retrodeck.retrodeck/current/active/files/bin/rclone" ]]; then
    rclone_bin="${HOME}/.local/share/flatpak/app/net.retrodeck.retrodeck/current/active/files/bin/rclone"
    echo "Found rclone in user's Flatpak installation: $rclone_bin"
elif command -v rclone >/dev/null 2>&1; then
    rclone_bin="rclone"
    echo "Found rclone in system PATH: $rclone_bin"
else
    echo "[ERROR] rclone not found" >&2
    echo '{"cancelLaunch": true}'
    exit 1
fi

echo "[DEBUG] Using rclone: $rclone_bin"

# Already downloaded?
if [[ -f "$local_rom_path" ]]; then
    echo "{\"romPath\": \"$local_rom_path\"}"
    exit 0
fi
echo "ROM not found locally. Attempting to download from remote storage..."
# Need to download
mkdir -p "$roms_path/$system_name"
temp_file="${local_rom_path}.tmp.$$"
echo "Downloading remote ROM using rclone..."
echo "[DEBUG] rclone config exists: $(test -f "$rclone_config" && echo YES || echo NO)"
echo "[DEBUG] rclone config path: $rclone_config"
echo "[DEBUG] rclone remote path: retrodeck-remote:/$system_name/$rom_name"
echo "[DEBUG] using unescaped name for remote lookup"
echo "[DEBUG] temp file: $temp_file"

# Run rclone with visible error output for debugging
rclone_output=$("$rclone_bin" --config "$rclone_config" copyto "retrodeck-remote:/$system_name/$rom_name" "$temp_file" 2>&1)
rclone_exit=$?
echo "[DEBUG] rclone exit code: $rclone_exit"
echo "[DEBUG] rclone output: $rclone_output"

if [[ $rclone_exit -eq 0 ]]; then
    if mv "$temp_file" "$local_rom_path"; then
        echo "{\"romPath\": \"$local_rom_path\"}"
        exit 0
    fi
fi

rm -f "$temp_file" 2>/dev/null
echo '{"cancelLaunch": true}'
exit 1
