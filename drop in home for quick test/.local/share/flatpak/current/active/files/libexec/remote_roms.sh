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
readonly REMOTE_ROMS_RCLONE_CONF="${XDG_CONFIG_HOME}/retrodeck/rclone/rclone.conf"
readonly ESDE_GAMELIST_DIR="${HOME}/retrodeck/ES-DE/gamelists/"
readonly ROMS_PATH="${HOME}/retrodeck/roms"


# ============================================
# Internal Helpers
# ============================================

_get_config() {
    # Get value from remote_roms config
    jq -r ".remote_roms.${1}" "$rd_conf" 2>/dev/null || echo ""
}

_set_config() {
    # Set value in remote_roms config atomically
    local key="$1" value="$2"
    jq ".remote_roms.${key} = \"$value\"" "$rd_conf" > "${rd_conf}.tmp" && \
        mv "${rd_conf}.tmp" "$rd_conf"
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
    
    mkdir -p "$dir"
    
    # Build working gamelist by concatenation
    # Structure: local entries + remote entries
    {
        # Add local entries (skip last line </gamelist>)
        [[ -f "$local_file"  ]] && head -n -1 "$local_file"
        
        # Add remote entries (skip first 2 lines <?xml> and <gameList>)
        [[ -f "$remote_file" ]] && tail -n +3 "$remote_file"

    } > "$tmp"
    
    mv "$tmp" "$working_file"
}

# ============================================
# 1. Save Connection Config
# ============================================

remote_roms_save_config() {
    local url="$1" user="$2" pass="$3" type="wevdav"
    
    # Initialize config if needed
    if ! jq -e '.remote_roms' "$rd_conf" >/dev/null 2>&1; then
        jq '. + {remote_roms: {remote_url: "", systems: {}}}' "$rd_conf" > "${rd_conf}.tmp" && \
            mv "${rd_conf}.tmp" "$rd_conf"
    fi
    
    # Save URL to JSON
    _set_config "remote_url" "$url"
    
    # Save credentials to rclone.conf
    mkdir -p "$(dirname "$REMOTE_ROMS_RCLONE_CONF")"
    {
        echo "[retrodeck-remote]"
        echo "type = $type"
        echo "url = $url"
        echo "vendor = other"
        echo "user = $user"
        echo "pass = $pass"
    } > "$REMOTE_ROMS_RCLONE_CONF"
    chmod 600 "$REMOTE_ROMS_RCLONE_CONF"
}

# ============================================
# 2. Test Connection
# ============================================

remote_roms_test_connection() {
    [[ -f "$REMOTE_ROMS_RCLONE_CONF" ]] || { echo "missing_config"; return 1; }
    
    rclone --config "$REMOTE_ROMS_RCLONE_CONF" ls "retrodeck-remote:/" --max-depth 1 --contimeout 10s --timeout 10s >/dev/null 2>&1 && \
        echo "connected" || echo "connection_failed"
}

# ============================================
# 3. Enable System (ES-DE Integration)
# ============================================

remote_roms_enable_system() {
    local system="$1" remote_path="${2:-$1}"
    
    # Add to config
    jq ".remote_roms.systems[\"$system\"] = {remote_path: \"$remote_path\", auto_refresh: true}" \
        "$rd_conf" > "${rd_conf}.tmp" && mv "${rd_conf}.tmp" "$rd_conf"
    
    # Create gamelist structure
    local dir="${ESDE_GAMELIST_DIR}/${system}"
    mkdir -p "$dir"
    
    # Ensure gamelist.xml exists (create empty if not)
    [[ -f "${dir}/gamelist.xml" ]] || \
        echo -e '<?xml version="1.0"?>\n<gameList>\n</gameList>' > "${dir}/gamelist.xml"
    
    # Copy working gamelist to local (preserves existing entries)
    cp "${dir}/gamelist.xml" "${dir}/gamelist.xml.local"
    
    # Refresh to fetch remote and rebuild working gamelist (local + remote merge)
    remote_roms_refresh_system "$system"
}

# ============================================
# 4. Disable System (Remove Integration)
# ============================================

remote_roms_disable_system() {
    local system="$1"
    local dir="${ESDE_GAMELIST_DIR}/${system}"
    
    # Remove from config
    jq "del(.remote_roms.systems[\"$system\"])" "$rd_conf" > "${rd_conf}.tmp" && \
        mv "${rd_conf}.tmp" "$rd_conf"
    
    # Copy local-only to working gamelist (removes remote entries from view)
    [[ -f "${dir}/gamelist.xml.local" ]] && \
        cp "${dir}/gamelist.xml.local" "${dir}/gamelist.xml"
    
    # Remove remote gamelist
    rm -f "${dir}/gamelist.xml.remote"
}

# ============================================
# 5. Refresh ROM List
# ============================================

remote_roms_refresh_system() {
    local system="$1"
    local dir="${ESDE_GAMELIST_DIR}/${system}"
    local remote_path=$(_get_config "systems.${system}.remote_path")
    
    [[ -z "$remote_path" ]] && return 1
    
    [[ -f "$REMOTE_ROMS_RCLONE_CONF" ]] || return 1
    
    # Try to fetch remote gamelist.xml, otherwise build from directory listing
    if ! rclone --config "$REMOTE_ROMS_RCLONE_CONF" copyto "retrodeck-remote:${remote_path}/gamelist.xml" \
              "${dir}/gamelist.xml.remote" 2>/dev/null; then
        # Build from directory listing
        rclone --config "$REMOTE_ROMS_RCLONE_CONF" lsjson "retrodeck-remote:${remote_path}" 2>/dev/null | \\
            jq -r '.[] | select(.IsDir == false) | "  <game><path>./\(.Name)</path><name>\(.Name)</name><desc>Remote ROM</desc></game>"' | \\
            { echo '<?xml version="1.0"?>'; echo '<gameList>'; cat; echo '</gameList>'; } > "${dir}/gamelist.xml.remote"
    fi
    
    # Merge local + remote into working gamelist
    _merge_gamelists "$system"
}

# ============================================
# 6. Auto-Discover Systems
# ============================================

remote_roms_discover_systems() {
    local custom_path="${1:-}"
    
    [[ -f "$REMOTE_ROMS_RCLONE_CONF" ]] && [[ -n "$ROMS_PATH" ]] || return 1
    
    # Build list of known systems from local roms folder
    local known_systems=""
    if [[ -d "$ROMS_PATH" ]]; then
        for dir in "$ROMS_PATH"/*/; do
            [[ -d "$dir" ]] && known_systems="$known_systems $(basename "$dir")"
        done
    fi
    
    # Determine which paths to scan
    local scan_paths=()
    if [[ -n "$custom_path" ]]; then
        scan_paths=("$custom_path")
    else
        scan_paths=("/" "/roms" "/games" "/library")
    fi
    
    # Scan selected paths and build discovered JSON
    # Use process substitution to avoid subshell issues with the while loop
    local discovered="{}"
    local dir
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        
        # Check if directory matches a known system
        local clean_dir="${dir%|*}"
        if [[ "$known_systems" == *" $clean_dir "* ]]; then
            # Build full path - extract path from the scan output format "dirname|full_path"
            local full_path="${dir#*|}"
            discovered=$(echo "$discovered" | jq --arg s "$clean_dir" --arg p "$full_path" '.[$s] = $p')
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
    
    echo "$discovered"
}

# ============================================
# 7. Startup Auto-Refresh
# ============================================

remote_roms_startup_refresh() {
    # Get all systems with auto_refresh enabled
    jq -r '.remote_roms.systems | to_entries[] | select(.value.auto_refresh == true) | .key' "$rd_conf" 2>/dev/null | \
    while read -r system; do
        [[ -n "$system" ]] && remote_roms_refresh_system "$system" &
    done
}