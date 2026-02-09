#!/bin/bash

# Remote ROMs Functions 
# Provides functions for managing remote ROM access and ES-DE integration
# - Save connection config (URL + credentials)
# - Test connection
# - Enable system (create gamelist structure, fetch remote list, merge with local)
# - Disable system (remove remote gamelist, revert to local-only)
# - Refresh ROM list (fetch remote gamelist or build from directory listing)
# - Auto-discover systems on remote (scan for directories, filter by known systems)
# - Startup auto-refresh for enabled systems

# ============================================
# Constants
# ============================================
readonly REMOTE_ROMS_RCLONE_CONF="${XDG_CONFIG_HOME}/rclone/rclone.conf"
readonly ESDE_GAMELIST_DIR="${rd_home_path}/ES-DE/gamelists/"
readonly FIFO_PATH="${XDG_CONFIG_HOME}/ES-DE/es-de-command.fifo"

# ============================================
# Internal Helpers
# ============================================

_get_config() {
    # Get value from remote_roms config
    local value
    value=$(jq -r ".remote_roms.${1}" "$rd_conf" 2>/dev/null || echo "")
    log d "_get_config: key='${1}' value='${value}'"
    echo "$value"
}

_set_config() {
    # Set value in remote_roms config atomically
    local key="$1" value="$2"
    log d "_set_config: setting key='${key}' value='${value}'"
    if jq ".remote_roms.${key} = \"$value\"" "$rd_conf" > "${rd_conf}.tmp" && \
        mv "${rd_conf}.tmp" "$rd_conf"; then
        log d "_set_config: successfully set key='${key}'"
    else
        log e "_set_config: failed to set key='${key}'"
        return 1
    fi
}

_merge_gamelists() {
    # Merge gamelist.local + gamelist.remote -> gamelist.xml
    # Uses fast stream concatenation (head/tail) instead of xmlstarlet for performance
    local system="$1"
    local dir="${ESDE_GAMELIST_DIR}/${system}"
    local local_file="${dir}/gamelist.xml.local"
    local remote_file="${dir}/gamelist.xml.remote"
    local working_file="${dir}/gamelist.xml"
    local tmp="${working_file}.tmp"
    
    log d "_merge_gamelists: merging gamelists for system='${system}'"
    log d "_merge_gamelists: local_file='${local_file}' remote_file='${remote_file}'"
    
    mkdir -p "$dir"
    
    # Build working gamelist by concatenation
    # Structure: local entries + remote entries
    {
        # Add local entries (skip last line </gamelist>)
        [[ -f "$local_file"  ]] && head -n -1 "$local_file"
        
        # Add remote entries (skip first 2 lines <?xml> and <gameList>)
        [[ -f "$remote_file" ]] && tail -n +3 "$remote_file"

    } > "$tmp"
    
    if mv "$tmp" "$working_file"; then
        log i "_merge_gamelists: successfully merged gamelist for system='${system}'"
    else
        log e "_merge_gamelists: failed to merge gamelist for system='${system}'"
        rm -f "$tmp"
        return 1
    fi
}

# ============================================
# 1. Save Connection Config
# ============================================

remote_roms_save_config() {
    local url="$1" user="$2" pass="$3" type="webdav"

    log i "remote_roms_save_config: saving remote ROMs configuration"
    log d "remote_roms_save_config: url='${url}' user='${user}' type='${type}'"

    # Initialize config if needed
    if ! jq -e '.remote_roms' "$rd_conf" >/dev/null 2>&1; then
        log d "remote_roms_save_config: initializing remote_roms config section"
        if jq '. + {remote_roms: {remote_url: "", systems: {}}}' "$rd_conf" > "${rd_conf}.tmp" && \
            mv "${rd_conf}.tmp" "$rd_conf"; then
            log d "remote_roms_save_config: successfully initialized config"
        else
            log e "remote_roms_save_config: failed to initialize config"
            return 1
        fi
    fi

    # Save URL to JSON
    _set_config "remote_url" "$url"

    # Obscure password using rclone (prevents casual exposure in config file)
    local obscured_pass
    obscured_pass=$(rclone obscure "$pass" 2>/dev/null) || obscured_pass="$pass"
    log d "remote_roms_save_config: password obscured successfully"

    # Save credentials to rclone.conf
    mkdir -p "$(dirname "$REMOTE_ROMS_RCLONE_CONF")"
    {
        echo "[retrodeck-remote]"
        echo "type = $type"
        echo "url = $url"
        echo "vendor = other"
        echo "user = $user"
        echo "pass = $obscured_pass"
    } > "$REMOTE_ROMS_RCLONE_CONF"
    chmod 600 "$REMOTE_ROMS_RCLONE_CONF"
    log i "remote_roms_save_config: rclone configuration saved to '${REMOTE_ROMS_RCLONE_CONF}'"
}

# ============================================
# 2. Test Connection
# ============================================

remote_roms_test_connection() {
    log d "remote_roms_test_connection: testing connection to remote"
    
    if [[ ! -f "$REMOTE_ROMS_RCLONE_CONF" ]]; then
        log w "remote_roms_test_connection: rclone config missing at '${REMOTE_ROMS_RCLONE_CONF}'"
        echo "missing_config"
        return 1
    fi
    
    log d "remote_roms_test_connection: attempting to list remote root directory"
    if rclone --config "$REMOTE_ROMS_RCLONE_CONF" ls "retrodeck-remote:/" --max-depth 1 --contimeout 10s --timeout 10s >/dev/null 2>&1; then
        log i "remote_roms_test_connection: connection successful"
        echo "connected"
    else
        log e "remote_roms_test_connection: connection failed"
        echo "connection_failed"
        return 1
    fi
}

# ============================================
# 3. Enable System (ES-DE Integration)
# ============================================

remote_roms_enable_system() {
    local system="$1" remote_path="${2:-$1}"
    
    log i "remote_roms_enable_system: enabling remote ROMs for system='${system}'"
    log d "remote_roms_enable_system: remote_path='${remote_path}'"
    
    # Add to config
    if jq ".remote_roms.systems[\"$system\"] = {remote_path: \"$remote_path\", auto_refresh: true}" \
        "$rd_conf" > "${rd_conf}.tmp" && mv "${rd_conf}.tmp" "$rd_conf"; then
        log d "remote_roms_enable_system: system added to config"
    else
        log e "remote_roms_enable_system: failed to add system to config"
        return 1
    fi
    
    # Create gamelist structure
    local dir="${ESDE_GAMELIST_DIR}/${system}"
    mkdir -p "$dir"
    log d "remote_roms_enable_system: created gamelist directory '${dir}'"
    
    # Ensure gamelist.xml exists (create empty if not)
    if [[ ! -f "${dir}/gamelist.xml" ]]; then
        echo -e '<?xml version="1.0"?>\n<gameList>\n</gameList>' > "${dir}/gamelist.xml"
        log d "remote_roms_enable_system: created empty gamelist.xml"
    fi
    
    # Copy working gamelist to local (preserves existing entries)
    if cp "${dir}/gamelist.xml" "${dir}/gamelist.xml.local"; then
        log i "remote_roms_enable_system: system '${system}' enabled successfully"
    else
        log e "remote_roms_enable_system: failed to copy gamelist to local"
        return 1
    fi

    if [ -p "$FIFO_PATH" ]; then
        echo "RESCAN" > "$FIFO_PATH"
        log i "ES-DE rescan triggered after disabling system '${system}'"
    else
        log w "ES-DE not running (FIFO not found), rescan not triggered"
    fi

}

# ============================================
# 4. Disable System (Remove Integration)
# ============================================

remote_roms_disable_system() {
    local system="$1"
    local dir="${ESDE_GAMELIST_DIR}/${system}"
    
    log i "remote_roms_disable_system: disabling remote ROMs for system='${system}'"
    
    # Remove from config
    if jq "del(.remote_roms.systems[\"$system\"])" "$rd_conf" > "${rd_conf}.tmp" && \
        mv "${rd_conf}.tmp" "$rd_conf"; then
        log d "remote_roms_disable_system: removed system from config"
    else
        log w "remote_roms_disable_system: failed to remove system from config"
    fi
    
    # Copy local-only to working gamelist (removes remote entries from view)
    if [[ -f "${dir}/gamelist.xml.local" ]]; then
        if cp "${dir}/gamelist.xml.local" "${dir}/gamelist.xml"; then
            log d "remote_roms_disable_system: restored local gamelist"
        else
            log w "remote_roms_disable_system: failed to restore local gamelist"
        fi
    fi
    
    # Remove remote gamelist
    if rm -f "${dir}/gamelist.xml.remote"; then
        log d "remote_roms_disable_system: removed remote gamelist"
    fi

    # Remove local gamelist (will be recreated fresh on next enable)
    if rm -f "${dir}/gamelist.xml.local"; then
        log d "remote_roms_disable_system: removed local gamelist"
    fi

    log i "remote_roms_disable_system: system '${system}' disabled successfully"

    if [ -p "$FIFO_PATH" ]; then
        echo "RESCAN" > "$FIFO_PATH"
        log i "ES-DE rescan triggered after disabling system '${system}'"
    else
        log w "ES-DE not running (FIFO not found), rescan not triggered"
    fi
}

# ============================================
# 5. Refresh ROM List
# ============================================

remote_roms_refresh_system() {
    local system="$1"
    local dir="${ESDE_GAMELIST_DIR}/${system}"
    local remote_path=$(_get_config "systems.${system}.remote_path")

    log i "remote_roms_refresh_system: refreshing ROM list for system='${system}'"
    
    if [[ -z "$remote_path" ]]; then
        log e "remote_roms_refresh_system: no remote_path configured for system='${system}'"
        return 1
    fi
    
    if [[ ! -f "$REMOTE_ROMS_RCLONE_CONF" ]]; then
        log e "remote_roms_refresh_system: rclone config missing at '${REMOTE_ROMS_RCLONE_CONF}'"
        return 1
    fi
    
    log d "remote_roms_refresh_system: remote_path='${remote_path}'"
    
    remote_roms_disable_system "$system" # Clear existing remote entries before refresh
    remote_roms_enable_system "$system" "$remote_path" # Re-enable to recreate structure

    # Try to fetch remote gamelist.xml, otherwise build from directory listing
    log d "remote_roms_refresh_system: attempting to fetch remote gamelist.xml"
    if rclone --config "$REMOTE_ROMS_RCLONE_CONF" copyto "retrodeck-remote:${remote_path}/gamelist.xml" \
              "${dir}/gamelist.xml.remote" 2>/dev/null; then
        log i "remote_roms_refresh_system: fetched remote gamelist.xml"
    else
        log d "remote_roms_refresh_system: no remote gamelist.xml found, building from directory listing"
        if rclone --config "$REMOTE_ROMS_RCLONE_CONF" lsjson "retrodeck-remote:${remote_path}" 2>/dev/null | \
            jq -r '.[] | select(.IsDir == false) | "  <game><path>./\(.Name)</path><name>\(.Name)</name><desc>Remote ROM</desc></game>"' | \
            { echo '<?xml version="1.0"?>'; echo '<gameList>'; cat; echo '</gameList>'; } > "${dir}/gamelist.xml.remote"; then
            log i "remote_roms_refresh_system: built gamelist from directory listing"
        else
            log w "remote_roms_refresh_system: failed to build gamelist from directory listing"
        fi
    fi
    
    # Merge local + remote into working gamelist
    if _merge_gamelists "$system"; then
        log i "remote_roms_refresh_system: successfully refreshed ROM list for system='${system}'"
    else
        log e "remote_roms_refresh_system: failed to merge gamelists for system='${system}'"
        return 1
    fi
}

# ============================================
# 6. Auto-Discover Systems
# ============================================

remote_roms_discover_systems() {
    local custom_path="${1:-}"
    
    log i "remote_roms_discover_systems: starting system discovery"
    log d "remote_roms_discover_systems: custom_path='${custom_path}'"
    
    if [[ ! -f "$REMOTE_ROMS_RCLONE_CONF" ]]; then
        log e "remote_roms_discover_systems: rclone config missing at '${REMOTE_ROMS_RCLONE_CONF}'"
        return 1
    fi
    
    if [[ -z "$roms_path" ]]; then
        log e "remote_roms_discover_systems: roms_path is not set"
        return 1
    fi
    
    # Build list of known systems from local roms folder
    local known_systems=""
    if [[ -d "$roms_path" ]]; then
        log d "remote_roms_discover_systems: scanning local roms_path='${roms_path}' for known systems"
        for dir in "$roms_path"/*/; do
            [[ -d "$dir" ]] && known_systems="$known_systems $(basename "$dir")"
        done
        log d "remote_roms_discover_systems: found known systems: ${known_systems}"
    else
        log w "remote_roms_discover_systems: local roms_path does not exist: '${roms_path}'"
    fi
    
    # Determine which paths to scan
    local scan_paths=()
    if [[ -n "$custom_path" ]]; then
        scan_paths=("$custom_path")
        log d "remote_roms_discover_systems: using custom scan path: '${custom_path}'"
    else
        scan_paths=("/" "/roms" "/games" "/library")
        log d "remote_roms_discover_systems: using default scan paths"
    fi
    
    # Scan selected paths and build discovered JSON
    # Use process substitution to avoid subshell issues with the while loop
    local discovered="{}"
    local dir
    local discovered_count=0
    
    log d "remote_roms_discover_systems: starting remote scan"
    
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        
        # Check if directory matches a known system
        local clean_dir="${dir%|*}"
        if [[ "$known_systems" == *" $clean_dir "* ]]; then
            # Build full path - extract path from the scan output format "dirname|full_path"
            local full_path="${dir#*|}"
            discovered=$(echo "$discovered" | jq --arg s "$clean_dir" --arg p "$full_path" '.[$s] = $p')
            log d "remote_roms_discover_systems: discovered system '${clean_dir}' at path '${full_path}'"
            ((discovered_count++))
        fi
    done < <(
        # List directories from all scan paths
        for scan_path in "${scan_paths[@]}"; do
            local rclone_path="$scan_path"
            [[ "$scan_path" != "/" ]] && rclone_path="${scan_path#/}"
            rclone --config "$REMOTE_ROMS_RCLONE_CONF" lsf "retrodeck-remote:/$rclone_path" \
                --max-depth 1 --dirs-only 2>/dev/null | \
                sed 's|/$||' | \
                while read -r folder; do
                    [[ -n "$folder" ]] && echo "$folder|$scan_path/$folder"
                done
        done
    )
    
    log i "remote_roms_discover_systems: discovered ${discovered_count} systems"
    echo "$discovered"
}

# ============================================
# 7. Startup Auto-Refresh
# ============================================

remote_roms_startup_refresh() {
    log i "remote_roms_startup_refresh: starting auto-refresh for enabled systems"
    
    # Get all systems with auto_refresh enabled
    local systems_to_refresh
    systems_to_refresh=$(jq -r '.remote_roms.systems | to_entries[] | select(.value.auto_refresh == true) | .key' "$rd_conf" 2>/dev/null)
    
    if [[ -z "$systems_to_refresh" ]]; then
        log d "remote_roms_startup_refresh: no systems with auto_refresh enabled"
        return 0
    fi
    
    local count=0
    while read -r system; do
        if [[ -n "$system" ]]; then
            log d "remote_roms_startup_refresh: queueing refresh for system='${system}'"
            remote_roms_refresh_system "$system" &
            ((count++))
        fi
    done <<< "$systems_to_refresh"
    
    log i "remote_roms_startup_refresh: queued ${count} systems for refresh"
}