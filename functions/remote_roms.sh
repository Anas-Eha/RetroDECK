#!/bin/bash

# Remote ROMs Functions
# Provides remote ROM browsing and downloading via WebDAV (extensible for future protocols)
# Uses rclone for all remote operations

# ============================================
# Configuration & Constants
# ============================================

# Define cache directory (XDG_CACHE_HOME falls back to ~/.cache)
readonly RD_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/retrodeck"
readonly REMOTE_ROMS_CACHE_DIR="${RD_CACHE_DIR}/remote_roms"
readonly REMOTE_ROMS_LISTING_FILE="listing.json"
readonly REMOTE_ROMS_GAMELIST_FILE="gamelist.xml"
readonly REMOTE_ROMS_RCLONE_CONFIG_DIR="${XDG_CONFIG_HOME}/retrodeck/rclone"
readonly REMOTE_ROMS_RCLONE_CONFIG_FILE="${REMOTE_ROMS_RCLONE_CONFIG_DIR}/rclone.conf"

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

_remote_roms_validate_remote_url() {
  # Validate remote server URL format (currently supports WebDAV URLs)
  local url="$1"

  if [[ -z "$url" ]]; then
    log e "Server URL cannot be empty"
    return 1
  fi

  # Basic URL validation: must start with http:// or https://
  if [[ ! "$url" =~ ^https?:// ]]; then
    log e "Invalid server URL: '$url' (must start with http:// or https://)"
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
  log d "lock_config: starting, rd_file_lock='$rd_file_lock'"

  if [[ -z "$rd_file_lock" ]]; then
    log e "lock_config: rd_file_lock is empty!"
    return 1
  fi

  if [[ ! -f "$rd_file_lock" ]]; then
    if ! touch "$rd_file_lock"; then
      log e "lock_config: failed to create lock file"
      return 1
    fi
  fi

  if ! eval "exec $_REMOTE_ROMS_LOCK_FD>\"$rd_file_lock\""; then
    log e "lock_config: failed to open file descriptor"
    return 1
  fi

  # Try to acquire exclusive lock with timeout
  if ! flock -n $_REMOTE_ROMS_LOCK_FD; then
    log w "lock_config: waiting for config lock..."
    if ! flock $_REMOTE_ROMS_LOCK_FD; then
      log e "lock_config: failed to acquire lock"
      return 1
    fi
  fi

  log d "lock_config: success"
  return 0
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

_remote_roms_write_rclone_config() {
  # Write rclone config file with secure permissions
  # USAGE: _remote_roms_write_rclone_config "$config_file" "$section" "$url" "$user" "$pass"

  local config_file="$1"
  local section="$2"
  local url="$3"
  local user="$4"
  local pass="$5"
  local protocol="webdav"
  local vendor="other"

  log d "_remote_roms_write_rclone_config: starting"

  # Ensure parent directory exists before writing
  local config_dir
  config_dir="$(dirname "$config_file")"

  if [[ ! -d "$config_dir" ]]; then
    if ! mkdir -p "$config_dir" 2>&1; then
      log e "Failed to create rclone config directory at $config_dir"
      return 1
    fi
    if [[ ! -d "$config_dir" ]]; then
      log e "Directory still does not exist after mkdir -p: $config_dir"
      return 1
    fi
  fi

  # Write config file
  {
    echo "[$section]"
    echo "type = $protocol"
    echo "url = $url"
    echo "vendor = $vendor"
    echo "user = $user"
    echo "pass = $pass"
  } > "$config_file" || {
    log e "Failed to write rclone config file at $config_file"
    return 1
  }



  # Set restricted permissions
  chmod 600 "$config_file" 2>/dev/null || true
  log d "_remote_roms_write_rclone_config: success"
  return 0
}

# ============================================
# Configuration Functions
# ============================================

remote_roms_init_config() {
  # Initialize remote ROMs configuration if not present
  # USAGE: remote_roms_init_config
  # Returns: 0 on success, 1 on failure

  if [[ -z "$rd_conf" ]]; then
    log e "init_config: rd_conf is empty!"
    return 1
  fi

  if [[ ! -f "$rd_conf" ]]; then
    log e "init_config: rd_conf file not found at '$rd_conf'"
    return 1
  fi

  if ! jq -e '.remote_roms' "$rd_conf" > /dev/null 2>&1; then
    log i "init_config: Creating remote_roms configuration"
    local default_config='{
      "remote_protocol": "webdav",
      "remote_url": "",
      "systems": {},
      "remote_rom_enabled": false
    }'

    if ! jq --argjson config "$default_config" '.remote_roms = $config' "$rd_conf" > "$rd_conf.tmp"; then
      log e "init_config: Failed to create remote_roms config"
      rm -f "$rd_conf.tmp"
      return 1
    fi

    if ! mv "$rd_conf.tmp" "$rd_conf"; then
      log e "init_config: Failed to update config file"
      rm -f "$rd_conf.tmp"
      return 1
    fi
    log i "init_config: remote_roms configuration created"
  fi
  return 0
}

remote_roms_get_setting() {
  # Get a remote ROMs setting value (global or system-specific)
  # USAGE: value=$(remote_roms_get_setting "setting_name")
  # USAGE: value=$(remote_roms_get_setting "$system" "property")
  # Returns: Setting value or empty string; exit code 0 always

  if [[ -z "$rd_conf" ]]; then
    echo ""
    return 0
  fi

  if [[ ! -f "$rd_conf" ]]; then
    echo ""
    return 0
  fi

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

  # Validate rd_conf is set and file exists
  if [[ -z "$rd_conf" ]]; then
    log e "set_setting: rd_conf is not set"
    return 1
  fi

  if [[ ! -f "$rd_conf" ]]; then
    log e "set_setting: rd_conf file not found at '$rd_conf'"
    return 1
  fi

  if ! _remote_roms_lock_config; then
    log e "set_setting: Failed to acquire config lock"
    return 1
  fi
  log d "set_setting: lock acquired for $1"

  if [[ $# -eq 2 ]]; then
    # Global setting
    log d "set_setting: updating global setting $1"
    if ! jq --arg val "$2" ".remote_roms.$1 = \$val" "$rd_conf" > "$rd_conf.tmp" 2>&1; then
      log e "set_setting: Failed to update setting $1"
      rm -f "$rd_conf.tmp"
      eval "exec $_REMOTE_ROMS_LOCK_FD>&- 2>/dev/null || true"
      return 1
    fi
    log d "set_setting: global setting $1 updated in temp file"
  else
    # System-specific setting
    local system="$1"
    local property="$2"
    local value="$3"

    if ! _remote_roms_validate_system_name "$system"; then
      eval "exec $_REMOTE_ROMS_LOCK_FD>&- 2>/dev/null || true"
      return 1
    fi

    log d "set_setting: updating system setting $system.$property"
    if ! jq --arg s "$system" --arg p "$property" --arg v "$value" \
      '.remote_roms.systems[$s][$p] = $v' "$rd_conf" > "$rd_conf.tmp" 2>&1; then
      log e "set_setting: Failed to update setting $system.$property"
      rm -f "$rd_conf.tmp"
      eval "exec $_REMOTE_ROMS_LOCK_FD>&- 2>/dev/null || true"
      return 1
    fi
    log d "set_setting: system setting $system.$property updated in temp file"
  fi

  if ! mv "$rd_conf.tmp" "$rd_conf" 2>&1; then
    log e "set_setting: Failed to commit config changes"
    rm -f "$rd_conf.tmp"
    eval "exec $_REMOTE_ROMS_LOCK_FD>&- 2>/dev/null || true"
      return 1
  fi
  log d "set_setting: config committed successfully"

  eval "exec $_REMOTE_ROMS_LOCK_FD>&- 2>/dev/null || true"
  return 0
}

remote_roms_get_remote_creds() {
  # Get remote credentials from rclone.conf (protocol-agnostic)
  # USAGE: eval $(remote_roms_get_remote_creds)  # sets $url, $user, $pass
  # OR: local url=$(remote_roms_get_remote_creds field)
  # NOTE: Uses base64 encoding to safely handle special characters in credentials

  local field="${1:-all}"
  local url=""
  local user=""
  local pass=""

  # Get URL from JSON config (generic key for future protocol support)
  url=$(remote_roms_get_setting "remote_url")

  # Get credentials from RetroDECK's isolated rclone.conf if it exists
  if [[ -f "$REMOTE_ROMS_RCLONE_CONFIG_FILE" ]]; then
    user=$(grep "^user = " "$REMOTE_ROMS_RCLONE_CONFIG_FILE" | head -1 | cut -d'=' -f2- | sed 's/^ *//')
    pass=$(grep "^pass = " "$REMOTE_ROMS_RCLONE_CONFIG_FILE" | head -1 | cut -d'=' -f2- | sed 's/^ *//')
  fi

  case "$field" in
    url)  echo "$url" ;;
    user) echo "$user" ;;
    pass) echo "$pass" ;;
    *)    echo "url=$(echo -n "$url" | base64 -w 0); user=$(echo -n "$user" | base64 -w 0); pass=$(echo -n "$pass" | base64 -w 0)" ;;
  esac
}

remote_roms_save_connection_config() {
  # Save remote connection settings (protocol-agnostic)
  # URL is saved to JSON, credentials are saved to rclone.conf only
  # Currently supports: webdav (protocol value in config)
  # USAGE: remote_roms_save_connection_config "$url" "$user" "$pass"
  # Returns: 0 on success, 1 on failure

  local url="$1"
  local user="$2"
  local pass="$3"

  # Validate XDG_CONFIG_HOME is set
  if [[ -z "$XDG_CONFIG_HOME" ]]; then
    log e "XDG_CONFIG_HOME is not set - cannot determine config directory"
    return 1
  fi

  # Validate inputs
  if ! _remote_roms_validate_remote_url "$url"; then
    log e "URL validation failed for: '$url'"
    return 1
  fi

  if [[ -z "$user" ]]; then
    log e "Username cannot be empty"
    return 1
  fi

  if [[ -z "$pass" ]]; then
    log e "Password cannot be empty"
    return 1
  fi

  # Initialize config if needed before saving
  if ! remote_roms_init_config; then
    log e "Failed to initialize remote ROMs config"
    return 1
  fi

  # Save URL to JSON config only (no credentials)
  if ! remote_roms_set_setting "remote_url" "$url"; then
    log e "Failed to save remote_url to config"
    return 1
  fi

  if ! remote_roms_set_setting "remote_protocol" "webdav"; then
    log e "Failed to save remote_protocol to config"
    return 1
  fi

  # Obscure password once before saving to rclone.conf
  local obscured_pass
  if command -v rclone &>/dev/null; then
    obscured_pass=$(rclone obscure "$pass" 2>/dev/null) || obscured_pass="$pass"
  else
    obscured_pass="$pass"
  fi

  if ! _remote_roms_write_rclone_config "$REMOTE_ROMS_RCLONE_CONFIG_FILE" "retrodeck-remote" "$url" "$user" "$obscured_pass"; then
    log e "Failed to write rclone config to $REMOTE_ROMS_RCLONE_CONFIG_FILE"
    return 1
  fi

  # Verify the file actually exists after writing
  if [[ ! -f "$REMOTE_ROMS_RCLONE_CONFIG_FILE" ]]; then
    log e "rclone config file missing after successful write: $REMOTE_ROMS_RCLONE_CONFIG_FILE"
    return 1
  fi

  log i "Remote configuration saved successfully"
  return 0
}

remote_roms_test_connection() {
  # Test remote server connection
  # USAGE: result=$(remote_roms_test_connection)
  # Returns: "connected", "missing_config", "rclone_not_found", or "connection_failed"

  # Decode base64-encoded credentials to safely handle special characters
  eval $(remote_roms_get_remote_creds)
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

  if ! _remote_roms_write_rclone_config "$rclone_config" "remote-test" "$url" "$user" "$pass"; then
    echo "connection_failed"
    return 1
  fi

  # Test connection with timeout
  local rclone_output
  rclone_output=$(RCLONE_CONFIG="$rclone_config" rclone ls "remote-test:/" --max-depth 1 \
    --contimeout ${REMOTE_ROMS_RCLONE_CONNECT_TIMEOUT}s --timeout ${REMOTE_ROMS_RCLONE_TIMEOUT}s 2>&1)
  local rclone_exit_code=$?

  if [[ $rclone_exit_code -eq 0 ]]; then
    echo "connected"
    return 0
  else
    # Log the actual error for debugging
    log e "Connection test failed: $rclone_output"
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

  # Validate rd_conf is set and file exists
  if [[ -z "$rd_conf" ]]; then
    log e "add_system: rd_conf is not set"
    return 1
  fi

  if [[ ! -f "$rd_conf" ]]; then
    log e "add_system: rd_conf file not found at '$rd_conf'"
    return 1
  fi

  if ! _remote_roms_lock_config; then
    log e "add_system: Failed to acquire config lock"
    return 1
  fi
  log d "add_system: lock acquired, creating system object..."

  log d "add_system: creating system_obj..."
  local system_obj
  system_obj=$(jq -n \
    --arg system "$system" \
    --arg remote_path "$remote_path" \
    '{
      "system": $system,
      "remote_path": $remote_path,
      "enabled": true
    }')
  local jq_exit_code=$?
  log d "add_system: jq for system_obj completed with exit code $jq_exit_code"
  if [[ $jq_exit_code -ne 0 ]] || [[ -z "$system_obj" ]]; then
    log e "add_system: Failed to create system object with jq"
    eval "exec $_REMOTE_ROMS_LOCK_FD>&- 2>/dev/null || true"
    return 1
  fi
  log d "add_system: system_obj created: $system_obj"
  log d "add_system: updating config with rd_conf='$rd_conf'..."

  if ! jq --arg system "$system" --argjson obj "$system_obj" '.remote_roms.systems[$system] = $obj' "$rd_conf" > "$rd_conf.tmp"; then
    log e "add_system: jq failed to update config"
    rm -f "$rd_conf.tmp"
    eval "exec $_REMOTE_ROMS_LOCK_FD>&- 2>/dev/null || true"
    return 1
  fi
  log d "add_system: config updated in temp file"

  if ! mv "$rd_conf.tmp" "$rd_conf"; then
    log e "add_system: Failed to commit system addition (mv failed)"
    rm -f "$rd_conf.tmp"
    eval "exec $_REMOTE_ROMS_LOCK_FD>&- 2>/dev/null || true"
    return 1
  fi
  log d "add_system: config committed"
  log d "add_system: system='$system'"
  log d "add_system: remote_path='$remote_path'"
  log d "add_system: freeing lock file='$rd_file_lock'"

  eval "exec $_REMOTE_ROMS_LOCK_FD>&- 2>/dev/null || true"
  log i "Added remote ROM system: $system"
  return 0
}

remote_roms_remove_system() {
  # Validate rd_conf is set and file exists
  if [[ -z "$rd_conf" ]]; then
    log e "remove_system: rd_conf is not set"
    return 1
  fi

  if [[ ! -f "$rd_conf" ]]; then
    log e "remove_system: rd_conf file not found at '$rd_conf'"
    return 1
  fi

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
    eval "exec $_REMOTE_ROMS_LOCK_FD>&- 2>/dev/null || true"
    rm -f "$rd_conf.tmp"
    log e "Failed to remove system $system"
    return 1
  fi

  if ! mv "$rd_conf.tmp" "$rd_conf"; then
    eval "exec $_REMOTE_ROMS_LOCK_FD>&- 2>/dev/null || true"
    rm -f "$rd_conf.tmp"
    log e "Failed to commit system removal"
    return 1
  fi

  eval "exec $_REMOTE_ROMS_LOCK_FD>&- 2>/dev/null || true"
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
  # Auto-discover systems on remote server
  # Scans default paths if no argument provided, or specific path if provided
  # USAGE: discovered=$(remote_roms_discover_systems)           # Quick scan
  # USAGE: discovered=$(remote_roms_discover_systems "$path") # Scan specific path
  # Returns: 0 on success (JSON object), 1 on failure (empty JSON)

  local custom_path="${1:-}"

  # Decode base64-encoded credentials to safely handle special characters
  eval $(remote_roms_get_remote_creds)
  url=$(echo "$url" | base64 -d)
  user=$(echo "$user" | base64 -d)
  pass=$(echo "$pass" | base64 -d)

  if [[ -z "$url" || -z "$user" ]]; then
    echo "{}"
    return 1
  fi

  # Create temporary rclone config
  local rclone_config
  rclone_config=$(mktemp) || { echo "{}"; return 1; }
  _REMOTE_ROMS_TEMP_RCLONE_CONFIG="$rclone_config"

  if ! _remote_roms_write_rclone_config "$rclone_config" "remote-discover" "$url" "$user" "$pass"; then
    echo "{}"
    return 1
  fi

  local available_systems=$(remote_roms_get_available_systems)
  local discovered="{}"

  # Determine which paths to scan
  local scan_paths=()
  if [[ -n "$custom_path" ]]; then
    # Single user-provided path
    scan_paths=("$custom_path")
    remote_roms_log_debug "discovery: scanning custom path '$custom_path'"
  else
    # Default quick scan paths
    scan_paths=("/" "/roms" "/games" "/library")
  fi

  # Scan selected paths
  for scan_path in "${scan_paths[@]}"; do
    local rclone_path="$scan_path"
    [[ "$scan_path" != "/" ]] && rclone_path="${scan_path#/}" # Remove leading slash except for root

    local folders=$(RCLONE_CONFIG="$rclone_config" rclone lsf "remote-discover:/$rclone_path" \
      --max-depth 1 --dirs-only 2>/dev/null | sed 's|/$||')

    while IFS= read -r folder; do
      [[ -z "$folder" ]] && continue

      # Validate folder name before processing
      if ! _remote_roms_validate_system_name "$folder"; then
        continue
      fi

      # Build full path
      local full_path="$folder"
      [[ "$scan_path" != "/" ]] && full_path="${scan_path#/}/$folder"

      # Check if folder name matches a known system
      for sys in $available_systems; do
        if [[ "$folder" == "$sys" ]]; then
          # Only add if not already found (prefer shorter paths)
          if ! echo "$discovered" | jq -e --arg s "$sys" 'has($s)' > /dev/null 2>&1; then
            discovered=$(echo "$discovered" | jq --arg s "$sys" --arg p "$full_path" '.[$s] = $p')
            remote_roms_log_debug "discovery: found $sys at $full_path"
          fi
          break
        fi
      done
    done <<< "$folders"
  done

  local final_count=$(echo "$discovered" | jq 'length')
  if [[ -n "$custom_path" ]]; then
    remote_roms_log_debug "discovery: custom scan complete, found $final_count systems at '$custom_path'"
  else
    remote_roms_log_debug "discovery: quick scan complete, found $final_count systems"
  fi

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
  eval $(remote_roms_get_remote_creds)
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

  mkdir -p "$REMOTE_ROMS_RCLONE_CONFIG_DIR" || {
    log e "Failed to create rclone directory at $REMOTE_ROMS_RCLONE_CONFIG_DIR"
    return 1
  }

  if ! _remote_roms_write_rclone_config "$REMOTE_ROMS_RCLONE_CONFIG_FILE" "retrodeck-remote" "$url" "$user" "$pass"; then
    log e "Failed to write rclone config"
    return 1
  fi

  # Export environment variable so rclone knows where to find the config
  export RCLONE_CONFIG="$REMOTE_ROMS_RCLONE_CONFIG_FILE"
  log d "generate_rclone_config: set RCLONE_CONFIG=$REMOTE_ROMS_RCLONE_CONFIG_FILE"
}

remote_roms_fetch_gamelist() {
  # Fetch gamelist.xml from remote server
  # NOTE: Caller must ensure rclone config exists (call remote_roms_generate_rclone_config first)
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

  # Get remote path
  local remote_path=$(remote_roms_get_setting "$system" "remote_path")
  if [[ -z "$remote_path" ]]; then
    log w "fetch_gamelist: no remote_path configured for $system"
    return 1
  fi

  log d "fetch_gamelist: fetching gamelist.xml from retrodeck-remote:${remote_path}/gamelist.xml"

  # Try to fetch gamelist.xml from remote (capture stderr for debugging)
  local temp_file
  temp_file=$(mktemp) || return 1
  _REMOTE_ROMS_TEMP_FILES+=("$temp_file")

  local rclone_output
  rclone_output=$(rclone --config "$REMOTE_ROMS_RCLONE_CONFIG_FILE" copyto "retrodeck-remote:${remote_path}/gamelist.xml" "$temp_file" 2>&1)
  local rclone_rc=$?

  if [[ $rclone_rc -eq 0 ]]; then
    log d "fetch_gamelist: downloaded gamelist.xml ($(stat -c%s "$temp_file" 2>/dev/null || echo 'unknown') bytes)"
    mv "$temp_file" "$gamelist_path" || return 1
    return 0
  else
    log w "fetch_gamelist: rclone failed - exit code $rclone_rc: $rclone_output"
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
    log d "build_listing_from_gamelist: gamelist_path not found: $gamelist_path"
    echo "[]"
    return 1
  fi

  log d "build_listing_from_gamelist: processing $gamelist_path"

  # Verify XML is valid
  if ! xmlstarlet val "$gamelist_path" > /dev/null 2>&1; then
    log w "Invalid XML in gamelist.xml for $system"
    echo "[]"
    return 1
  fi

  # Get game count
  local game_count=$(xmlstarlet sel -t -v "count(//game)" "$gamelist_path" 2>/dev/null)
  log d "build_listing_from_gamelist: found $game_count games"

  if [[ -z "$game_count" || "$game_count" -eq 0 ]]; then
    log w "No games found in gamelist.xml for $system"
    echo "[]"
    return 1
  fi

  log d "build_listing_from_gamelist: extracting game data from gamelist.xml"

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
  # NOTE: Caller must ensure rclone config exists (call remote_roms_generate_rclone_config first)
  # USAGE: listing=$(remote_roms_build_listing_from_directory "$system")

  local system="$1"
  local remote_path=$(remote_roms_get_setting "$system" "remote_path")

  if [[ -z "$remote_path" ]]; then
    echo "[]"
    return 1
  fi

  # Fetch listing with rclone lsjson
  local temp_file
  temp_file=$(mktemp) || return 1
  _REMOTE_ROMS_TEMP_FILES+=("$temp_file")

  if rclone --config "$REMOTE_ROMS_RCLONE_CONFIG_FILE" lsjson "retrodeck-remote:${remote_path}" --recursive > "$temp_file" 2>/dev/null; then
    # Filter only files and format
    jq '[.[] | select(.IsDir == false) | {
      "name": .Name,
      "display_name": .Name,
      "size": .Size,
      "path": .Path,
      "modtime": .ModTime
    }]' "$temp_file"
    return 0
  else
    echo "[]"
    return 1
  fi
}

remote_roms_convert_gamelist_for_esde() {
  # Convert a gamelist.xml for ES-DE, changing paths to ./remote/<romname>
  # Outputs gamelist entries as XML string for merging
  # USAGE: xml_entries=$(remote_roms_convert_gamelist_for_esde "$system" "$gamelist_path")

  local system="$1"
  local gamelist_path="$2"

  if [[ ! -f "$gamelist_path" ]]; then
    echo ""
    return 1
  fi

  # Use xmlstarlet ed to edit the XML in-place (copy mode)
  # Change all path values from ./filename to ./remote/filename
  xmlstarlet ed \
    -u "//game/path" -x "concat('./remote/', substring-after(., './'))" \
    "$gamelist_path" 2>/dev/null | \
  xmlstarlet sel -t -m "//game" -c . -n 2>/dev/null | \
  sed 's/^/  /'
}

remote_roms_build_gamelist_from_json() {
  # Build gamelist.xml entries from JSON listing (for directory-based discovery)
  # Outputs XML game entries
  # USAGE: xml_entries=$(remote_roms_build_gamelist_from_json "$system" "$roms_json")

  local system="$1"
  local roms_json="$2"

  if [[ -z "$roms_json" || "$roms_json" == "[]" ]]; then
    echo ""
    return 1
  fi

  # Generate game entries from JSON
  echo "$roms_json" | jq -r '.[] | [
    "  <game>",
    "    <path>./remote/" + .name + "</path>",
    "    <name>" + .display_name + "</name>",
    "    <desc>Remote ROM</desc>",
    "  </game>"
  ] | .[]'
}

remote_roms_update_esde_gamelist() {
  # Merge or create ES-DE gamelist.xml with remote ROM entries
  # Removes old remote ROM entries first, then adds new ones
  # USAGE: remote_roms_update_esde_gamelist "$system" "$new_xml_entries"

  local system="$1"
  local new_xml_entries="$2"
  local esde_gamelist_path="${rd_home_path}/ES-DE/gamelists/${system}/gamelist.xml"
  local esde_gamelist_dir="$(dirname "$esde_gamelist_path")"

  # Ensure gamelist directory exists
  mkdir -p "$esde_gamelist_dir" || {
    log e "Failed to create gamelist directory: $esde_gamelist_dir"
    return 1
  }

  # Create temp file for new gamelist
  local temp_gamelist
  temp_gamelist=$(mktemp) || return 1
  [[ -n "$temp_gamelist" ]] && _REMOTE_ROMS_TEMP_FILES+=("$temp_gamelist")

  log d "update_esde_gamelist: building new gamelist at $esde_gamelist_path"
  log d "update_esde_gamelist: new_xml_entries length=${#new_xml_entries}"

  # Build new gamelist content
  {
    echo "<?xml version=\"1.0\"?>"
    echo "<gameList>"

    # If existing gamelist exists, copy non-remote entries
    if [[ -f "$esde_gamelist_path" ]]; then
      log d "update_esde_gamelist: merging with existing ES-DE gamelist: $esde_gamelist_path"
      # Extract games that don't have ./remote/ paths
      xmlstarlet sel -t -m "//game[not(starts-with(path, './remote/'))]" -c . -n "$esde_gamelist_path" 2>/dev/null | sed 's/^/  /'
    else
      log d "update_esde_gamelist: no existing gamelist, creating new one"
    fi

    # Add new remote ROM entries
    echo "$new_xml_entries"

    echo "</gameList>"
  } > "$temp_gamelist"

  log d "update_esde_gamelist: temp gamelist created at $temp_gamelist"
  log d "update_esde_gamelist: temp file size=$(stat -c%s "$temp_gamelist" 2>/dev/null || echo 'unknown')"

  # Validate the XML before moving
  if xmlstarlet val "$temp_gamelist" > /dev/null 2>&1; then
    log d "update_esde_gamelist: XML validation passed"
    if mv "$temp_gamelist" "$esde_gamelist_path"; then
      _REMOTE_ROMS_TEMP_FILES=("${_REMOTE_ROMS_TEMP_FILES[@]/#$temp_gamelist/}")
      log d "update_esde_gamelist: successfully updated ES-DE gamelist at: $esde_gamelist_path"
      return 0
    else
      log e "Failed to move gamelist to: $esde_gamelist_path"
      return 1
    fi
  else
    log e "Generated gamelist.xml is invalid XML, temp file content:"
    cat "$temp_gamelist" | head -20 | while read line; do log e "  $line"; done
    return 1
  fi
}

remote_roms_refresh_system_listing() {
  # Refresh ROM listing for a system and update ES-DE gamelist.xml
  # Fetches gamelist.xml from remote, converts paths to ./remote/<romname>
  # and merges/creates local ES-DE gamelist.xml
  # Falls back to building from directory listing if no remote gamelist
  # USAGE: remote_roms_refresh_system_listing "$system"
  # Returns: 0 on success, 1 on failure

  local system="$1"
  local cache_dir="${REMOTE_ROMS_CACHE_DIR}/${system}"
  local cache_file="${cache_dir}/${REMOTE_ROMS_LISTING_FILE}"

  log d "refresh_system_listing: starting for system=$system"

  # Validate rd_home_path is set
  if [[ -z "$rd_home_path" ]]; then
    log e "refresh_system_listing: rd_home_path is not set!"
    return 1
  fi

  local esde_gamelist_path="${rd_home_path}/ES-DE/gamelists/${system}/gamelist.xml"

  # Generate rclone config once - all sub-functions will use this
  if ! remote_roms_generate_rclone_config; then
    log e "refresh_system_listing: failed to generate rclone config"
    return 1
  fi

  # Try to fetch gamelist.xml from remote
  local gamelist_xml_content=""
  local roms_json=""

  if remote_roms_fetch_gamelist "$system"; then
    local remote_gamelist_path="${cache_dir}/${REMOTE_ROMS_GAMELIST_FILE}"
    log d "refresh_system_listing: fetched remote gamelist"

    # Parse gamelist.xml and convert paths to ./remote/<romname>
    gamelist_xml_content=$(remote_roms_convert_gamelist_for_esde "$system" "$remote_gamelist_path")
    roms_json=$(remote_roms_build_listing_from_gamelist "$system" "$remote_gamelist_path")
  else
    log d "refresh_system_listing: no remote gamelist, trying directory listing"
  fi

  # If no gamelist or gamelist failed, build from directory
  if [[ -z "$roms_json" || "$roms_json" == "[]" ]]; then
    roms_json=$(remote_roms_build_listing_from_directory "$system")
    log d "refresh_system_listing: directory listing length=${#roms_json}"

    # Build gamelist.xml from directory listing
    if [[ -n "$roms_json" && "$roms_json" != "[]" ]]; then
      gamelist_xml_content=$(remote_roms_build_gamelist_from_json "$system" "$roms_json")
    fi
  fi

  # Save listing to cache
  if [[ -n "$roms_json" && "$roms_json" != "[]" ]]; then
    echo "$roms_json" > "$cache_file"
    local count=$(echo "$roms_json" | jq 'length')
    log i "Cached $count ROMs for $system"
  else
    log w "refresh_system_listing: no roms_json to cache"
  fi

  # Update ES-DE gamelist.xml with remote ROMs
  if [[ -n "$gamelist_xml_content" ]]; then
    if remote_roms_update_esde_gamelist "$system" "$gamelist_xml_content"; then
      log i "Updated ES-DE gamelist.xml for $system with remote ROMs"
      return 0
    else
      log e "refresh_system_listing: failed to update ES-DE gamelist"
      return 1
    fi
  else
    log w "No gamelist_xml_content generated for $system"
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
  [[ -n "$temp_file" ]] && _REMOTE_ROMS_TEMP_FILES+=("$temp_file")

  log i "Downloading $rom_name from remote..."

  # Use rclone copyto with timeouts
  if rclone --config "$REMOTE_ROMS_RCLONE_CONFIG_FILE" copyto "retrodeck-remote:${remote_path}/${rom_name}" "$temp_file" \
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
# Remote ROMs Management Functions
# ============================================

remote_roms_create_esde_integration() {
  # Create ES-DE integration for remote ROM browsing
  # Creates a "remote" folder for storing downloaded ROMs
  # The gamelist.xml is now created/updated by remote_roms_refresh_system_listing
  # USAGE: remote_roms_create_esde_integration "$system"
  # Returns: 0 on success, 1 on failure

  local system="$1"

  # Validate system name
  if ! _remote_roms_validate_system_name "$system"; then
    return 1
  fi

  local system_roms_path="${roms_path}/${system}"
  local remote_folder="${system_roms_path}/remote"

  # Create remote folder for storing downloaded ROMs
  mkdir -p "$remote_folder" || {
    log e "Failed to create remote folder for $system"
    return 1
  }

  # Note: The gamelist.xml for remote ROMs is now managed by
  # remote_roms_refresh_system_listing and remote_roms_update_esde_gamelist
  # which fetch the gamelist from the remote server and convert paths

  log i "ES-DE integration created for $system (remote folder ready)"
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

  # Remove remote folder and any downloaded ROMs
  if [[ -d "$remote_folder" ]]; then
    rm -rf "$remote_folder" || {
      log w "Failed to remove remote folder for $system"
    }
  fi

  # Remove remote ROM entries from ES-DE gamelist.xml
  local esde_gamelist_path="${rd_home_path}/ES-DE/gamelists/${system}/gamelist.xml"
  if [[ -f "$esde_gamelist_path" ]]; then
    local temp_gamelist
    temp_gamelist=$(mktemp) || return 1
    [[ -n "$temp_gamelist" ]] && _REMOTE_ROMS_TEMP_FILES+=("$temp_gamelist")

    # Remove games with ./remote/ paths (remote ROM entries)
    if xmlstarlet sel -t -m "//game[not(starts-with(path, './remote/'))]" -c . -n "$esde_gamelist_path" 2>/dev/null > "$temp_gamelist"; then
      # Reconstruct valid gamelist.xml
      {
        echo "<?xml version=\"1.0\"?>"
        echo "<gameList>"
        cat "$temp_gamelist"
        echo "</gameList>"
      } > "${temp_gamelist}.xml"

      if xmlstarlet val "${temp_gamelist}.xml" > /dev/null 2>&1; then
        mv "${temp_gamelist}.xml" "$esde_gamelist_path"
        _REMOTE_ROMS_TEMP_FILES=("${_REMOTE_ROMS_TEMP_FILES[@]/#$temp_gamelist/}")
        rm -f "$temp_gamelist"
      else
        log w "Generated gamelist.xml was invalid, not updating"
        rm -f "${temp_gamelist}.xml"
      fi
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

remote_roms_startup_auto_refresh() {
  # Startup hook: Auto-refresh ROM listings for systems with auto_refresh=true
  # Runs silently in background during startup
  # USAGE: remote_roms_startup_auto_refresh

  # Check if remote ROMs is globally enabled
  local remote_rom_enabled=$(remote_roms_get_setting "remote_rom_enabled")
  [[ "$remote_rom_enabled" != "true" ]] && return 0

  # Get all systems with auto_refresh enabled
  local systems=$(remote_roms_get_setting "systems")
  local auto_refresh_systems=$(echo "$systems" | jq -r '[.[] | select(.auto_refresh == true) | .system] | .[]')

  [[ -z "$auto_refresh_systems" ]] && return 0

  log i "Auto-refreshing remote ROM listings for enabled systems"

  while IFS= read -r system; do
    [[ -z "$system" ]] && continue
    log d "Auto-refreshing $system..."
    remote_roms_refresh_system_listing "$system" &
  done <<< "$auto_refresh_systems"

  # Don't wait for background jobs - let them complete asynchronously
}
