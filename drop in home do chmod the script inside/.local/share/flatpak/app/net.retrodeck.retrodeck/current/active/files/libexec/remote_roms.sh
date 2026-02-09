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
readonly SLUG_MAPPINGS_FILE="$rd_core_files/reference_lists/remote_roms_slug_mappings.json"

# ============================================
# Internal Helpers
# ============================================

_compute_fingerprint() {
    # Compute sha256 fingerprint of a path (file or directory)
    # Usage: _compute_fingerprint <path>
    # For directories: fingerprints sorted filenames
    # For files: fingerprints file content
    local target_path="$1"
    
    if [[ -d "$target_path" ]]; then
        # Directory: fingerprint sorted filenames
        ls -1 "$target_path" 2>/dev/null | sort | sha256sum | cut -d' ' -f1
    elif [[ -f "$target_path" ]]; then
        # File: fingerprint content
        sha256sum "$target_path" | cut -d' ' -f1
    else
        echo ""
    fi
}

_read_fingerprint() {
    # Read stored fingerprint for a system
    local system="$1"
    local type="$2"  # "local" or "remote"
    local dir="${ESDE_GAMELIST_DIR}/${system}"
    local fp_file="${dir}/.fingerprint.${type}"
    
    if [[ -f "$fp_file" ]]; then
        cat "$fp_file"
    else
        echo ""
    fi
}

_write_fingerprint() {
    # Write fingerprint for a system
    local system="$1"
    local type="$2"  # "local" or "remote"
    local fingerprint="$3"
    local dir="${ESDE_GAMELIST_DIR}/${system}"
    
    echo "$fingerprint" > "${dir}/.fingerprint.${type}"
}

_build_local_gamelist() {
    # Build gamelist.xml.local from ROM directory listing
    local system="$1"
    local roms_dir="${roms_path}/${system}"
    local dir="${ESDE_GAMELIST_DIR}/${system}"
    local local_file="${dir}/gamelist.xml.local"
    
    log d "_build_local_gamelist: building local gamelist for system='${system}'"
    
    mkdir -p "$dir"
    
    {
        echo '<?xml version="1.0"?>'
        echo '<gameList>'
        
        if [[ -d "$roms_dir" ]]; then
            for rom in "$roms_dir"/*; do
                [[ -f "$rom" ]] || continue
                local name=$(basename "$rom")
                echo "  <game><path>./${name}</path><name>${name}</name></game>"
            done
        fi
        
        echo '</gameList>'
    } > "$local_file"
    
    log i "_build_local_gamelist: built local gamelist with $(grep -c '<game>' "$local_file" 2>/dev/null || echo 0) entries"
}

_extract_metadata() {
    # Extract metadata from gamelist.xml into pipe-separated cache for fast lookup
    # Deduplicates by path: prefers entries with MORE fields, ties go to LAST occurrence
    local system="$1"
    local dir="${ESDE_GAMELIST_DIR}/${system}"
    local gamelist="${dir}/gamelist.xml"
    local cache_file="${dir}/.metadata.cache"
    
    log d "_extract_metadata: extracting metadata for system='${system}'"
    
    [[ ! -f "$gamelist" ]] && return
    
    # Single-pass extraction: path|weight|desc|image|rating|releasedate|developer|publisher|genre|players|hidden
    # Sort by path, weight DESC - stable sort keeps last occurrence for ties
    xmlstarlet sel -t \
        -m "//game" \
        -v "path" -o "|" -v "count(*)" -o "|" \
        -v "desc" -o "|" \
        -v "image" -o "|" \
        -v "rating" -o "|" \
        -v "releasedate" -o "|" \
        -v "developer" -o "|" \
        -v "publisher" -o "|" \
        -v "genre" -o "|" \
        -v "players" -o "|" \
        -v "hidden" -n \
        "$gamelist" 2>/dev/null | \
    sort -t'|' -k1,1 -k2,2nr -s | \
    awk -F'|' '!seen[$1]++ {print $1"|"$3"|"$4"|"$5"|"$6"|"$7"|"$8"|"$9"|"$10"|"$11}' > "$cache_file"
    
    log i "_extract_metadata: cached $(wc -l < "$cache_file" 2>/dev/null || echo 0) entries for system='${system}'"
}

_inject_metadata() {
    # Inject metadata from cache file into gamelist XML using associative arrays
    local base_file="$1"
    local dir="${base_file%/*}"
    local cache_file="${dir}/.metadata.cache"
    local tmp_output=$(mktemp)
    
    # If no cache, just copy base file
    if [[ ! -s "$cache_file" ]]; then
        cat "$base_file"
        return
    fi
    
    # Build associative arrays from cache: path -> metadata field
    declare -A meta_desc meta_image meta_rating meta_releasedate meta_developer meta_publisher meta_genre meta_players meta_hidden
    local path desc image rating releasedate developer publisher genre players hidden
    
    while IFS='|' read -r path desc image rating releasedate developer publisher genre players hidden; do
        [[ -z "$path" ]] && continue
        meta_desc["$path"]="$desc"
        meta_image["$path"]="$image"
        meta_rating["$path"]="$rating"
        meta_releasedate["$path"]="$releasedate"
        meta_developer["$path"]="$developer"
        meta_publisher["$path"]="$publisher"
        meta_genre["$path"]="$genre"
        meta_players["$path"]="$players"
        meta_hidden["$path"]="$hidden"
    done < "$cache_file"
    
    # Generate output XML with inlined metadata
    {
        echo '<?xml version="1.0"?>'
        echo '<gameList>'
        
        # Process each game in base file
        xmlstarlet sel -t -m "//game" \
            -v "path" -o "|" \
            -v "name" -n \
            "$base_file" 2>/dev/null | \
        while IFS='|' read -r path name; do
            [[ -z "$path" ]] && continue
            local clean_path="${path#./}"
            [[ -z "$name" ]] && name="$clean_path"
            
            echo "  <game>"
            echo "    <path>$path</path>"
            echo "    <name>$(echo "$name" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</name>"
            [[ -n "${meta_desc[$path]}" ]] && echo "    <desc>$(echo "${meta_desc[$path]}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</desc>"
            [[ -n "${meta_image[$path]}" ]] && echo "    <image>${meta_image[$path]}</image>"
            [[ -n "${meta_rating[$path]}" ]] && echo "    <rating>${meta_rating[$path]}</rating>"
            [[ -n "${meta_releasedate[$path]}" ]] && echo "    <releasedate>${meta_releasedate[$path]}</releasedate>"
            [[ -n "${meta_developer[$path]}" ]] && echo "    <developer>$(echo "${meta_developer[$path]}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</developer>"
            [[ -n "${meta_publisher[$path]}" ]] && echo "    <publisher>$(echo "${meta_publisher[$path]}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</publisher>"
            [[ -n "${meta_genre[$path]}" ]] && echo "    <genre>$(echo "${meta_genre[$path]}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</genre>"
            [[ -n "${meta_players[$path]}" ]] && echo "    <players>${meta_players[$path]}</players>"
            [[ -n "${meta_hidden[$path]}" ]] && echo "    <hidden>${meta_hidden[$path]}</hidden>"
            echo "  </game>"
        done
        
        echo '</gameList>'
    } > "$tmp_output"
    
    if [[ -s "$tmp_output" ]]; then
        cat "$tmp_output"
    else
        cat "$base_file"
    fi
    
    rm -f "$tmp_output"
}

_merge_gamelists() {
    # Merge local + remote gamelists and inject metadata
    local system="$1"
    local include_remote="${2:-true}"
    local dir="${ESDE_GAMELIST_DIR}/${system}"
    local local_file="${dir}/gamelist.xml.local"
    local remote_file="${dir}/gamelist.xml.remote"
    local working_file="${dir}/gamelist.xml"
    local tmp="${working_file}.tmp"
    
    log d "_merge_gamelists: merging for system='${system}' include_remote='${include_remote}'"
    
    mkdir -p "$dir"
    
    # Build base gamelist (ROM entries only)
    {
        echo '<?xml version="1.0"?>'
        echo '<gameList>'
        
        # Add local entries (skip XML declaration, opening <gameList> and closing </gameList>)
        if [[ -f "$local_file" ]]; then
            tail -n +3 "$local_file" | head -n -1
        fi
        
        # Add remote entries if enabled (skip XML declaration, opening <gameList> and closing </gameList>)
        if [[ "$include_remote" == "true" && -f "$remote_file" ]]; then
            tail -n +3 "$remote_file" | head -n -1
        fi
        
        echo '</gameList>'
    } > "$tmp"
    
    # Inject metadata into final gamelist
    _inject_metadata "$tmp" > "$working_file" || mv "$tmp" "$working_file"
    
    rm -f "$tmp"
    
    log i "_merge_gamelists: merged gamelist for system='${system}'"
}

_get_config() {
    # Get value from remote_roms config
    local value
    value=$(jq -r ".remote_roms.${1}" "$rd_conf" 2>/dev/null || echo "")
    log d "_get_config: key='${1}' value='${value}'"
    echo "$value"
}

remote_roms_list_slug_languages() {
    # List available slug languages from mappings file
    # Output format: "key|description" per line
    if [[ -f "$SLUG_MAPPINGS_FILE" ]]; then
        jq -r '.slug_languages | to_entries[] | "\(.key)|\(.value.description)"' "$SLUG_MAPPINGS_FILE" 2>/dev/null
    else
        echo "retrodeck|Standard RetroDECK naming"
    fi
}

_fetch_remote_gamelist() {
    # Fetch remote gamelist.xml or build from directory. Returns 0 on success.
    local system="$1" remote_path="$2"
    local dir="${ESDE_GAMELIST_DIR}/${system}"
    local tmp="${dir}/gamelist.xml.remote.tmp.$$"
    
    # Try fetch gamelist.xml first
    if rclone --config "$REMOTE_ROMS_RCLONE_CONF" copyto "retrodeck-remote:${remote_path}/gamelist.xml" "$tmp" 2>/dev/null; then
        mv "$tmp" "${dir}/gamelist.xml.remote"
        return 0
    fi
    
    # Fallback: build from directory
    rclone --config "$REMOTE_ROMS_RCLONE_CONF" lsjson "retrodeck-remote:${remote_path}" 2>/dev/null | \
        jq -r '.[] | select(.IsDir == false) | "  <game><path>./\(.Name)</path><name>\(.Name)</name></game>"' | \
        { echo '<?xml version="1.0"?>'; echo '<gameList>'; cat; echo '</gameList>'; } > "$tmp" 2>/dev/null
    
    if [[ -s "$tmp" ]]; then
        mv "$tmp" "${dir}/gamelist.xml.remote"
        return 0
    fi
    
    rm -f "$tmp"
    return 1
}

_get_slug_mapping() {
    # Get mapped system name for a remote slug
    # Usage: _get_slug_mapping <language> <remote_slug>
    local language="$1"
    local remote_slug="$2"
    
    # RetroDECK mode: identity mapping
    if [[ "$language" == "retrodeck" || ! -f "$SLUG_MAPPINGS_FILE" ]]; then
        echo "$remote_slug"
        return
    fi
    
    # Query JSON for mapping, return empty if not found
    jq -r --arg lang "$language" --arg slug "$remote_slug" \
        '.slug_languages[$lang].mappings[$slug] // empty' \
        "$SLUG_MAPPINGS_FILE" 2>/dev/null
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
    local dir="${ESDE_GAMELIST_DIR}/${system}"
    
    log i "remote_roms_enable_system: enabling remote ROMs for system='${system}'"
    
    # Add to config
    jq ".remote_roms.systems[\"$system\"] = {remote_path: \"$remote_path\", auto_refresh: true}" \
        "$rd_conf" > "${rd_conf}.tmp" && mv "${rd_conf}.tmp" "$rd_conf" || return 1
    
    mkdir -p "$dir"
    
    # FIRST: Build local gamelist from current ROM directory
    _build_local_gamelist "$system"
    _write_fingerprint "$system" "local" "$(_compute_fingerprint "${roms_path}/${system}")"
    
    # SECOND: Extract existing metadata from gamelist.xml
    # This preserves all scraped metadata for games
    if [[ -f "${dir}/gamelist.xml" ]]; then
        log d "remote_roms_enable_system: preserving existing metadata from gamelist.xml"
        _extract_metadata "$system"
    fi
    
    # Fetch remote gamelist
    _fetch_remote_gamelist "$system" "$remote_path" || echo -e '<?xml version="1.0"?>\n<gameList>\n</gameList>' > "${dir}/gamelist.xml.remote"
    _write_fingerprint "$system" "remote" "$(_compute_fingerprint "${dir}/gamelist.xml.remote")"
    
    # Merge local + remote with metadata injection
    _merge_gamelists "$system" "true"
    
    log i "remote_roms_enable_system: system '${system}' enabled"
    [[ -p "$FIFO_PATH" ]] && echo "RESCAN" > "$FIFO_PATH"
}


# ============================================
# 4. Disable System (Remove Integration)
# ============================================

remote_roms_disable_system() {
    local system="$1"
    local dir="${ESDE_GAMELIST_DIR}/${system}"
    
    log i "remote_roms_disable_system: disabling remote ROMs for system='${system}'"
    
    _extract_metadata "$system"
    jq "del(.remote_roms.systems[\"$system\"])" "$rd_conf" > "${rd_conf}.tmp" && mv "${rd_conf}.tmp" "$rd_conf"
    
    _merge_gamelists "$system" "false"
    rm -f "${dir}/gamelist.xml.remote" "${dir}/.fingerprint.remote"
    
    log i "remote_roms_disable_system: system '${system}' disabled"
    [[ -p "$FIFO_PATH" ]] && echo "RESCAN" > "$FIFO_PATH"
}

# ============================================
# 5. Refresh ROM List
# ============================================

remote_roms_refresh_system() {
    local system="$1"
    local dir="${ESDE_GAMELIST_DIR}/${system}"
    local remote_path=$(_get_config "systems.${system}.remote_path")
    
    [[ -z "$remote_path" ]] && { log e "no remote_path for ${system}"; return 1; }
    [[ ! -f "$REMOTE_ROMS_RCLONE_CONF" ]] && { log e "no rclone config"; return 1; }
    
    log i "remote_roms_refresh_system: refreshing ${system}"
    
    _extract_metadata "$system"
    _fetch_remote_gamelist "$system" "$remote_path" || echo -e '<?xml version="1.0"?>\n<gameList>\n</gameList>' > "${dir}/gamelist.xml.remote"
    _write_fingerprint "$system" "remote" "$(_compute_fingerprint "${dir}/gamelist.xml.remote")"
    
    _build_local_gamelist "$system"
    _write_fingerprint "$system" "local" "$(_compute_fingerprint "${roms_path}/${system}")"
    
    _merge_gamelists "$system" "true"
    log i "remote_roms_refresh_system: refreshed ${system}"
    [[ -p "$FIFO_PATH" ]] && echo "RESCAN" > "$FIFO_PATH"
}

# ============================================
# 6. Auto-Discover Systems
# ============================================

remote_roms_discover_systems() {
    local custom_path="${1:-}"
    local slug_language="${2:-retrodeck}"
    
    log i "remote_roms_discover_systems: starting discovery (language: $slug_language)"
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
        log d "remote_roms_discover_systems: scanning local roms_path='${roms_path}'"
        for dir in "$roms_path"/*/; do
            [[ -d "$dir" ]] && known_systems="$known_systems $(basename "$dir")"
        done
        log d "remote_roms_discover_systems: found known systems: ${known_systems}"
    else
        log w "remote_roms_discover_systems: local roms_path does not exist: '${roms_path}'"
    fi
    
    # Build slug mapping lookup table (for non-retrodeck modes)
    declare -A slug_map
    if [[ "$slug_language" != "retrodeck" ]]; then
        log d "remote_roms_discover_systems: building slug mappings for '$slug_language'"
        while IFS='|' read -r remote_slug local_system; do
            [[ -n "$remote_slug" && -n "$local_system" ]] && slug_map["$remote_slug"]="$local_system"
        done < <(jq -r --arg lang "$slug_language" \
            '.slug_languages[$lang].mappings | to_entries[] | "\(.key)|\(.value)"' \
            "$SLUG_MAPPINGS_FILE" 2>/dev/null)
        log d "remote_roms_discover_systems: loaded ${#slug_map[@]} slug mappings"
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
    local discovered="{}"
    local dir
    local discovered_count=0
    
    log d "remote_roms_discover_systems: starting remote scan"
    
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        
        local clean_dir="${dir%|*}"
        local full_path="${dir#*|}"
        
        # Map remote slug to local system name
        local mapped_system="$clean_dir"
        if [[ "$slug_language" != "retrodeck" ]]; then
            if [[ -n "${slug_map[$clean_dir]}" ]]; then
                mapped_system="${slug_map[$clean_dir]}"
                log d "Mapped '$clean_dir' -> '$mapped_system'"
            fi
        fi
        
        # Accept mapped system (regardless of local ROM folder existence)
        # This allows remote-only systems to work
        if [[ "$mapped_system" != "$clean_dir" ]] || [[ "$known_systems" == *" $mapped_system "* ]]; then
            discovered=$(echo "$discovered" | jq --arg s "$mapped_system" --arg p "$full_path" '.[$s] = $p')
            log i "remote_roms_discover_systems: discovered '$clean_dir' -> '$mapped_system' at '$full_path'"
            ((discovered_count++))
        else
            log d "remote_roms_discover_systems: '$clean_dir' (mapped: '$mapped_system') not recognized"
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

remote_roms_startup_check() {
    # Single startup check: handles both local changes and remote refresh
    log i "remote_roms_startup_check: starting"
    local rescan_needed=false
        
    # Check all managed systems for local changes
    if [[ -d "$ESDE_GAMELIST_DIR" ]]; then
        for gamelist in "$ESDE_GAMELIST_DIR"/*/gamelist.xml; do
            [[ -f "$gamelist" ]] || continue
            local system=$(basename "$(dirname "$gamelist")")
            [[ ! -d "${roms_path}/${system}" ]] && continue
            
            local current_fp=$(_compute_fingerprint "${roms_path}/${system}")
            local stored_fp=$(_read_fingerprint "$system" "local")
            
            if [[ "$current_fp" != "$stored_fp" ]]; then
                log i "startup_check: local change detected for ${system}"
                _extract_metadata "$system"
                _build_local_gamelist "$system"
                _write_fingerprint "$system" "local" "$current_fp"
                
                if jq -e ".remote_roms.systems[\"$system\"]" "$rd_conf" >/dev/null 2>&1; then
                    _merge_gamelists "$system" "true"
                else
                    _merge_gamelists "$system" "false"
                fi
                rescan_needed=true
            fi
        done
    fi
    
    # Lightweight remote refresh for enabled systems (process substitution, not pipeline)
    if [[ -f "$REMOTE_ROMS_RCLONE_CONF" ]]; then
        local -a enabled_systems
        while IFS= read -r system; do
            [[ -n "$system" ]] && enabled_systems+=("$system")
        done < <(jq -r '.remote_roms.systems | to_entries[] | select(.value.auto_refresh == true) | .key' "$rd_conf" 2>/dev/null)
        
        for system in "${enabled_systems[@]}"; do
            local remote_path=$(_get_config "systems.${system}.remote_path")
            [[ -z "$remote_path" ]] && continue
            
            local dir="${ESDE_GAMELIST_DIR}/${system}"
            local tmp="${dir}/gamelist.xml.remote.tmp.$$"
            
            # Try fetch (best effort, silent on failure)
            rclone --config "$REMOTE_ROMS_RCLONE_CONF" copyto "retrodeck-remote:${remote_path}/gamelist.xml" "$tmp" 2>/dev/null || \
                rclone --config "$REMOTE_ROMS_RCLONE_CONF" lsjson "retrodeck-remote:${remote_path}" 2>/dev/null | \
                    jq -r '.[] | select(.IsDir == false) | "  <game><path>./\(.Name)</path><name>\(.Name)</name></game>"' | \
                    { echo '<?xml version="1.0"?>'; echo '<gameList>'; cat; echo '</gameList>'; } > "$tmp" 2>/dev/null
            
            [[ ! -s "$tmp" ]] && { rm -f "$tmp"; continue; }
            
            local new_fp=$(sha256sum "$tmp" | cut -d' ' -f1)
            local stored_fp=$(_compute_fingerprint "${dir}/gamelist.xml.remote")
            
            if [[ "$new_fp" != "$stored_fp" ]]; then
                log i "startup_check: remote updated for ${system}"
                mv "$tmp" "${dir}/gamelist.xml.remote"
                _write_fingerprint "$system" "remote" "$new_fp"
                _merge_gamelists "$system" "true"
                rescan_needed=true
            else
                rm -f "$tmp"
            fi
        done
    fi
    
    # Send single RESCAN if any changes were made
    [[ "$rescan_needed" == "true" && -p "$FIFO_PATH" ]] && echo "RESCAN" > "$FIFO_PATH"
    
    log i "remote_roms_startup_check: done"
}