#!/bin/bash

# ES-DE Custom Event Script
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
rclone_config="${XDG_CONFIG_HOME}/rclone/rclone.conf"
rclone_bin="/app/bin/rclone"
FIFO_PATH="${XDG_CONFIG_HOME}/ES-DE/es-de-command.fifo"

# Unescape the path (ES-DE passes shell-escaped paths with \ before spaces/special chars)
rom_path=$(echo "$rom_path" | sed 's/\\//g')
log d "ES-DE game-start event: system='$system_name', rom_path='$rom_path', game_name='$game_name'"
rom_name=$(basename "$rom_path")
local_rom_path="$roms_path/$system_name/$rom_name"
gamelist_local="${rd_home_path}/ES-DE/gamelists/${system_name}/gamelist.xml.local"
log d "Checking for local gamelist at '$gamelist_local' and game '$rom_name'"



# No local gamelist = local-only system, just launch
[[ ! -f "$gamelist_local" ]] && echo "{\"romPath\": \"$local_rom_path\"}" && exit 0

# Check if game exists in local gamelist (fast grep check)
grep -q "<path>\./${rom_name}</path>" "$gamelist_local" 2>/dev/null && \
    echo "{\"romPath\": \"$local_rom_path\"}" && exit 0

# Check if the file exists locally (Use case being the user put a rom in the folder without remote connection)
if [[ -f "$local_rom_path" ]]; then
    log i "Game '$rom_name' found at '$local_rom_path' but not in local gamelist, adding it"
    temp_list="${gamelist_local}.tmp.$$"
    head -n -1 "$gamelist_local" > "$temp_list"
    echo "  <game><path>./$rom_name</path><name>${game_name:-$rom_name}</name></game>" >> "$temp_list"
    echo '</gameList>' >> "$temp_list"
    xmlstarlet val "$temp_list" >/dev/null 2>&1 && mv "$temp_list" "$gamelist_local"
    rm -f "$temp_list"
    echo "{\"romPath\": \"$local_rom_path\"}"
    exit 0
fi

# Need to download
log i "Game '$rom_name' not found locally for system '$system_name', attempting remote download"
mkdir -p "$roms_path/$system_name"
temp_file="${local_rom_path}.tmp.$$"


# Get remote path from config for this system
remote_system_path=$(jq -r ".remote_roms.systems[\"$system_name\"].remote_path // \"$system_name\"" "$rd_conf" 2>/dev/null)
log d "Using full remote  path '$remote_system_path/$rom_name' for system '$system_name'"

"$rclone_bin" --config "$rclone_config" copyto "retrodeck-remote:/${remote_system_path}/$rom_name" "$temp_file" 2>/dev/null || \
    { rm -f "$temp_file"; echo '{"cancelLaunch": true}'; exit 1; }


mv "$temp_file" "$local_rom_path" || \
    { rm -f "$temp_file"; echo '{"cancelLaunch": true}'; exit 1; }

# Append to gamelist.xml.local
log d "Downloaded '$rom_name' to '$local_rom_path', updating local gamelist at '$gamelist_local'"
temp_list="${gamelist_local}.tmp.$$"
head -n -1 "$gamelist_local" > "$temp_list"
echo "  <game>">> "$temp_list"
echo "    <path>./$rom_name</path>">> "$temp_list"
echo "    <name>${game_name:-$rom_name}</name>">> "$temp_list"
echo "  </game>" >> "$temp_list"
echo '</gameList>' >> "$temp_list"
mv "$temp_list" "$gamelist_local"

# Launch - tell ESDE to use the local downloaded file
echo "ES-DE game-start event: system='$system_name', rom_path='$rom_path', game_name='$game_name'"

[[ -p "$FIFO_PATH" ]] && echo "ESDE:MODIFYROMPATH ::$local_rom_path" > "$FIFO_PATH"

exit 0
