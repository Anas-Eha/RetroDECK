#!/bin/bash

# Remote ROMs Functions 
# Provides functions for managing remote ROM access and ES-DE integration
#
# ARCHITECTURE OVERVIEW:
#   3-Layer Persistence: local ROMs + remote ROMs → merged gamelist.xml
#   Metadata Cache: .rd_internal.metadata preserves scraped data across merges
#
# KEY FILES PER SYSTEM (in <rd_home_path>/ES-DE/gamelists/<system>):
#   gamelist.xml.local   - Generated from local ROM directory (ephemeral)
#   gamelist.xml.remote  - Fetched from remote server (ephemeral)
#   gamelist.xml         - Final merged file ES-DE reads (regenerated)
#   .rd_internal.metadata - Pipe-separated metadata cache (preserved)
#   .fingerprint.{local,remote} - Change detection hashes
#
# MERGE FLOW:
#   1. _extract_metadata() → Save metadata from current gamelist.xml to cache
#   2. Rebuild local/remote gamelist files (ROM lists only, no metadata)
#   3. _merge_gamelists() → Combine ROM lists
#   4. _inject_metadata() → Re-apply cached metadata to final gamelist.xml

# ============================================
# Constants
# ============================================
readonly REMOTE_ROMS_RCLONE_CONF="${XDG_CONFIG_HOME}/rclone/rclone.conf"
readonly FIFO_PATH="${XDG_CONFIG_HOME}/ES-DE/es-de-command.fifo"
readonly SLUG_MAPPINGS_FILE="$rd_core_files/reference_lists/remote_roms_slug_mappings.json"

# ============================================
# Internal Helpers
# ============================================

_xml_escape() {
    # Escape XML special characters: &, <, >, "
    # Usage: _xml_escape "string"
    # Returns: XML-escaped string on stdout
    local str="$1"
    str="${str//&/&amp;}"
    str="${str//</&lt;}"
    str="${str//>/&gt;}"
    str="${str//\"/&quot;}"
    printf '%s' "$str"
}

_compute_fingerprint() {
    # Compute sha256 fingerprint of a path (file or directory)
    # Usage: _compute_fingerprint <path>
    # Returns: sha256 hash string (or empty string if path doesn't exist)
    # For directories: fingerprints sorted filenames (excluding '.remote' subdirectory)
    # For files: fingerprints file content
    local target_path="$1"
    
    if [[ -d "$target_path" ]]; then
        # Directory: fingerprint sorted filenames, excluding '.remote' subdirectory
        ls -1 "$target_path" 2>/dev/null | grep -v '^\.remote$' | sort | sha256sum | cut -d' ' -f1
    elif [[ -f "$target_path" ]]; then
        # File: fingerprint content
        sha256sum "$target_path" | cut -d' ' -f1
    else
        echo ""
    fi
}

_read_fingerprint() {
    # Read stored fingerprint for a system
    # Usage: _read_fingerprint <system> <type>
    # Args:
    #   system: System name (e.g., "snes", "psx")
    #   type: "local" or "remote"
    # Returns: Stored fingerprint hash (or empty string if not found)
    local system="$1"
    local type="$2"
    local dir="${rd_home_path}/ES-DE/gamelists/${system}"
    local fp_file="${dir}/.fingerprint.${type}"
    
    if [[ -f "$fp_file" ]]; then
        cat "$fp_file"
    else
        echo ""
    fi
}

_write_fingerprint() {
    # Write fingerprint for a system
    # Usage: _write_fingerprint <system> <type> <fingerprint>
    # Args:
    #   system: System name (e.g., "snes")
    #   type: "local" or "remote"
    #   fingerprint: The hash to store
    local system="$1"
    local type="$2"
    local fingerprint="$3"
    local dir="${rd_home_path}/ES-DE/gamelists/${system}"
    
    # Use printf to avoid trailing newline
    printf '%s' "$fingerprint" > "${dir}/.fingerprint.${type}"
}

_build_local_gamelist() {
    # Build gamelist.xml.local from ROM directory listing
    # Usage: _build_local_gamelist <system>
    # Args:
    #   system: System name (e.g., "snes")
    # Side effects: Creates gamelist.xml.local file
    local system="$1"
    local roms_dir="${roms_path}/${system}"
    local dir="${rd_home_path}/ES-DE/gamelists/${system}"
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
                # Skip system info files that aren't ROMs
                [[ "$name" == "systeminfo.txt" ]] && continue
                local safe_name=$(_xml_escape "$name")
                echo "  <game>"
                echo "    <path>./${safe_name}</path>"
                echo "    <name>${safe_name}</name>"
                echo "  </game>"
            done
        fi
        
        echo '</gameList>'
    } > "$local_file"
    
    log i "_build_local_gamelist: built local gamelist with $(grep -c '<game>' "$local_file" 2>/dev/null || echo 0) entries"
}

_extract_metadata() {
    # Extract metadata from gamelist.xml into cache file
    # Usage: _extract_metadata <system>
    # Args:
    #   system: System name (e.g., "snes")
    # Side effects: Creates/updates .rd_internal.metadata cache file
    # Note: Normalizes paths (./.remote/file -> ./file) for cache keys
    #
    # DEDUPLICATION STRATEGY:
    #   - weight = count of non-empty metadata fields (more fields = richer entry)
    #   - Prefer richer entries when duplicates exist
    #   - Ties broken by last occurrence (stable sort -s)
    #
    # PATH NORMALIZATION:
    #   - ./.remote/filename -> ./filename (remote ROMs treated same as local)
    #   - Ensures metadata persists regardless of ROM location
    #
    # CACHE FORMAT: path|desc|image|rating|releasedate|developer|publisher|genre|players|hidden
    # Using pipes (not XML) enables O(1) hashmap lookups in _inject_metadata()
    local system="$1"
    local dir="${rd_home_path}/ES-DE/gamelists/${system}"
    local gamelist="${dir}/gamelist.xml"
    local cache_file="${dir}/.rd_internal.metadata"
    local cache_tmp="${cache_file}.tmp.$$"
    local stderr_file="${cache_file}.err.$$"
    
    log d "_extract_metadata: extracting metadata for system='${system}'"
    
    [[ ! -f "$gamelist" ]] && return
    
    # PIPELINE EXPLAINED:
    # 1. xmlstarlet: Extract fields with tab delimiters, handle missing fields gracefully
    # 2. awk: Normalize path, calculate weight from non-empty fields, convert to pipe-delimited
    # 3. sort -S 10%: Limit sort memory to 10% RAM (8GB safe), spill to disk if needed
    # 4. sort -t'|' -k1,1 -k2,2nr -s: Sort by path, then weight DESC, stable for tie-breaking
    # 5. awk '!seen[$1]++': Keep first occurrence per path (after sort = richest wins)
    # Note: Using $'\t' to output actual tab characters, not literal "\t" strings
    if xmlstarlet sel -t \
        -m "//game" \
        -v "path" -o $'\t' \
        -v "desc" -o $'\t' \
        -v "image" -o $'\t' \
        -v "rating" -o $'\t' \
        -v "releasedate" -o $'\t' \
        -v "developer" -o $'\t' \
        -v "publisher" -o $'\t' \
        -v "genre" -o $'\t' \
        -v "players" -o $'\t' \
        -v "hidden" -n \
        "$gamelist" 2>"$stderr_file" | \
    awk -F'\t' '{
        # Normalize path: ./.remote/filename -> ./filename
        path = $1
        if (path ~ /^\.\/\.remote\//) {
            sub(/^\.\/\.remote\//, "./", path)
        }
        # Calculate weight = count of non-empty metadata fields (columns 2-10)
        weight = 0
        for(i=2; i<=10; i++) if($i != "") weight++
        # Output pipe-delimited: path|weight|desc|image|rating|releasedate|developer|publisher|genre|players|hidden
        print path "|" weight "|" $2 "|" $3 "|" $4 "|" $5 "|" $6 "|" $7 "|" $8 "|" $9 "|" $10
    }' | \
    sort -S 10% -t'|' -k1,1 -k2,2nr -s 2>/dev/null | \
    awk -F'|' '!seen[$1]++ {print $1"|"$3"|"$4"|"$5"|"$6"|"$7"|"$8"|"$9"|"$10"|"$11}' > "$cache_tmp" && \
    [[ -s "$cache_tmp" ]]; then
        # Atomic write with file lock to prevent race conditions
        (
            flock -x 200 || exit 1
            mv "$cache_tmp" "$cache_file"
        ) 200>"${cache_file}.lock"
        rm -f "$stderr_file"
        log i "_extract_metadata: cached $(wc -l < "$cache_file" 2>/dev/null || echo 0) entries for system='${system}'"
    else
        rm -f "$cache_tmp"
        log w "_extract_metadata: extraction failed or empty, preserving existing cache for system='${system}'"
        if [[ -s "$stderr_file" ]]; then
            log e "_extract_metadata: xmlstarlet error: $(head -1 "$stderr_file")"
        fi
        rm -f "$stderr_file"
    fi
}

_inject_metadata() {
    # Inject cached metadata into base gamelist file using awk for efficiency
    # Usage: _inject_metadata <base_file>
    # Args:
    #   base_file: Path to gamelist file to enrich (e.g., gamelist.xml.tmp)
    # Returns: Enriched XML on stdout
    #
    # PERFORMANCE: O(n) single-pass. Awk handles large caches better than bash.
    # Tradeoff: Simple awk, no complex packing/unpacking logic
    local base_file="$1"
    local dir="${base_file%/*}"
    local cache_file="${dir}/.rd_internal.metadata"
    
    # No cache? Just passthrough
    [[ ! -s "$cache_file" ]] && { cat "$base_file"; return; }
    
    # Preprocess: convert cache to awk-friendly "path KEY value" format
    # This avoids complex parsing in awk - simple key=value lookup
    local keyfile
    keyfile=$(mktemp)
    while IFS='|' read -r p d i r rd de pu g pl h; do
        [[ -z "$p" ]] && continue
        # Output: path<TAB>field<TAB>value for each non-empty field
        # Note: weight field was already dropped in _extract_metadata, cache has 10 fields
        [[ -n "$d" ]] && printf '%s\tdesc\t%s\n' "$p" "$d"
        [[ -n "$i" ]] && printf '%s\timage\t%s\n' "$p" "$i"
        [[ -n "$r" ]] && printf '%s\trating\t%s\n' "$p" "$r"
        [[ -n "$rd" ]] && printf '%s\treleasedate\t%s\n' "$p" "$rd"
        [[ -n "$de" ]] && printf '%s\tdeveloper\t%s\n' "$p" "$de"
        [[ -n "$pu" ]] && printf '%s\tpublisher\t%s\n' "$p" "$pu"
        [[ -n "$g" ]] && printf '%s\tgenre\t%s\n' "$p" "$g"
        [[ -n "$pl" ]] && printf '%s\tplayers\t%s\n' "$p" "$pl"
        [[ -n "$h" ]] && printf '%s\thidden\t%s\n' "$p" "$h"
    done < "$cache_file" > "$keyfile"
    
    # If preprocessing produced nothing, passthrough
    [[ ! -s "$keyfile" ]] && { rm -f "$keyfile"; cat "$base_file"; return; }
    
    # Awk: load keyfile, then process XML
    awk -F'\t' '
        # First file: build lookup table path,field -> value
        NF==3 { cache[$1","$2] = $3; next }
        
        # Second file: process XML
        FNR==1 { print "<?xml version=\"1.0\"?>"; print "<gameList>"; next }
        
        /<game>/ {
            in_game = 1
            g_path = ""; g_key = ""
            has_desc = 0; has_image = 0; has_rating = 0
            has_releasedate = 0; has_developer = 0; has_publisher = 0
            has_genre = 0; has_players = 0; has_hidden = 0
            print "  <game>"
            next
        }
        
        /<\/game>/ {
            # Inject missing fields from cache
            if (g_key != "") {
                if (!has_desc && (g_key",desc" in cache)) 
                    print "    <desc>" xml_esc(cache[g_key",desc"]) "</desc>"
                if (!has_image && (g_key",image" in cache)) 
                    print "    <image>" cache[g_key",image"] "</image>"
                if (!has_rating && (g_key",rating" in cache)) 
                    print "    <rating>" cache[g_key",rating"] "</rating>"
                if (!has_releasedate && (g_key",releasedate" in cache)) 
                    print "    <releasedate>" cache[g_key",releasedate"] "</releasedate>"
                if (!has_developer && (g_key",developer" in cache)) 
                    print "    <developer>" xml_esc(cache[g_key",developer"]) "</developer>"
                if (!has_publisher && (g_key",publisher" in cache)) 
                    print "    <publisher>" xml_esc(cache[g_key",publisher"]) "</publisher>"
                if (!has_genre && (g_key",genre" in cache)) 
                    print "    <genre>" xml_esc(cache[g_key",genre"]) "</genre>"
                if (!has_players && (g_key",players" in cache)) 
                    print "    <players>" cache[g_key",players"] "</players>"
                if (!has_hidden && (g_key",hidden" in cache)) 
                    print "    <hidden>" cache[g_key",hidden"] "</hidden>"
            }
            print "  </game>"
            in_game = 0
            next
        }
        
        in_game {
            # Track fields we already have
            if ($0 ~ /<desc>/) { has_desc = 1 }
            else if ($0 ~ /<image>/) { has_image = 1 }
            else if ($0 ~ /<rating>/) { has_rating = 1 }
            else if ($0 ~ /<releasedate>/) { has_releasedate = 1 }
            else if ($0 ~ /<developer>/) { has_developer = 1 }
            else if ($0 ~ /<publisher>/) { has_publisher = 1 }
            else if ($0 ~ /<genre>/) { has_genre = 1 }
            else if ($0 ~ /<players>/) { has_players = 1 }
            else if ($0 ~ /<hidden>/) { has_hidden = 1 }
            else if ($0 ~ /<path>/) {
                # Extract path and normalize key for lookup
                match($0, /<path>([^<]+)<\/path>/, m)
                g_path = m[1]
                g_key = g_path
                # Normalize: ./.remote/file -> ./file
                if (g_key ~ /^\.\/\.remote\//) sub(/^\.\/\.remote\//, "./", g_key)
            }
            # Output the original line (passthrough)
            print
            next
        }
        
        END { print "</gameList>" }
        
        function xml_esc(s) {
            gsub(/&/, "\&amp;", s)
            gsub(/</, "\&lt;", s)
            gsub(/>/, "\&gt;", s)
            gsub(/"/, "\&quot;", s)
            return s
        }
    ' "$keyfile" "$base_file"
    
    rm -f "$keyfile"
}

_merge_gamelists() {
    # Merge local + remote gamelists and inject metadata
    # Usage: _merge_gamelists <system> [include_remote]
    # Args:
    #   system: System name (e.g., "snes")
    #   include_remote: "true" (default) or "false" - whether to include remote ROMs
    # Side effects: Creates final gamelist.xml
    # Note: Uses file locking to prevent race conditions during concurrent operations
    local system="$1"
    local include_remote="${2:-true}"
    local dir="${rd_home_path}/ES-DE/gamelists/${system}"
    local local_file="${dir}/gamelist.xml.local"
    local remote_file="${dir}/gamelist.xml.remote"
    local working_file="${dir}/gamelist.xml"
    local tmp="${working_file}.tmp.$$"
    local lock_file="${dir}/.gamelist.lock"
    
    log d "_merge_gamelists: merging for system='${system}' include_remote='${include_remote}'"
    
    mkdir -p "$dir"
    
    # Concatenate ROM lists (strip XML headers/footers, re-add wrapper)
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
    
    # Validate tmp file was created successfully
    if [[ ! -s "$tmp" ]]; then
        log e "_merge_gamelists: failed to create merge temp file for system='${system}'"
        rm -f "$tmp"
        return 1
    fi
    
    # Inject metadata into final gamelist with file locking (prevents race conditions)
    (
        flock -x 200 || { log e "_merge_gamelists: could not acquire lock for ${system}"; exit 1; }
        
        if ! _inject_metadata "$tmp" > "$working_file" 2>/dev/null; then
            log w "_merge_gamelists: metadata injection failed, using un-enriched gamelist"
            cp "$tmp" "$working_file"
        fi
        
        # Verify output
        if [[ ! -s "$working_file" ]]; then
            log e "_merge_gamelists: gamelist.xml is empty after merge, restoring from temp"
            cp "$tmp" "$working_file"
        fi
    ) 200>"$lock_file"
    
    rm -f "$tmp"
    
    log i "_merge_gamelists: merged gamelist for system='${system}'"
}

_get_config() {
    # Get value from remote_roms config
    # Usage: _get_config <key>
    # Args:
    #   key: JSON path (e.g., "systems.snes.remote_path")
    # Returns: Value on stdout (or empty string if not found)
    local value
    value=$(jq -r ".remote_roms.${1}" "$rd_conf" 2>/dev/null || echo "")
    log d "_get_config: key='${1}' value='${value}'"
    echo "$value"
}

remote_roms_list_slug_languages() {
    # List available slug languages from mappings file
    # Usage: remote_roms_list_slug_languages
    # Returns: "key|description" pairs, one per line on stdout
    if [[ -f "$SLUG_MAPPINGS_FILE" ]]; then
        jq -r '.slug_languages | to_entries[] | "\(.key)|\(.value.description)"' "$SLUG_MAPPINGS_FILE" 2>/dev/null
    else
        echo "retrodeck|Standard RetroDECK naming"
    fi
}

_fetch_remote_gamelist() {
    # Fetch remote gamelist.xml or build from directory
    # Usage: _fetch_remote_gamelist <system> <remote_path>
    # Args:
    #   system: System name (e.g., "snes")
    #   remote_path: Path on remote server (e.g., "/roms/snes")
    # Returns: 0 on success, 1 on failure
    # Side effects: Creates gamelist.xml.remote file
    local system="$1" remote_path="$2"
    local dir="${rd_home_path}/ES-DE/gamelists/${system}"
    local tmp="${dir}/gamelist.xml.remote.tmp.$$"
    
    # Try fetch gamelist.xml first - modify paths to include .remote/ prefix
    if rclone --config "$REMOTE_ROMS_RCLONE_CONF" copyto "retrodeck-remote:${remote_path}/gamelist.xml" "$tmp" 2>/dev/null; then
        # Transform paths to include .remote/ subdirectory prefix
        sed 's|<path>\./|<path>./.remote/|g' "$tmp" > "${tmp}.transformed" && mv "${tmp}.transformed" "${dir}/gamelist.xml.remote"
        rm -f "$tmp"
        return 0
    fi
    
    # Fallback: build from directory - paths include .remote/ prefix
    rclone --config "$REMOTE_ROMS_RCLONE_CONF" lsjson "retrodeck-remote:${remote_path}" 2>/dev/null | \
        jq -r '.[] | select(.IsDir == false) | "  <game><path>./.remote/\(.Name | @html)</path><name>\(.Name | @html)</name></game>"' | \
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
    # Args:
    #   language: Slug language key (e.g., "retrodeck", "batocera")
    #   remote_slug: Remote folder name (e.g., "supernes")
    # Returns: Mapped local system name on stdout (or original slug if no mapping)
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
    # Usage: _set_config <key> <value>
    # Args:
    #   key: JSON path (e.g., "remote_url")
    #   value: Value to set
    # Returns: 0 on success, 1 on failure
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
    # Save remote ROMs connection configuration
    # Usage: remote_roms_save_config <url> <user> <pass>
    # Args:
    #   url: WebDAV server URL
    #   user: Username for authentication
    #   pass: Password for authentication
    # Side effects: Updates rd_conf and rclone.conf
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
    # Test connection to remote WebDAV server
    # Usage: remote_roms_test_connection
    # Returns: "connected", "missing_config", or "connection_failed" on stdout
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
    # Enable remote ROMs for a system
    # Usage: remote_roms_enable_system <system> [remote_path]
    # Args:
    #   system: System name (e.g., "snes")
    #   remote_path: Optional path on remote (defaults to system name)
    # Side effects: Updates config, fetches remote gamelist, merges gamelists
    local system="$1" remote_path="${2:-$1}"
    local dir="${rd_home_path}/ES-DE/gamelists/${system}"
    
    log i "remote_roms_enable_system: enabling remote ROMs for system='${system}'"
    
    # Add to config
    jq ".remote_roms.systems[\"$system\"] = {remote_path: \"$remote_path\", auto_refresh: false}" \
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
    [[ -p "$FIFO_PATH" ]] && echo "ESDE:RESCAN" > "$FIFO_PATH"
}


# ============================================
# 4. Disable System (Remove Integration)
# ============================================

remote_roms_disable_system() {
    # Disable remote ROMs for a system
    # Usage: remote_roms_disable_system <system>
    # Args:
    #   system: System name to disable
    # Side effects: Removes from config, rebuilds gamelist without remote
    local system="$1"
    local dir="${rd_home_path}/ES-DE/gamelists/${system}"
    
    log i "remote_roms_disable_system: disabling remote ROMs for system='${system}'"
    
    _extract_metadata "$system"
    jq "del(.remote_roms.systems[\"$system\"])" "$rd_conf" > "${rd_conf}.tmp" && mv "${rd_conf}.tmp" "$rd_conf"
    
    _merge_gamelists "$system" "false"
    rm -f "${dir}/gamelist.xml.remote" "${dir}/.fingerprint.remote"
    
    log i "remote_roms_disable_system: system '${system}' disabled"
    [[ -p "$FIFO_PATH" ]] && echo "ESDE:RESCAN" > "$FIFO_PATH"
}

# ============================================
# 5. Refresh ROM List
# ============================================

remote_roms_refresh_system() {
    # Manually refresh remote ROM list for a system
    # Usage: remote_roms_refresh_system <system>
    # Args:
    #   system: System name to refresh
    # Side effects: Re-fetches remote gamelist, rebuilds merged gamelist
    local system="$1"
    local dir="${rd_home_path}/ES-DE/gamelists/${system}"
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
    [[ -p "$FIFO_PATH" ]] && echo "ESDE:RESCAN" > "$FIFO_PATH"
}

# ============================================
# 6. Auto-Discover Systems
# ============================================

remote_roms_discover_systems() {
    # Auto-discover systems from remote server
    # Usage: remote_roms_discover_systems [custom_path] [slug_language]
    # Args:
    #   custom_path: Optional specific path to scan on remote
    #   slug_language: Language for folder name mapping (default: "retrodeck")
    # Returns: JSON object of discovered systems on stdout
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
    # Startup check: detects local/remote changes and rebuilds gamelists as needed
    # Usage: remote_roms_startup_check
    # Side effects: May rebuild gamelists and trigger ESDE:RESCAN
    # Note: Called during RetroDECK startup for all enabled systems
    log i "remote_roms_startup_check: starting"
    local rescan_needed=false
    local -a systems_to_check=()
    
    # Build list of systems to check for local changes:
    # 1. Systems with ROM folders in roms_path (primary source)
    # 2. Systems with existing gamelist.xml files (catches empty ROM folders)
    # 3. Systems configured for remote_roms (remote-only systems)
    
    # 1. Scan roms_path for system folders (primary source of truth)
    if [[ -d "$roms_path" ]]; then
        for system_dir in "$roms_path"/*/; do
            [[ -d "$system_dir" ]] || continue
            local system=$(basename "$system_dir")
            systems_to_check+=("$system")
        done
    fi
    
    # Check all identified systems for local changes
    for system in "${systems_to_check[@]}"; do
        [[ ! -d "${roms_path}/${system}" ]] && continue
        
        # Skip empty ROM folders (no files, or only .remote subdirectory)
        # Exclude systeminfo.txt and .directory from count to match fingerprinting logic
        local rom_count=$(find "${roms_path}/${system}" \
            -maxdepth 1 \
            -type f \
            ! -name '.*' \
            ! -name '*.txt' \
            2>/dev/null | wc -l
        )
        [[ "$rom_count" -eq 0 ]] && continue
        log i "startup_check: checking change for ${system}"
        local current_fp=$(_compute_fingerprint "${roms_path}/${system}")
        local stored_fp=$(_read_fingerprint "$system" "local")
        
        # Trim whitespace/newlines for robust comparison
        current_fp="${current_fp%%[[:space:]]}"
        stored_fp="${stored_fp%%[[:space:]]}"
        
        log d "startup_check: system='${system}' current_fp='${current_fp}' stored_fp='${stored_fp}'"
        
        # Trigger rebuild only if fingerprint differs (or no stored fingerprint exists)
        if [[ -z "$stored_fp" ]] || [[ "$current_fp" != "$stored_fp" ]]; then
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
    
    # Lightweight remote refresh for systems with auto_refresh enabled
    if [[ -f "$REMOTE_ROMS_RCLONE_CONF" ]]; then
        local -a autorefresh_systems
        while IFS= read -r system; do
            [[ -n "$system" ]] && autorefresh_systems+=("$system")
        done < <(jq -r '.remote_roms.systems | to_entries[] | select(.value.auto_refresh == true) | .key' "$rd_conf" 2>/dev/null)
        
        for system in "${autorefresh_systems[@]}"; do
            local remote_path=$(_get_config "systems.${system}.remote_path")
            [[ -z "$remote_path" ]] && continue
            
            local dir="${rd_home_path}/ES-DE/gamelists/${system}"
            local tmp="${dir}/gamelist.xml.remote.tmp.$$"
            
            # Try fetch (best effort, silent on failure)
            rclone --config "$REMOTE_ROMS_RCLONE_CONF" copyto "retrodeck-remote:${remote_path}/gamelist.xml" "$tmp" 2>/dev/null || \
                rclone --config "$REMOTE_ROMS_RCLONE_CONF" lsjson "retrodeck-remote:${remote_path}" 2>/dev/null | \
                    jq -r '.[] | select(.IsDir == false) | "  <game><path>./\(.Name | @html)</path><name>\(.Name | @html)</name></game>"' | \
                    { echo '<?xml version="1.0"?>'; echo '<gameList>'; cat; echo '</gameList>'; } > "$tmp" 2>/dev/null
            
            [[ ! -s "$tmp" ]] && { rm -f "$tmp"; continue; }
            
            [[ ! -s "$tmp" ]] && { rm -f "$tmp"; continue; }
            
            # Fast comparison: check file size first (instant rejection if same)
            local new_size=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
            local stored_size=$(stat -c %s "${dir}/gamelist.xml.remote" 2>/dev/null || echo 0)
            
            # Quick reject: if sizes match, likely content matches (skip expensive normalization)
            local skip_normalize=false
            if [[ "$new_size" == "$stored_size" && "$new_size" -gt 0 ]]; then
                # Optional: do a quick head/tail comparison for extra safety
                if cmp -s <(head -c 1000 "$tmp") <(head -c 1000 "${dir}/gamelist.xml.remote" 2>/dev/null); then
                    skip_normalize=true
                fi
            fi
            
            if [[ "$skip_normalize" == "true" ]]; then
                rm -f "$tmp"
                continue
            fi
            
            # Fast XML normalization: remove whitespace between tags only
            # Avoids expensive xmlstarlet c14n - uses simple sed/tr
            local normalized_tmp="${tmp}.norm"
            tr -d '\n\r\t' < "$tmp" | sed 's/<?xml[^?]*?>//g; s/>[[:space:]]*</></g' > "$normalized_tmp"
            
            # Get stored normalized fingerprint (computed once, stored in .fingerprint.remote)
            local stored_fp=$(_read_fingerprint "$system" "remote")
            local new_fp=$(sha256sum "$normalized_tmp" | cut -d' ' -f1)
            
            # Trim whitespace for robust comparison
            stored_fp="${stored_fp%%[[:space:]]}"
            new_fp="${new_fp%%[[:space:]]}"
            
            # Validate
            [[ ! -s "$normalized_tmp" ]] && { rm -f "$tmp" "$normalized_tmp"; continue; }
            
            if [[ -z "$stored_fp" ]] || [[ "$new_fp" != "$stored_fp" ]]; then
                log i "startup_check: remote updated for ${system}"
                mv "$tmp" "${dir}/gamelist.xml.remote"
                _write_fingerprint "$system" "remote" "$new_fp"
                _merge_gamelists "$system" "true"
                rescan_needed=true
            else
                rm -f "$tmp"
            fi
            rm -f "$normalized_tmp"
        done
    fi
    
    # Send single ESDE:RESCAN if any changes were made
    [[ "$rescan_needed" == "true" && -p "$FIFO_PATH" ]] && echo "ESDE:RESCAN" > "$FIFO_PATH"
    
    log i "remote_roms_startup_check: done"
}