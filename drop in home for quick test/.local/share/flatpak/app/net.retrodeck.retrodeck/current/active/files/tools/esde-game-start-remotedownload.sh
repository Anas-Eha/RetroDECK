#!/bin/bash

# ES-DE Custom Event Script - Ultra Simplified
# If gamelist.xml.local doesn't exist: launch immediately (local-only system)
# If gamelist.xml.local exists and game is in it: launch
# Otherwise: download, append to gamelist.xml.local, launch
# Documentation: https://gitlab.com/es-de/emulationstation-de/-/blob/master/INSTALL.md#custom-event-scripts
# Installation:
#   mkdir -p ~/.var/app/net.retrodeck.retrodeck/config/ES-DE/scripts/game-start
#   cp esde-game-start-remotedownload.sh ~/.var/app/net.retrodeck.retrodeck/config/ES-DE/scripts/game-start/esde-game-start-remotedownload.sh
#   chmod +x ~/.var/app/net.retrodeck.retrodeck/config/ES-DE/scripts/game-start/esde-game-start-remotedownload.sh

rom_path="$1"
game_name="$2"
system_name="$3"

# Unescape the path (ES-DE passes shell-escaped paths with \ before spaces/special chars)
rom_path=$(echo "$rom_path" | sed 's/\\//g')

roms_path="${HOME}/retrodeck/roms"
rom_name=$(basename "$rom_path")
local_rom_path="$roms_path/$system_name/$rom_name"
gamelist_local="${HOME}/retrodeck/ES-DE/gamelists/${system_name}/gamelist.xml.local"


echo "BAWADOUNGA"
echo "$rom_path"
echo "$game_name"
echo "$system_name"
echo "$local_rom_path"
echo "$gamelist_local"
echo "BAWADOUNGA"



# No local gamelist = local-only system, just launch
[[ ! -f "$gamelist_local" ]] && echo "{\"romPath\": \"$local_rom_path\"}" && exit 0

# Check if game exists in local gamelist
xmlstarlet sel -t -v "//game[path='./$rom_name']" "$gamelist_local" >/dev/null 2>&1 && \
    echo "{\"romPath\": \"$local_rom_path\"}" && exit 0

# Need to download
mkdir -p "$roms_path/$system_name"
temp_file="${local_rom_path}.tmp.$$"
rclone_config="${HOME}/.var/app/net.retrodeck.retrodeck/config/retrodeck/rclone/rclone.conf"

if [[ -x "/app/bin/rclone" ]]; then
    rclone_bin="/app/bin/rclone"
elif [[ -x "${HOME}/.local/share/flatpak/app/net.retrodeck.retrodeck/current/active/files/bin/rclone" ]]; then
    rclone_bin="${HOME}/.local/share/flatpak/app/net.retrodeck.retrodeck/current/active/files/bin/rclone"
else
    rclone_bin="rclone"
fi
echo "BAWADOUNGA download"
echo "Using rclone binary: $rclone_bin"
echo "Using rclone config: $rclone_config"
echo "/$system_name/$rom_name"
"$rclone_bin" --config "$rclone_config" copyto "retrodeck-remote:/$system_name/$rom_name" "$temp_file" 2>/dev/null || \
    { rm -f "$temp_file"; echo '{"cancelLaunch": true}'; exit 1; }
echo "BAWADOUNGA download complete"

mv "$temp_file" "$local_rom_path" || \
    { rm -f "$temp_file"; echo '{"cancelLaunch": true}'; exit 1; }

# Append to gamelist.xml.local
temp_list="${gamelist_local}.tmp.$$"
head -n -1 "$gamelist_local" > "$temp_list"
echo "  <game><path>./$rom_name</path><name>${game_name:-$rom_name}</name></game>" >> "$temp_list"
echo '</gameList>' >> "$temp_list"
xmlstarlet val "$temp_list" >/dev/null 2>&1 && mv "$temp_list" "$gamelist_local"
rm -f "$temp_list"

# Launch
echo "{\"romPath\": \"$local_rom_path\"}"
exit 0
