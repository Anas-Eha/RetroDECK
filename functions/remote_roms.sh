#!/bin/bash

# Remote ROMs Functions
# Provides WebDAV-based remote ROM browsing and downloading
# Uses rclone for all remote operations

# ============================================
# Configuration & Constants
# ============================================

readonly REMOTE_ROMS_CACHE_DIR="${rd_cache}/remote_roms"
readonly REMOTE_ROMS_LISTING_FILE="listing.json"
readonly REMOTE_ROMS_GAMELIST_FILE="gamelist.xml"

# UI/UX Constants
readonly REMOTE_ROMS_ALPHABETICAL_BUCKET_THRESHOLD=200  # Games before using A-Z buckets
readonly REMOTE_ROMS_LATEST_GAMES_COUNT=50              # Number of recent games to show

# File Locking
readonly _REMOTE_ROMS_LOCK_FD=3

# Timeout Constants (seconds)
readonly REMOTE_ROMS_RCLONE_CONNECT_TIMEOUT=10
readonly REMOTE_ROMS_RCLONE_TIMEOUT=10
readonly REMOTE_ROMS_DOWNLOAD_CONNECT_TIMEOUT=30
readonly REMOTE_ROMS_DOWNLOAD_TIMEOUT=300

# ============================================
# Cleanup Infrastructure
# ============================================

# Track temporary files for guaranteed cleanup
_REMOTE_ROMS_TEMP_RCLONE_CONFIG=""
_REMOTE_ROMS_TEMP_FILES=()

_remote_roms_cleanup_temp_files() {
  # Cleanup function to ensure all temporary files are removed on any exit
  # Handles: normal exit, errors, signals (INT, TERM)
  
  [[ -n "$_REMOTE_ROMS_TEMP_RCLONE_CONFIG" ]] && rm -f "$_REMOTE_ROMS_TEMP_RCLONE_CONFIG"
  
  for file in "${_REMOTE_ROMS_TEMP_FILES[@]}"; do
    [[ -n "$file" ]] && rm -f "$file"
  done
  
  _REMOTE_ROMS_TEMP_RCLONE_CONFIG=""
  _REMOTE_ROMS_TEMP_FILES=()
}

_remote_roms_register_temp_file() {
  # Register a temporary file for cleanup
  local temp_file="$1"
  [[ -n "$temp_file" ]] && _REMOTE_ROMS_TEMP_FILES+=("$temp_file")
}

trap _remote_roms_cleanup_temp_files EXIT INT TERM

# ============================================
# Input Validation Functions
# ============================================

_remote_roms_validate_system_name() {
  # Validate system name format (prevent injection/traversal)
  local system="$1"
  
  # Allow only alphanumeric, underscore, hyphen
  if [[ ! "$system" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log e "Invalid system name: '$system' (alphanumeric, hyphen, underscore only)"
    return 1
  fi
  return 0
}

_remote_roms_validate_webdav_url() {
  # Validate WebDAV URL format
  local url="$1"
  
  if [[ -z "$url" ]]; then
    log e "WebDAV URL cannot be empty"
    return 1
  fi
  
  # Basic URL validation: must start with http:// or https://
  if [[ ! "$url" =~ ^https?:// ]]; then
    log e "Invalid WebDAV URL: '$url' (must start with http:// or https://)"
    return 1
  fi
  
  return 0
}

_remote_roms_validate_remote_path() {
  # Validate remote path (prevent directory traversal)
  local path="$1"
  
  if [[ -z "$path" ]]; then
    log e "Remote path cannot be empty"
    return 1
  fi
  
  # Reject paths with parent directory traversal
  if [[ "$path" =~ \.\./ || "$path" =~ /\.\.$ || "$path" == ".." ]]; then
    log e "Invalid remote path: '$path' (parent directory traversal not allowed)"
    return 1
  fi
  
  # Reject absolute paths
  if [[ "$path" =~ ^/ ]]; then
    log e "Invalid remote path: '$path' (must be relative path)"
    return 1
  fi
  
  return 0
}

# ============================================
# File Locking Functions (for config atomicity)
# ============================================

_remote_roms_lock_config() {
  # Acquire lock on config file to prevent concurrent modification
  # Uses file descriptor $_REMOTE_ROMS_LOCK_FD to hold the lock
  if [[ ! -f "$rd_file_lock" ]]; then
    touch "$rd_file_lock" || return 1
  fi
  
  eval "exec $_REMOTE_ROMS_LOCK_FD>\"$rd_file_lock\"" || return 1
  
  # Try to acquire exclusive lock with timeout
  if ! flock -n $_REMOTE_ROMS_LOCK_FD; then
    log w "Waiting for config lock..."
    flock $_REMOTE_ROMS_LOCK_FD || return 1
  fi
  
  return 0
}

_remote_roms_unlock_config() {
  # Release lock on config file
  exec $_REMOTE_ROMS_LOCK_FD>&- 2>/dev/null || true
}

# ============================================
# Internal Helper Functions
# ============================================

remote_roms_log_debug() {
  # Only log if remote ROMs debug logging is enabled
  if [[ "${REMOTE_ROMS_DEBUG:-0}" == "1" ]]; then
    log d "$1"
  fi
}

_remote_roms_zenity_wrapper() {
  # Wrapper for zenity that captures errors for debug logging
  # All zenity stderr is logged when REMOTE_ROMS_DEBUG=1
  # USAGE: output=$(_remote_roms_zenity_wrapper --list --title "Foo" ...)

  local output
  local err_output
  err_output=$(mktemp)
  _remote_roms_register_temp_file "$err_output"

  output=$(zenity "$@" 2>"$err_output")
  local exit_code=$?

  if [[ "${REMOTE_ROMS_DEBUG:-0}" == "1" ]]; then
    local err_content
    err_content=$(cat "$err_output" 2>/dev/null)
    if [[ -n "$err_content" ]]; then
      log d "zenity stderr: $err_content"
    fi
  fi

  # Remove from tracking and cleanup
  _REMOTE_ROMS_TEMP_FILES=("${_REMOTE_ROMS_TEMP_FILES[@]/#$err_output/}")
  rm -f "$err_output"

  echo "$output"
  return $exit_code
}

_remote_roms_write_rclone_config() {
  # Write rclone config file with secure permissions
  # USAGE: _remote_roms_write_rclone_config "$config_file" "$section" "$url" "$user" "$pass"

  local config_file="$1"
  local section="$2"
  local url="$3"
  local user="$4"
  local pass="$5"

  # Obscure password for rclone (rclone uses reversible obfuscation, NOT encryption)
  # This is not security - it only prevents casual shoulder-surfing of the config file
  local obscured_pass
  obscured_pass=$(rclone obscure "$pass" 2>/dev/null) || obscured_pass="$pass"

  # Write config file first
  {
    echo "[$section]"
    echo "type = webdav"
    echo "url = $url"
    echo "vendor = other"
    echo "user = $user"
    echo "pass = $obscured_pass"
  } > "$config_file"

  # Then set restricted permissions
  chmod 600 "$config_file" || {
    log e "Failed to set permissions on rclone config"
    return 1
  }
}


# ============================================
# Configuration Functions
# ============================================

remote_roms_init_config() {
  # Initialize remote ROMs configuration if not present
  # USAGE: remote_roms_init_config
  # Returns: 0 on success, 1 on failure

  if ! jq -e '.remote_roms' "$rd_conf" > /dev/null 2>&1; then
    log i "Creating remote_roms configuration"
    local default_config='{
      "webdav_url": "",
      "systems": {},
      "global_enabled": false
    }'
    
    if ! jq --argjson config "$default_config" '.remote_roms = $config' "$rd_conf" > "$rd_conf.tmp"; then
      log e "Failed to create remote_roms config"
      rm -f "$rd_conf.tmp"
      return 1
    fi
    
    if ! mv "$rd_conf.tmp" "$rd_conf"; then
      log e "Failed to update config file"
      rm -f "$rd_conf.tmp"
      return 1
    fi
  fi
  return 0
}

remote_roms_get_setting() {
  # Get a remote ROMs setting value (global or system-specific)
  # USAGE: value=$(remote_roms_get_setting "setting_name")
  # USAGE: value=$(remote_roms_get_setting "$system" "property")
  # Returns: Setting value or empty string; exit code 0 always

  if [[ $# -eq 1 ]]; then
    # Global setting
    jq -r ".remote_roms.$1 // empty" "$rd_conf" 2>/dev/null || echo ""
  else
    # System-specific setting - validate system name
    local system="$1"
    local property="$2"
    
    if ! _remote_roms_validate_system_name "$system"; then
      return 0  # Return empty on invalid system name
    fi
    
    jq -r ".remote_roms.systems[\"$system\"].$property // empty" "$rd_conf" 2>/dev/null || echo ""
  fi
}

remote_roms_set_setting() {
  # Set a remote ROMs setting value (global or system-specific)
  # USAGE: remote_roms_set_setting "setting_name" "value"
  # USAGE: remote_roms_set_setting "$system" "property" "value"
  # Returns: 0 on success, 1 on failure

  if ! _remote_roms_lock_config; then
    log e "Failed to acquire config lock"
    return 1
  fi
  
  if [[ $# -eq 2 ]]; then
    # Global setting
    if ! jq --arg val "$2" ".remote_roms.$1 = \$val" "$rd_conf" > "$rd_conf.tmp"; then
      log e "Failed to update setting $1"
      rm -f "$rd_conf.tmp"
      _remote_roms_unlock_config
      return 1
    fi
  else
    # System-specific setting
    local system="$1"
    local property="$2"
    local value="$3"
    
    if ! _remote_roms_validate_system_name "$system"; then
      _remote_roms_unlock_config
      return 1
    fi
    
    if ! jq --arg s "$system" --arg p "$property" --arg v "$value" \
      '.remote_roms.systems[$s][$p] = $v' "$rd_conf" > "$rd_conf.tmp"; then
      log e "Failed to update setting $system.$property"
      rm -f "$rd_conf.tmp"
      _remote_roms_unlock_config
      return 1
    fi
  fi
  
  if ! mv "$rd_conf.tmp" "$rd_conf"; then
    log e "Failed to commit config changes"
    rm -f "$rd_conf.tmp"
    _remote_roms_unlock_config
    return 1
  fi
  
  _remote_roms_unlock_config
  return 0
}

remote_roms_get_webdav_creds() {
  # Get WebDAV credentials from rclone.conf
  # USAGE: eval $(remote_roms_get_webdav_creds)  # sets $url, $user, $pass
  # OR: local url=$(remote_roms_get_webdav_creds url)
  # NOTE: Uses base64 encoding to safely handle special characters in credentials

  local field="${1:-all}"
  local url=""
  local user=""
  local pass=""
  local rclone_conf="${XDG_CONFIG_HOME:-$HOME/.config}/rclone/rclone.conf"

  # Get URL from JSON config
  url=$(remote_roms_get_setting "webdav_url")

  # Get credentials from rclone.conf if it exists
  if [[ -f "$rclone_conf" ]]; then
    user=$(awk -F' = ' '/^\[retrodeck-webdav\]/{found=1} found && /^user = /{print $2; found=0}' "$rclone_conf")
    pass=$(awk -F' = ' '/^\[retrodeck-webdav\]/{found=1} found && /^pass = /{print $2; found=0}' "$rclone_conf")
  fi

  case "$field" in
    url)  echo "$url" ;;
    user) echo "$user" ;;
    pass) echo "$pass" ;;
    *)    echo "url=$(echo -n "$url" | base64 -w 0); user=$(echo -n "$user" | base64 -w 0); pass=$(echo -n "$pass" | base64 -w 0)" ;;
  esac
}

remote_roms_save_webdav_config() {
  # Save WebDAV connection settings
  # URL is saved to JSON, credentials are saved to rclone.conf only
  # USAGE: remote_roms_save_webdav_config "$url" "$user" "$pass"
  # Returns: 0 on success, 1 on failure

  local url="$1"
  local user="$2"
  local pass="$3"
  
  # Validate inputs
  if ! _remote_roms_validate_webdav_url "$url"; then
    return 1
  fi
  
  if [[ -z "$user" ]]; then
    log e "WebDAV username cannot be empty"
    return 1
  fi
  
  # Save URL to JSON config only (no credentials)
  remote_roms_set_setting "webdav_url" "$url" || return 1
  
  # Save credentials to rclone.conf
  local rclone_dir="${XDG_CONFIG_HOME:-$HOME/.config}/rclone"
  mkdir -p "$rclone_dir" || {
    log e "Failed to create rclone directory"
    return 1
  }
  
  if ! _remote_roms_write_rclone_config "$rclone_dir/rclone.conf" "retrodeck-webdav" "$url" "$user" "$pass"; then
    log e "Failed to write rclone config"
    return 1
  fi
  
  log i "WebDAV configuration saved"
  return 0
}

remote_roms_test_connection() {
  # Test WebDAV connection
  # USAGE: result=$(remote_roms_test_connection)
  # Returns: "connected", "missing_config", "rclone_not_found", or "connection_failed"

  # Decode base64-encoded credentials to safely handle special characters
  eval $(remote_roms_get_webdav_creds)
  url=$(echo "$url" | base64 -d)
  user=$(echo "$user" | base64 -d)
  pass=$(echo "$pass" | base64 -d)

  # Check for missing configuration
  if [[ -z "$url" || -z "$user" ]]; then
    echo "missing_config"
    return 1
  fi

  # Check if rclone is available
  if ! command -v rclone &> /dev/null; then
    echo "rclone_not_found"
    return 1
  fi

  # Create temporary rclone config
  local rclone_config
  rclone_config=$(mktemp) || {
    echo "connection_failed"
    return 1
  }
  _REMOTE_ROMS_TEMP_RCLONE_CONFIG="$rclone_config"

  if ! _remote_roms_write_rclone_config "$rclone_config" "webdav-test" "$url" "$user" "$pass"; then
    echo "connection_failed"
    return 1
  fi

  # Test connection with timeout
  local rclone_output
  rclone_output=$(RCLONE_CONFIG="$rclone_config" rclone ls "webdav-test:/" --max-depth 1 \
    --contimeout ${REMOTE_ROMS_RCLONE_CONNECT_TIMEOUT}s --timeout ${REMOTE_ROMS_RCLONE_TIMEOUT}s 2>&1)
  local rclone_exit_code=$?

  if [[ $rclone_exit_code -eq 0 ]]; then
    echo "connected"
    return 0
  else
    # Log the actual error for debugging
    log e "WebDAV connection test failed: $rclone_output"
    remote_roms_log_debug "rclone exit code: $rclone_exit_code"
    remote_roms_log_debug "rclone output: $rclone_output"
    echo "connection_failed"
    return 1
  fi
}

# ============================================
# System Management Functions
# ============================================

remote_roms_add_system() {
  # Add a system to remote ROMs configuration
  # USAGE: remote_roms_add_system "$system" "$remote_path"
  # Returns: 0 on success, 1 on failure

  local system="$1"
  local remote_path="$2"

  # Validate inputs
  if ! _remote_roms_validate_system_name "$system"; then
    return 1
  fi
  
  if ! _remote_roms_validate_remote_path "$remote_path"; then
    return 1
  fi

  if ! _remote_roms_lock_config; then
    log e "Failed to acquire config lock"
    return 1
  fi

  local system_obj
  system_obj=$(jq -n \
    --arg system "$system" \
    --arg remote_path "$remote_path" \
    '{
      "system": $system,
      "remote_path": $remote_path,
      "enabled": true
    }') || {
    _remote_roms_unlock_config
    log e "Failed to create system object"
    return 1
  }

  if ! jq --arg system "$system" --argjson obj "$system_obj" '.remote_roms.systems[$system] = $obj' "$rd_conf" > "$rd_conf.tmp"; then
    _remote_roms_unlock_config
    rm -f "$rd_conf.tmp"
    log e "Failed to add system $system"
    return 1
  fi

  if ! mv "$rd_conf.tmp" "$rd_conf"; then
    _remote_roms_unlock_config
    rm -f "$rd_conf.tmp"
    log e "Failed to commit system addition"
    return 1
  fi

  _remote_roms_unlock_config
  log i "Added remote ROM system: $system"
  return 0
}

remote_roms_remove_system() {
  # Remove a system from remote ROMs configuration
  # USAGE: remote_roms_remove_system "$system"
  # Returns: 0 on success, 1 on failure

  local system="$1"

  # Validate system name
  if ! _remote_roms_validate_system_name "$system"; then
    return 1
  fi

  # Clear cache
  rm -rf "${REMOTE_ROMS_CACHE_DIR:?}/${system}" || {
    log w "Failed to remove cache for $system"
  }

  if ! _remote_roms_lock_config; then
    log e "Failed to acquire config lock"
    return 1
  fi

  if ! jq --arg s "$system" 'del(.remote_roms.systems[$s])' "$rd_conf" > "$rd_conf.tmp"; then
    _remote_roms_unlock_config
    rm -f "$rd_conf.tmp"
    log e "Failed to remove system $system"
    return 1
  fi

  if ! mv "$rd_conf.tmp" "$rd_conf"; then
    _remote_roms_unlock_config
    rm -f "$rd_conf.tmp"
    log e "Failed to commit system removal"
    return 1
  fi

  _remote_roms_unlock_config
  log i "Removed remote ROM system: $system"
  return 0
}

remote_roms_get_available_systems() {
  # Get list of available RetroDECK systems
  # Returns: Space-separated list of system folder names

  # First try to get systems from actual roms folder
  if [[ -n "$roms_path" && -d "$roms_path" ]]; then
    local systems=""
    for dir in "$roms_path"/*/; do
      if [[ -d "$dir" ]]; then
        local sysname=$(basename "$dir")
        # Skip special directories
        [[ "$sysname" == "remote" || "$sysname" == "downloaded" ]] && continue
        systems="$systems $sysname"
      fi
    done
    # If we found actual systems, return them
    if [[ -n "$systems" ]]; then
      echo "$systems"
      return 0
    fi
  fi

  # Fallback: extract unique system names from bios.json reference file
  if [[ -f "$bios_checklist" ]]; then
    jq -r '.bios[].system' "$bios_checklist" 2>/dev/null | sort -u | tr '\n' ' '
    return 0
  fi

  # Final fallback: return empty
  echo ""
  return 1
}

# ============================================
# Discovery Functions
# ============================================

remote_roms_discover_systems() {
  # Auto-discover systems on WebDAV server
  # USAGE: discovered=$(remote_roms_discover_systems)
  # Returns: 0 on success (JSON object), 1 on failure (empty JSON)

  # Decode base64-encoded credentials to safely handle special characters
  eval $(remote_roms_get_webdav_creds)
  url=$(echo "$url" | base64 -d)
  user=$(echo "$user" | base64 -d)
  pass=$(echo "$pass" | base64 -d)

  if [[ -z "$url" || -z "$user" ]]; then
    echo "{}"
    return 1
  fi

  # Create temporary rclone config
  local rclone_config
  rclone_config=$(mktemp) || {
    echo "{}"
    return 1
  }
  _REMOTE_ROMS_TEMP_RCLONE_CONFIG="$rclone_config"

  if ! _remote_roms_write_rclone_config "$rclone_config" "webdav-discover" "$url" "$user" "$pass"; then
    echo "{}"
    return 1
  fi

  local available_systems=$(remote_roms_get_available_systems)
  local discovered="{}"

  # Scan root and common subfolders for system folders
  for scan_path in "/" "/roms" "/games" "/library"; do
    local folders=$(RCLONE_CONFIG="$rclone_config" rclone lsf "webdav-discover:$scan_path" --max-depth 1 --dirs-only 2>/dev/null | sed 's|/$||')

    while IFS= read -r folder; do
      [[ -z "$folder" ]] && continue

      # Validate folder name before processing
      if ! _remote_roms_validate_system_name "$folder"; then
        continue
      fi

      local full_path="${scan_path:1}$folder"
      [[ "$scan_path" == "/" ]] && full_path="$folder"

      # Check if folder name matches a known system
      for sys in $available_systems; do
        if [[ "$folder" == "$sys" ]]; then
          # Only add if not already found (prefer shorter paths)
          if ! echo "$discovered" | jq -e --arg s "$sys" 'has($s)' > /dev/null 2>&1; then
            discovered=$(echo "$discovered" | jq --arg s "$sys" --arg p "$full_path" '.[$s] = $p')
          fi
          break
        fi
      done
    done <<< "$folders"
  done

  echo "$discovered"
  return 0
}

# ============================================
# ROM Listing & Gamelist Functions
# ============================================

remote_roms_generate_rclone_config() {
  # Generate rclone config file for operations
  # USAGE: remote_roms_generate_rclone_config

  # Decode base64-encoded credentials to safely handle special characters
  eval $(remote_roms_get_webdav_creds)
  url=$(echo "$url" | base64 -d)
  user=$(echo "$user" | base64 -d)
  pass=$(echo "$pass" | base64 -d)

  if [[ -z "$url" || -z "$user" ]]; then
    log e "Cannot generate rclone config: missing URL or username"
    return 1
  fi

  if ! command -v rclone &> /dev/null; then
    log e "rclone not found in PATH"
    return 1
  fi

  local rclone_dir="$XDG_CONFIG_HOME/rclone"
  mkdir -p "$rclone_dir" || {
    log e "Failed to create rclone directory"
    return 1
  }

  if ! _remote_roms_write_rclone_config "$rclone_dir/rclone.conf" "retrodeck-webdav" "$url" "$user" "$pass"; then
    log e "Failed to write rclone config"
    return 1
  fi
}

remote_roms_fetch_gamelist() {
  # Fetch gamelist.xml from remote server
  # USAGE: remote_roms_fetch_gamelist "$system"
  # Returns: 0 on success, 1 on failure

  local system="$1"
  
  # Validate system name
  if ! _remote_roms_validate_system_name "$system"; then
    return 1
  fi

  local cache_dir="${REMOTE_ROMS_CACHE_DIR}/${system}"
  mkdir -p "$cache_dir" || return 1
  local gamelist_path="${cache_dir}/${REMOTE_ROMS_GAMELIST_FILE}"

  remote_roms_log_debug "fetch_gamelist: fetching for $system"

  # Get remote path
  local remote_path=$(remote_roms_get_setting "$system" "remote_path")
  if [[ -z "$remote_path" ]]; then
    return 1
  fi

  remote_roms_generate_rclone_config || return 1

  # Try to fetch gamelist.xml from remote
  local temp_file
  temp_file=$(mktemp) || return 1
  _remote_roms_register_temp_file "$temp_file"

  if rclone copyto "retrodeck-webdav:${remote_path}/gamelist.xml" "$temp_file" 2>/dev/null; then
    mv "$temp_file" "$gamelist_path" || return 1
    remote_roms_log_debug "fetch_gamelist: downloaded gamelist.xml for $system"
    # Remove from tracking since it's been moved (exact match only)
    _REMOTE_ROMS_TEMP_FILES=("${_REMOTE_ROMS_TEMP_FILES[@]/#$temp_file/}")
    return 0
  else
    remote_roms_log_debug "fetch_gamelist: no gamelist.xml found for $system"
    return 1
  fi
}

remote_roms_build_listing_from_gamelist() {
  # Build ROM listing from gamelist.xml using xmlstarlet for robust parsing
  # Supports RomM format: <path>, <name>, <desc>, etc.
  # Handles both local paths (./filename) and URLs
  # USAGE: listing=$(remote_roms_build_listing_from_gamelist "$system" "$gamelist_path")

  local system="$1"
  local gamelist_path="$2"

  if [[ ! -f "$gamelist_path" ]]; then
    echo "[]"
    return 1
  fi

  # Verify XML is valid
  if ! xmlstarlet val "$gamelist_path" > /dev/null 2>&1; then
    log w "Invalid XML in gamelist.xml for $system"
    echo "[]"
    return 1
  fi

  # Get game count
  local game_count=$(xmlstarlet sel -t -v "count(//game)" "$gamelist_path" 2>/dev/null)
  if [[ -z "$game_count" || "$game_count" -eq 0 ]]; then
    remote_roms_log_debug "No games found in gamelist.xml for $system"
    echo "[]"
    return 1
  fi

  remote_roms_log_debug "Found $game_count games in gamelist.xml for $system"

  # Build JSON array using xmlstarlet to extract path/name pairs
  # Output format: path|name (one per line, properly handling special chars)
  local json_entries=$(xmlstarlet sel -t \
    -m "//game[path]" \
    -v "path" -o "|" \
    -v "name" -n \
    "$gamelist_path" 2>/dev/null | \
  while IFS='|' read -r path name; do
    # Skip empty paths
    [[ -z "$path" ]] && continue

    # Handle path: strip leading ./ for local paths, extract filename from URLs
    local filename="$path"
    if [[ "$path" =~ ^https?:// ]]; then
      # URL path - extract filename
      filename=$(basename "$path" | sed 's/[?#].*$//')
    else
      # Local path - strip leading ./ if present
      filename="${path#./}"
    fi

    # Use name if available, otherwise use filename
    local display_name="${name:-$filename}"

    # Escape for JSON using jq
    printf '{"name":%s,"display_name":%s,"size":0,"path":%s}\n' \
      "$(printf '%s' "$filename" | jq -Rs '.[:-1]')" \
      "$(printf '%s' "$display_name" | jq -Rs '.[:-1]')" \
      "$(printf '%s' "$filename" | jq -Rs '.[:-1]')"
  done | jq -s '.' 2>/dev/null)

  if [[ -z "$json_entries" || "$json_entries" == "null" ]]; then
    echo "[]"
    return 1
  fi

  echo "$json_entries"
}

remote_roms_build_listing_from_directory() {
  # Build ROM listing from remote directory scan
  # USAGE: listing=$(remote_roms_build_listing_from_directory "$system")

  local system="$1"
  local remote_path=$(remote_roms_get_setting "$system" "remote_path")

  if [[ -z "$remote_path" ]]; then
    echo "[]"
    return 1
  fi

  remote_roms_generate_rclone_config || return 1

  # Fetch listing with rclone lsjson
  local temp_file
  temp_file=$(mktemp) || return 1
  _remote_roms_register_temp_file "$temp_file"

  if rclone lsjson "retrodeck-webdav:${remote_path}" --recursive > "$temp_file" 2>/dev/null; then
    # Filter only files and format
    local listing=$(jq '[.[] | select(.IsDir == false) | {
      "name": .Name,
      "display_name": .Name,
      "size": .Size,
      "path": .Path,
      "modtime": .ModTime
    }]' "$temp_file")
    echo "$listing"
    return 0
  else
    echo "[]"
    return 1
  fi
}

remote_roms_refresh_system_listing() {
  # Refresh ROM listing for a system
  # Tries gamelist.xml first, falls back to directory listing
  # USAGE: remote_roms_refresh_system_listing "$system"
  # Returns: 0 on success, 1 on failure

  local system="$1"
  local cache_dir="${REMOTE_ROMS_CACHE_DIR}/${system}"
  local cache_file="${cache_dir}/${REMOTE_ROMS_LISTING_FILE}"

  remote_roms_log_debug "refresh_system_listing: refreshing for $system"

  # Ensure rclone config exists
  remote_roms_generate_rclone_config || return 1

  # Try to fetch gamelist.xml first
  local listing=""
  if remote_roms_fetch_gamelist "$system"; then
    local gamelist_path="${cache_dir}/${REMOTE_ROMS_GAMELIST_FILE}"
    listing=$(remote_roms_build_listing_from_gamelist "$system" "$gamelist_path")
    remote_roms_log_debug "refresh_system_listing: built listing from gamelist.xml for $system"
  fi

  # If no gamelist or gamelist failed, build from directory
  if [[ -z "$listing" || "$listing" == "[]" ]]; then
    listing=$(remote_roms_build_listing_from_directory "$system")
    remote_roms_log_debug "refresh_system_listing: built listing from directory for $system"
  fi

  # Save listing to cache
  if [[ -n "$listing" && "$listing" != "[]" ]]; then
    echo "$listing" > "$cache_file"
    local count=$(echo "$listing" | jq 'length')
    log i "Cached $count ROMs for $system"
    return 0
  else
    log w "No ROMs found for $system"
    return 1
  fi
}

remote_roms_get_system_listing() {
  # Get cached ROM listing for a system
  # USAGE: listing=$(remote_roms_get_system_listing "$system")

  local system="$1"
  local cache_file="${REMOTE_ROMS_CACHE_DIR}/${system}/${REMOTE_ROMS_LISTING_FILE}"

  if [[ -f "$cache_file" ]]; then
    cat "$cache_file"
    return 0
  else
    echo "[]"
    return 1
  fi
}

remote_roms_ensure_listing() {
  # Get listing for a system, refreshing if needed
  # USAGE: listing=$(remote_roms_ensure_listing "$system")

  local system="$1"
  local listing=$(remote_roms_get_system_listing "$system")
  local count=$(echo "$listing" | jq 'length')

  if [[ "$count" -eq 0 ]] && remote_roms_refresh_system_listing "$system"; then
    listing=$(remote_roms_get_system_listing "$system")
  fi
  echo "$listing"
}

remote_roms_refresh_all_systems() {
  # Refresh ROM listings for all configured systems
  # USAGE: count=$(remote_roms_refresh_all_systems)
  # Returns: Number of successfully refreshed systems

  log i "Refreshing all remote ROM listings"

  local systems=$(remote_roms_get_setting "systems")
  local refreshed=0
  local total=$(echo "$systems" | jq 'length')

  if [[ "$total" -eq 0 ]]; then
    log w "No systems configured for remote ROMs"
    echo "0"
    return 0
  fi

  while IFS= read -r system; do
    [[ -z "$system" ]] && continue

    if remote_roms_refresh_system_listing "$system"; then
      ((refreshed++))
    fi
  done < <(echo "$systems" | jq -r 'keys[]')

  log i "Refreshed $refreshed/$total systems"
  echo "$refreshed"
}

# ============================================
# ROM Download Functions
# ============================================

remote_roms_download_rom() {
  # Download a ROM from remote to local storage
  # USAGE: local_path=$(remote_roms_download_rom "$system" "$rom_name")
  # Returns: Path to local file

  local system="$1"
  local rom_name="$2"
  local local_path="${roms_path}/${system}/${rom_name}"

  remote_roms_log_debug "download_rom: $system/$rom_name"

  # Return existing local file immediately
  if [[ -f "$local_path" ]]; then
    echo "$local_path"
    return 0
  fi

  # Get remote path from config
  local remote_path=$(remote_roms_get_setting "$system" "remote_path")
  if [[ -z "$remote_path" ]]; then
    log e "No remote_path configured for $system"
    return 1
  fi

  # Ensure rclone config exists
  remote_roms_generate_rclone_config || return 1

  # Create temp file for atomic download using PID for uniqueness
  local temp_file="${local_path}.tmp.$$"
  mkdir -p "$(dirname "$local_path")" || {
    log e "Failed to create directory for $rom_name"
    return 1
  }
  _remote_roms_register_temp_file "$temp_file"

  log i "Downloading $rom_name from remote..."

  # Use rclone copyto with timeouts
  if rclone copyto "retrodeck-webdav:${remote_path}/${rom_name}" "$temp_file" \
    --progress --contimeout ${REMOTE_ROMS_DOWNLOAD_CONNECT_TIMEOUT}s --timeout ${REMOTE_ROMS_DOWNLOAD_TIMEOUT}s 2>/dev/null; then
    if mv "$temp_file" "$local_path"; then
      log i "Downloaded $rom_name successfully"
      echo "$local_path"
      return 0
    else
      log e "Failed to move downloaded file to $local_path"
      return 1
    fi
  else
    log e "Failed to download $rom_name"
    return 1
  fi
}

# ============================================
# Virtual Browser Dialog Functions
# ============================================

remote_roms_browse_system() {
  # Show ROM browser dialog for a system
  # USAGE: selected_file=$(remote_roms_browse_system "$system")
  # Returns: Selected file or empty on cancel/failure

  local system="$1"
  
  # Validate system name
  if ! _remote_roms_validate_system_name "$system"; then
    return 1
prprismaazure  fi

  remote_roms_log_debug "browse_system: opening browser for $system"

  # Ensure listing is available (with automatic refresh)
  local listing=$(remote_roms_ensure_listing "$system")
  local count=$(echo "$listing" | jq 'length')

  if [[ "$count" -eq 0 ]]; then
    zenity --error --title "Remote ROMs" --text "No ROMs found for $system"
    return 1
  fi

  # For large libraries, use alphabetical bucketing
  if [[ "$count" -gt $REMOTE_ROMS_ALPHABETICAL_BUCKET_THRESHOLD ]]; then
    remote_roms_browse_alphabetical "$system" "$listing"
  else
    remote_roms_show_game_list "$system" "$listing"
  fi
}

remote_roms_browse_alphabetical() {
  # Browse with A-Z letter selection first
  # USAGE: selected_file=$(remote_roms_browse_alphabetical "$system" "$listing")

  local system="$1"
  local listing="$2"

  # Get unique first letters from display names
  local letters=$(echo "$listing" | jq -r '.[].display_name[0:1] | ascii_upcase' | sort -u)

  # Show letter selector
  local selected_letter=$(echo "$letters" | zenity --list \
    --title "Browse $system - Select Letter" \
    --text "Found $(echo "$listing" | jq 'length') games. Choose a letter:" \
    --column "Letter" \
    --width 200 --height 400 2>/dev/null)

  [[ -z "$selected_letter" ]] && return 1

  # Filter games by selected letter
  local filtered=$(echo "$listing" | jq --arg letter "$selected_letter" \
    '[.[] | select(.display_name | ascii_upcase | startswith($letter))]')

  # Show filtered list
  remote_roms_show_game_list "$system" "$filtered"
}

remote_roms_show_game_list() {
  # Show zenity list dialog for game selection
  # USAGE: selected_file=$(remote_roms_show_game_list "$system" "$game_json")

  local system="$1"
  local game_data="$2"

  # Format for zenity: display_name | size | filename
  local list_data=$(echo "$game_data" | jq -r '
    .[] | [
      .display_name,
      (if .size > 0 then (.size | tonumber | . / 1024 / 1024 | floor | tostring + " MB") else "Unknown" end),
      .name
    ] | @tsv
  ')

  # Show selection dialog
  local selection=$(echo "$list_data" | zenity --list \
    --title "Select ROM - $system" \
    --text "Choose a game to download:" \
    --column "Name" \
    --column "Size" \
    --column "Filename" \
    --hide-column 3 \
    --print-column 3 \
    --width 700 --height 600 \
    --search-column 1 2>/dev/null)

  echo "$selection"
}

remote_roms_search_dialog() {
  # Search-based ROM finder
  # USAGE: selected_file=$(remote_roms_search_dialog "$system" ["$query"])
  # Returns: Selected file or empty on cancel/failure

  local system="$1"
  local query="${2:-}"

  # Validate system name
  if ! _remote_roms_validate_system_name "$system"; then
    return 1
  fi

  # Prompt for search if no query provided
  if [[ -z "$query" ]]; then
    query=$(zenity --entry \
      --title "Search $system" \
      --text "Enter game name to search:" 2>/dev/null)
  fi

  [[ -z "$query" ]] && return 1

  local listing=$(remote_roms_get_system_listing "$system")

  # Search in display names (case-insensitive)
  local matches=$(echo "$listing" | jq --arg q "$query" \
    '[.[] | select(.display_name | test($q; "i"))]')

  local match_count=$(echo "$matches" | jq 'length')

  if [[ "$match_count" -eq 0 ]]; then
    zenity --error --title "Search" --text "No games found matching '$query'"
    return 1
  elif [[ "$match_count" -eq 1 ]]; then
    # Auto-select single match
    echo "$matches" | jq -r '.[0].name'
    return 0
  else
    # Show matches
    remote_roms_show_game_list "$system" "$matches"
  fi
}

remote_roms_virtual_browser_menu() {
  # Main entry point for virtual browser
  # USAGE: local_path=$(remote_roms_virtual_browser_menu "$system")
  # Returns: 0 on success with path, 1 on failure

  local system="$1"

  # Validate system name
  if ! _remote_roms_validate_system_name "$system"; then
    return 1
  fi

  # Initialize and check config
  if ! remote_roms_init_config; then
    log e "Failed to initialize remote ROMs config"
    return 1
  fi

  # Check if system is enabled (global + system setting)
  local global_enabled=$(remote_roms_get_setting "global_enabled")
  local system_enabled=$(remote_roms_get_setting "$system" "enabled")
  if [[ "$global_enabled" != "true" || "$system_enabled" != "true" ]]; then
    log w "Remote ROMs not enabled for $system"
    return 1
  fi

  # Show main menu
  local action=$(zenity --list \
    --title "Remote ROMs - $system" \
    --text "Choose an action:" \
    --column "Action" --column "Description" \
    "browse" "Browse all games (A-Z)" \
    "search" "Search by name" \
    "latest" "Show recently added" \
    --width 400 --height 300 2>/dev/null)

  local selected_file=""

  case "$action" in
    browse)
      selected_file=$(remote_roms_browse_system "$system") || return 1
      ;;
    search)
      selected_file=$(remote_roms_search_dialog "$system") || return 1
      ;;
    latest)
      # Show recently added games
      local listing=$(remote_roms_get_system_listing "$system")
      local latest=$(echo "$listing" | jq --argjson count "$REMOTE_ROMS_LATEST_GAMES_COUNT" 'sort_by(.modtime) | reverse | .[0:$count]')
      selected_file=$(remote_roms_show_game_list "$system" "$latest") || return 1
      ;;
    *)
      return 1
      ;;
  esac

  [[ -z "$selected_file" ]] && return 1

  # Download and return local path
  remote_roms_download_rom "$system" "$selected_file"
}

remote_roms_create_esde_integration() {
  # Create ES-DE integration files for remote ROM browsing
  # Creates a "Remote" folder with gamelist entry that triggers the virtual browser
  # USAGE: remote_roms_create_esde_integration "$system"
  # Returns: 0 on success, 1 on failure

  local system="$1"
  
  # Validate system name
  if ! _remote_roms_validate_system_name "$system"; then
    return 1
  fi

  local system_roms_path="${roms_path}/${system}"
  local remote_folder="${system_roms_path}/remote"

  # Create remote folder
  mkdir -p "$remote_folder" || {
    log e "Failed to create remote folder for $system"
    return 1
  }

  # Create trigger file that opens the virtual browser when "launched"
  # This is a placeholder file that run_game.sh detects
  local trigger_file="${remote_folder}/Browse Remote ROMs.remote_trigger"
  {
    echo "# This file triggers the virtual browser when selected in ES-DE"
    echo "# System: $system"
  } > "$trigger_file" || {
    log e "Failed to create trigger file for $system"
    return 1
  }

  # Create gamelist.xml entry for the remote folder if gamelist exists
  local gamelist_path="${system_roms_path}/gamelist.xml"
  if [[ -f "$gamelist_path" ]]; then
    # Check if entry already exists
    if ! grep -q "Browse Remote ROMs" "$gamelist_path" 2>/dev/null; then
      # Add entry before closing </gameList> tag
      local temp_gamelist
      temp_gamelist=$(mktemp) || return 1
      _remote_roms_register_temp_file "$temp_gamelist"

      if awk '
        /<\/gameList>/ {
          print "  <game>"
          print "    <path>./remote/Browse Remote ROMs.remote_trigger</path>"
          print "    <name>📡 Browse Remote ROMs</name>"
          print "    <desc>Browse and download ROMs from your WebDAV server</desc>"
          print "    <image></image>"
          print "    <thumbnail></thumbnail>"
          print "  </game>"
        }
        { print }
      ' "$gamelist_path" > "$temp_gamelist"; then
        if mv "$temp_gamelist" "$gamelist_path"; then
          # Remove from tracking since it's been moved (exact match only)
          _REMOTE_ROMS_TEMP_FILES=("${_REMOTE_ROMS_TEMP_FILES[@]/#$temp_gamelist/}")
        else
          log e "Failed to update gamelist.xml for $system"
          return 1
        fi
      else
        log e "Failed to process gamelist.xml for $system"
        return 1
      fi
    fi
  fi

  log i "ES-DE integration created for $system"
  return 0
}

remote_roms_remove_esde_integration() {
  # Remove ES-DE integration files for a system
  # USAGE: remote_roms_remove_esde_integration "$system"
  # Returns: 0 on success, 1 on failure

  local system="$1"
  
  # Validate system name
  if ! _remote_roms_validate_system_name "$system"; then
    return 1
  fi

  local remote_folder="${roms_path}/${system}/remote"

  # Remove remote folder and trigger file
  if [[ -d "$remote_folder" ]]; then
    rm -rf "$remote_folder" || {
      log w "Failed to remove remote folder for $system"
    }
  fi

  # Remove from gamelist.xml if present
  local gamelist_path="${roms_path}/${system}/gamelist.xml"
  if [[ -f "$gamelist_path" ]] && grep -q "Browse Remote ROMs" "$gamelist_path" 2>/dev/null; then
    local temp_gamelist
    temp_gamelist=$(mktemp) || return 1
    _remote_roms_register_temp_file "$temp_gamelist"

    if awk '
      /<game>/ { in_game=1; game_block=$0; next }
      in_game {
        game_block=game_block "\n" $0
        if (/<\/game>/) {
          if (game_block !~ /Browse Remote ROMs/) {
            print game_block
          }
          in_game=0
          game_block=""
        }
        next
      }
      { print }
    ' "$gamelist_path" > "$temp_gamelist"; then
      if mv "$temp_gamelist" "$gamelist_path"; then
        # Remove from tracking since it's been moved (exact match only)
        _REMOTE_ROMS_TEMP_FILES=("${_REMOTE_ROMS_TEMP_FILES[@]/#$temp_gamelist/}")
      else
        log w "Failed to update gamelist.xml for $system"
      fi
    else
      log w "Failed to process gamelist.xml for $system"
    fi
  fi

  log i "ES-DE integration removed for $system"
  return 0
}

remote_roms_set_system_auto_refresh() {
  # Set auto_refresh flag for a system
  # USAGE: remote_roms_set_system_auto_refresh "$system" "true|false"
  # Returns: 0 on success, 1 on failure
  
  local system="$1"
  local value="$2"
  
  # Validate system name
  if ! _remote_roms_validate_system_name "$system"; then
    return 1
  fi
  
  # Validate value
  if [[ "$value" != "true" && "$value" != "false" ]]; then
    log e "Invalid auto_refresh value: '$value' (must be 'true' or 'false')"
    return 1
  fi
  
  remote_roms_set_setting "$system" "auto_refresh" "$value"
}