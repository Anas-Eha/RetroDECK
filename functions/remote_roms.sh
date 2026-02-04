#!/bin/bash

# Remote ROMs Folder Management Functions
# This file handles mounting remote WebDAV folders using rclone with VFS caching

# Default rclone VFS settings
# Note: VFS cache is optional since we explicitly copy files locally
# The cache only helps with directory listing and copy performance
readonly REMOTE_ROMS_DEFAULT_VFS_CACHE_MODE="writes"
readonly REMOTE_ROMS_DEFAULT_VFS_READ_AHEAD="0"
readonly REMOTE_ROMS_DEFAULT_VFS_CACHE_MAX_SIZE="500M"

# Debug log file for remote_roms operations
readonly REMOTE_ROMS_DEBUG_LOG="$rd_xdg_config_logs_path/remote_roms_debug.log"

# Helper function for remote_roms debug logging
remote_roms_log_debug() {
  local message="$1"
  local timestamp="$(date +[%Y-%m-%d\ %H:%M:%S.%3N])"
  echo "$timestamp [REMOTE_ROMS_DEBUG] $message" >> "$REMOTE_ROMS_DEBUG_LOG"
  # Also log via standard log function if debug level is enabled
  log d "[REMOTE_ROMS] $message"
}

# ============================================
# Configuration Functions
# ============================================

remote_roms_init_config() {
  # Initialize remote ROMs configuration if not present
  # USAGE: remote_roms_init_config

  remote_roms_log_debug "init_config: Starting initialization check"
  remote_roms_log_debug "init_config: rd_conf path: $rd_conf"

  if ! jq -e '.remote_roms' "$rd_conf" > /dev/null 2>&1; then
    log i "Creating remote_roms configuration"
    remote_roms_log_debug "init_config: remote_roms section not found, creating default config"
    local default_config='{
      "webdav_url": "",
      "webdav_user": "",
      "webdav_pass": "",
      "vfs_cache_mode": "'"$REMOTE_ROMS_DEFAULT_VFS_CACHE_MODE"'",
      "vfs_read_ahead": "'"$REMOTE_ROMS_DEFAULT_VFS_READ_AHEAD"'",
      "vfs_cache_max_size": "'"$REMOTE_ROMS_DEFAULT_VFS_CACHE_MAX_SIZE"'",
      "mounts": {},
      "global_enabled": false
    }'
    jq --argjson config "$default_config" '.remote_roms = $config' "$rd_conf" > "$rd_conf.tmp" && mv "$rd_conf.tmp" "$rd_conf"
    remote_roms_log_debug "init_config: Default config created successfully"
  else
    remote_roms_log_debug "init_config: remote_roms section already exists"
  fi
}

remote_roms_get_setting() {
  # Get a remote ROMs setting value
  # USAGE: value=$(remote_roms_get_setting "setting_name")
  jq -r ".remote_roms.$1 // empty" "$rd_conf"
}

remote_roms_set_setting() {
  # Set a remote ROMs setting value
  # USAGE: remote_roms_set_setting "setting_name" "value"
  jq --arg val "$2" ".remote_roms.$1 = \$val" "$rd_conf" > "$rd_conf.tmp" && mv "$rd_conf.tmp" "$rd_conf"
}

# ============================================
# WebDAV Configuration
# ============================================

remote_roms_save_webdav_config() {
  # Save WebDAV connection settings
  # USAGE: remote_roms_save_webdav_config "$url" "$user" "$pass"
  remote_roms_set_setting "webdav_url" "$1"
  remote_roms_set_setting "webdav_user" "$2"
  remote_roms_set_setting "webdav_pass" "$3"
  log i "WebDAV configuration saved"
}

remote_roms_test_connection() {
  # Test WebDAV connection
  # USAGE: result=$(remote_roms_test_connection)
  # Returns: "connected", "missing_config", "rclone_not_found", or "connection_failed"

  remote_roms_log_debug "test_connection: ====== START CONNECTION TEST ======"

  local url=$(remote_roms_get_setting "webdav_url")
  local user=$(remote_roms_get_setting "webdav_user")
  local pass=$(remote_roms_get_setting "webdav_pass")

  remote_roms_log_debug "test_connection: URL: ${url:-'(not set)'}"
  remote_roms_log_debug "test_connection: User: ${user:-'(not set)'}"
  remote_roms_log_debug "test_connection: Password set: $([[ -n "$pass" ]] && echo 'yes' || echo 'no')"

  remote_roms_log_debug "test_connection: URL: ${url:-'(not set)'}"
  remote_roms_log_debug "test_connection: User: ${user:-'(not set)'}"
  remote_roms_log_debug "test_connection: Password set: $([[ -n "$pass" ]] && echo 'yes' || echo 'no')"

  # Check for missing configuration
  if [[ -z "$url" || -z "$user" ]]; then
    remote_roms_log_debug "test_connection: ERROR - Missing config (url or user empty)"
    remote_roms_log_debug "test_connection: ERROR - Missing config (url or user empty)"
    echo "missing_config"
    return 1
  fi

  # Check if rclone is available
  if ! command -v rclone &> /dev/null; then
    remote_roms_log_debug "test_connection: ERROR - rclone command not found in PATH"
    remote_roms_log_debug "test_connection: PATH=$PATH"
    remote_roms_log_debug "test_connection: ERROR - rclone command not found in PATH"
    remote_roms_log_debug "test_connection: PATH=$PATH"
    echo "rclone_not_found"
    return 1
  fi

  remote_roms_log_debug "test_connection: rclone found at: $(command -v rclone)"
  remote_roms_log_debug "test_connection: rclone version: $(rclone version 2>/dev/null | head -1 || echo 'unknown')"

  remote_roms_log_debug "test_connection: rclone found at: $(command -v rclone)"
  remote_roms_log_debug "test_connection: rclone version: $(rclone version 2>/dev/null | head -1 || echo 'unknown')"

  # Create temporary rclone config
  local rclone_config
  rclone_config=$(mktemp)
  local obscured_pass
  obscured_pass=$(rclone obscure "$pass" 2>/dev/null || echo "$pass")

  remote_roms_log_debug "test_connection: Created temp config: $rclone_config"

  remote_roms_log_debug "test_connection: Created temp config: $rclone_config"

  cat > "$rclone_config" << EOF
[webdav-test]
type = webdav
url = $url
vendor = other
user = $user
pass = $obscured_pass
EOF

  remote_roms_log_debug "test_connection: Testing connection to: $url"

  remote_roms_log_debug "test_connection: Testing connection to: $url"

  # Test connection with timeout
  local test_result
  local rclone_output
  rclone_output=$(RCLONE_CONFIG="$rclone_config" rclone ls "webdav-test:/" --max-depth 1 --contimeout 10s --timeout 10s 2>&1)
  local rclone_exit_code=$?

  if [[ $rclone_exit_code -eq 0 ]]; then
  local rclone_output
  rclone_output=$(RCLONE_CONFIG="$rclone_config" rclone ls "webdav-test:/" --max-depth 1 --contimeout 10s --timeout 10s 2>&1)
  local rclone_exit_code=$?

  if [[ $rclone_exit_code -eq 0 ]]; then
    test_result="connected"
    remote_roms_log_debug "test_connection: Connection SUCCESS"
    remote_roms_log_debug "test_connection: Connection SUCCESS"
  else
    test_result="connection_failed"
    remote_roms_log_debug "test_connection: Connection FAILED (exit code: $rclone_exit_code)"
    remote_roms_log_debug "test_connection: rclone error output: $rclone_output"
    remote_roms_log_debug "test_connection: Connection FAILED (exit code: $rclone_exit_code)"
    remote_roms_log_debug "test_connection: rclone error output: $rclone_output"
  fi

  # Cleanup

  # Cleanup
  rm -f "$rclone_config"
  remote_roms_log_debug "test_connection: Cleaned up temp config"

  remote_roms_log_debug "test_connection: ====== END CONNECTION TEST (result: $test_result) ======"
  remote_roms_log_debug "test_connection: Cleaned up temp config"

  remote_roms_log_debug "test_connection: ====== END CONNECTION TEST (result: $test_result) ======"

  echo "$test_result"
  [[ "$test_result" == "connected" ]]
}

# ============================================
# Mount Management
# ============================================

remote_roms_add_mount() {
  # Add a system mount configuration
  # USAGE: remote_roms_add_mount "$system" "$remote_path" "$cache_size"

  local system="$1"
  local remote_path="$2"
  local cache_size="${3:-}"

  remote_roms_log_debug "add_mount: ====== ADDING MOUNT ======"
  remote_roms_log_debug "add_mount: system=$system"
  remote_roms_log_debug "add_mount: remote_path=$remote_path"
  remote_roms_log_debug "add_mount: cache_size=${cache_size:-'(default)'}"

  remote_roms_log_debug "add_mount: ====== ADDING MOUNT ======"
  remote_roms_log_debug "add_mount: system=$system"
  remote_roms_log_debug "add_mount: remote_path=$remote_path"
  remote_roms_log_debug "add_mount: cache_size=${cache_size:-'(default)'}"

  local mount_obj=$(jq -n \
    --arg system "$system" \
    --arg remote_path "$remote_path" \
    --arg cache_size "$cache_size" \
    '{
      "system": $system,
      "remote_path": $remote_path,
      "enabled": true,
      "automount": false,
      "automount": false,
      "cache_size": (if $cache_size == "" then null else $cache_size end)
    }')

  jq --arg system "$system" --argjson obj "$mount_obj" '.remote_roms.mounts[$system] = $obj' "$rd_conf" > "$rd_conf.tmp" && mv "$rd_conf.tmp" "$rd_conf"
  log i "Added mount for $system"
  remote_roms_log_debug "add_mount: Mount added successfully"
  remote_roms_log_debug "add_mount: ====== END ADD MOUNT ======"
  remote_roms_log_debug "add_mount: Mount added successfully"
  remote_roms_log_debug "add_mount: ====== END ADD MOUNT ======"
}

remote_roms_remove_mount() {
  # Remove a system mount configuration
  # USAGE: remote_roms_remove_mount "$system"

  local system="$1"
  remote_roms_unmount_system "$system"
  jq --arg s "$system" 'del(.remote_roms.mounts[$s])' "$rd_conf" > "$rd_conf.tmp" && mv "$rd_conf.tmp" "$rd_conf"
  log i "Removed mount for $system"
}

remote_roms_toggle_mount() {
  # Enable/disable a mount
  # USAGE: remote_roms_toggle_mount "$system" "true|false"

  local system="$1"
  local enabled="$2"
  jq --arg s "$system" --argjson e "$enabled" '.remote_roms.mounts[$s].enabled = $e' "$rd_conf" > "$rd_conf.tmp" && mv "$rd_conf.tmp" "$rd_conf"
}

remote_roms_set_mount_automount() {
  # Enable/disable auto-mount for a system
  # USAGE: remote_roms_set_mount_automount "$system" "true|false"

  local system="$1"
  local automount="$2"

  remote_roms_log_debug "set_mount_automount: Setting automount for $system to $automount"

  jq --arg s "$system" --argjson a "$automount" '.remote_roms.mounts[$s].automount = $a' "$rd_conf" > "$rd_conf.tmp" && mv "$rd_conf.tmp" "$rd_conf"

  log i "Auto-mount for $system set to $automount"
  remote_roms_log_debug "set_mount_automount: Auto-mount setting updated"
}

remote_roms_set_mount_automount() {
  # Enable/disable auto-mount for a system
  # USAGE: remote_roms_set_mount_automount "$system" "true|false"

  local system="$1"
  local automount="$2"

  remote_roms_log_debug "set_mount_automount: Setting automount for $system to $automount"

  jq --arg s "$system" --argjson a "$automount" '.remote_roms.mounts[$s].automount = $a' "$rd_conf" > "$rd_conf.tmp" && mv "$rd_conf.tmp" "$rd_conf"

  log i "Auto-mount for $system set to $automount"
  remote_roms_log_debug "set_mount_automount: Auto-mount setting updated"
}

remote_roms_get_mounts() {
  # Get all mount configurations
  jq '.remote_roms.mounts // {}' "$rd_conf"
}

# ============================================
# Rclone Operations
# ============================================

remote_roms_generate_rclone_config() {
  # Generate rclone config file
  # USAGE: remote_roms_generate_rclone_config
  # Side Effects: Creates/overwrites $XDG_CONFIG_HOME/rclone/rclone.conf

  local url user pass rclone_dir obscured_pass

  remote_roms_log_debug "generate_rclone_config: Starting config generation"

  remote_roms_log_debug "generate_rclone_config: Starting config generation"

  url=$(remote_roms_get_setting "webdav_url")
  user=$(remote_roms_get_setting "webdav_user")
  pass=$(remote_roms_get_setting "webdav_pass")

  remote_roms_log_debug "generate_rclone_config: URL configured: ${url:-'(empty)'}"
  remote_roms_log_debug "generate_rclone_config: User configured: ${user:-'(empty)'}"
  remote_roms_log_debug "generate_rclone_config: Password is set: $([[ -n "$pass" ]] && echo 'yes' || echo 'no')"

  remote_roms_log_debug "generate_rclone_config: URL configured: ${url:-'(empty)'}"
  remote_roms_log_debug "generate_rclone_config: User configured: ${user:-'(empty)'}"
  remote_roms_log_debug "generate_rclone_config: Password is set: $([[ -n "$pass" ]] && echo 'yes' || echo 'no')"

  rclone_dir="$XDG_CONFIG_HOME/rclone"
  mkdir -p "$rclone_dir"
  remote_roms_log_debug "generate_rclone_config: rclone config dir: $rclone_dir"

  # Check if rclone is available
  if ! command -v rclone &> /dev/null; then
    remote_roms_log_debug "generate_rclone_config: ERROR - rclone command not found!"
    log e "rclone not found in PATH. Cannot generate config."
    return 1
  fi

  remote_roms_log_debug "generate_rclone_config: rclone binary found at: $(command -v rclone)"
  remote_roms_log_debug "generate_rclone_config: rclone version: $(rclone version 2>/dev/null | head -1 || echo 'unknown')"
  remote_roms_log_debug "generate_rclone_config: rclone config dir: $rclone_dir"

  # Check if rclone is available
  if ! command -v rclone &> /dev/null; then
    remote_roms_log_debug "generate_rclone_config: ERROR - rclone command not found!"
    log e "rclone not found in PATH. Cannot generate config."
    return 1
  fi

  remote_roms_log_debug "generate_rclone_config: rclone binary found at: $(command -v rclone)"
  remote_roms_log_debug "generate_rclone_config: rclone version: $(rclone version 2>/dev/null | head -1 || echo 'unknown')"

  obscured_pass=$(rclone obscure "$pass" 2>/dev/null || echo "$pass")

  cat > "$rclone_dir/rclone.conf" << EOF
[retrodeck-webdav]
type = webdav
url = $url
vendor = other
user = $user
pass = $obscured_pass
EOF

  # Secure the config file (contains credentials)
  chmod 600 "$rclone_dir/rclone.conf"
  remote_roms_log_debug "generate_rclone_config: Config file created at: $rclone_dir/rclone.conf"
  remote_roms_log_debug "generate_rclone_config: Config file permissions: $(stat -c %a "$rclone_dir/rclone.conf" 2>/dev/null || echo 'unknown')"
  remote_roms_log_debug "generate_rclone_config: Config file created at: $rclone_dir/rclone.conf"
  remote_roms_log_debug "generate_rclone_config: Config file permissions: $(stat -c %a "$rclone_dir/rclone.conf" 2>/dev/null || echo 'unknown')"
}

remote_roms_mount_system() {
  # Mount a specific system
  # Remote is mounted to roms/<system>/remote/ (visible)
  # Downloaded files go to roms/<system>/ (local cache)
  # Remote is mounted to roms/<system>/remote/ (visible)
  # Downloaded files go to roms/<system>/ (local cache)
  # USAGE: remote_roms_mount_system "$system"

  local system system_path remote_visible mount_config enabled remote_path
  local custom_cache cache_mode read_ahead cache_size

  system="$1"
  system_path="$roms_path/$system"
  remote_visible="$roms_path/$system/remote"

  remote_roms_log_debug "mount_system: ====== START MOUNT FOR $system ======"
  remote_roms_log_debug "mount_system: system=$system"
  remote_roms_log_debug "mount_system: system_path=$system_path"
  remote_roms_log_debug "mount_system: remote_visible=$remote_visible"
  remote_roms_log_debug "mount_system: roms_path=$roms_path"

  # Check if FUSE is available
  local fuse_status
  fuse_status=$(remote_roms_check_fuse)
  if [[ "$fuse_status" == "none" ]]; then
    log e "FUSE not available - cannot mount $system"
    remote_roms_log_debug "mount_system: ERROR - FUSE (fusermount3/fusermount) not found"
    remote_roms_log_debug "mount_system: Running FUSE diagnosis..."
    remote_roms_diagnose_fuse
    return 1
  fi
  remote_roms_log_debug "mount_system: FUSE available: $fuse_status"

  # Check if already mounted
  if mountpoint -q "$remote_visible" 2>/dev/null; then
    log i "$system already mounted"
    remote_roms_log_debug "mount_system: Already mounted, returning success"
    remote_roms_log_debug "mount_system: Already mounted, returning success"
    return 0
  fi
  remote_roms_log_debug "mount_system: Not currently mounted, proceeding"
  remote_roms_log_debug "mount_system: Not currently mounted, proceeding"

  mount_config=$(jq --arg s "$system" '.remote_roms.mounts[$s] // empty' "$rd_conf")
  remote_roms_log_debug "mount_system: mount_config from JSON: ${mount_config:-'(empty)'})"

  remote_roms_log_debug "mount_system: mount_config from JSON: ${mount_config:-'(empty)'})"

  if [[ -z "$mount_config" ]]; then
    log e "No mount config for $system"
    remote_roms_log_debug "mount_system: ERROR - No mount config found in rd_conf"
    remote_roms_log_debug "mount_system: ERROR - No mount config found in rd_conf"
    return 1
  fi

  enabled=$(echo "$mount_config" | jq -r '.enabled')
  remote_roms_log_debug "mount_system: enabled=$enabled"
  [[ "$enabled" != "true" ]] && { remote_roms_log_debug "mount_system: Mount not enabled, skipping"; return 0; }
  remote_roms_log_debug "mount_system: enabled=$enabled"
  [[ "$enabled" != "true" ]] && { remote_roms_log_debug "mount_system: Mount not enabled, skipping"; return 0; }

  remote_path=$(echo "$mount_config" | jq -r '.remote_path')
  custom_cache=$(echo "$mount_config" | jq -r '.cache_size // empty')
  remote_roms_log_debug "mount_system: remote_path=$remote_path"
  remote_roms_log_debug "mount_system: custom_cache=$custom_cache"
  remote_roms_log_debug "mount_system: remote_path=$remote_path"
  remote_roms_log_debug "mount_system: custom_cache=$custom_cache"

  remote_roms_log_debug "mount_system: Generating rclone config..."
  remote_roms_log_debug "mount_system: Generating rclone config..."
  remote_roms_generate_rclone_config
  local config_result=$?
  if [[ $config_result -ne 0 ]]; then
    remote_roms_log_debug "mount_system: ERROR - Failed to generate rclone config"
    return 1
  fi
  local config_result=$?
  if [[ $config_result -ne 0 ]]; then
    remote_roms_log_debug "mount_system: ERROR - Failed to generate rclone config"
    return 1
  fi

  # Get VFS settings
  cache_mode=$(remote_roms_get_setting "vfs_cache_mode")
  read_ahead=$(remote_roms_get_setting "vfs_read_ahead")
  cache_size=$(remote_roms_get_setting "vfs_cache_max_size")

  remote_roms_log_debug "mount_system: VFS settings - cache_mode=$cache_mode, read_ahead=$read_ahead, cache_size=$cache_size"

  remote_roms_log_debug "mount_system: VFS settings - cache_mode=$cache_mode, read_ahead=$read_ahead, cache_size=$cache_size"

  # Use custom cache size if set
  [[ -n "$custom_cache" ]] && cache_size="$custom_cache"
  [[ -n "$custom_cache" ]] && remote_roms_log_debug "mount_system: Using custom cache_size=$cache_size"
  [[ -n "$custom_cache" ]] && remote_roms_log_debug "mount_system: Using custom cache_size=$cache_size"

  # Create directories
  mkdir -p "$system_path"
  mkdir -p "$remote_visible"
  remote_roms_log_debug "mount_system: Created directories - system_path exists: $([[ -d "$system_path" ]] && echo 'yes' || echo 'no')"
  remote_roms_log_debug "mount_system: Created directories - remote_visible exists: $([[ -d "$remote_visible" ]] && echo 'yes' || echo 'no')"
  remote_roms_log_debug "mount_system: Created directories - system_path exists: $([[ -d "$system_path" ]] && echo 'yes' || echo 'no')"
  remote_roms_log_debug "mount_system: Created directories - remote_visible exists: $([[ -d "$remote_visible" ]] && echo 'yes' || echo 'no')"

  # Create README to explain the structure
  cat > "$system_path/README.txt" << 'EOF'
Remote ROMs Folder Structure
============================

remote/ - Mounted WebDAV folder (browse all remote ROMs here)
*.gba, *.zip, etc. - Downloaded ROMs appear here after first launch

How it works:
1. Browse the "remote/" folder to see all available ROMs on your WebDAV
2. Click any ROM in "remote/" to play
3. The ROM is downloaded to this folder automatically
4. Next time, the local copy is used (works offline!)

Tip: ROMs you play often will be in this main folder for fast access.
EOF

  # Build and log the rclone mount command
  local rclone_cmd="rclone mount"
  local rclone_remote="retrodeck-webdav:${remote_path}"
  local rclone_mount_point="$remote_visible"

  remote_roms_log_debug "mount_system: ====== EFFECTIVE RCLONE COMMAND ======"
  remote_roms_log_debug "mount_system: Command: $rclone_cmd"
  remote_roms_log_debug "mount_system: Remote: $rclone_remote"
  remote_roms_log_debug "mount_system: Mount Point: $rclone_mount_point"
  remote_roms_log_debug "mount_system: Full command line:"
  remote_roms_log_debug "mount_system:   $rclone_cmd \"$rclone_remote\" \"$rclone_mount_point\" \\"
  remote_roms_log_debug "mount_system:     --vfs-cache-mode=\"$cache_mode\" \\"
  remote_roms_log_debug "mount_system:     --vfs-read-ahead=\"$read_ahead\" \\"
  remote_roms_log_debug "mount_system:     --vfs-cache-max-size=\"$cache_size\" \\"
  remote_roms_log_debug "mount_system:     --cache-dir=\"$system_path/.vfs-cache\" \\"
  remote_roms_log_debug "mount_system:     --allow-other --allow-non-empty --daemon \\"
  remote_roms_log_debug "mount_system:     --log-file=\"$logs_path/rclone-$system.log\""
  remote_roms_log_debug "mount_system: ====== END RCLONE COMMAND ======"

  # Also write to a dedicated file for easy debugging
  echo "$(date +[%Y-%m-%d\ %H:%M:%S]) RCLONE MOUNT COMMAND for $system:" >> "$rd_xdg_config_logs_path/rclone_commands.log"
  echo "  $rclone_cmd \"$rclone_remote\" \"$rclone_mount_point\" \\" >> "$rd_xdg_config_logs_path/rclone_commands.log"
  echo "    --vfs-cache-mode=\"$cache_mode\" \\" >> "$rd_xdg_config_logs_path/rclone_commands.log"
  echo "    --vfs-read-ahead=\"$read_ahead\" \\" >> "$rd_xdg_config_logs_path/rclone_commands.log"
  echo "    --vfs-cache-max-size=\"$cache_size\" \\" >> "$rd_xdg_config_logs_path/rclone_commands.log"
  echo "    --cache-dir=\"$system_path/.vfs-cache\" \\" >> "$rd_xdg_config_logs_path/rclone_commands.log"
  echo "    --allow-other --allow-non-empty --daemon \\" >> "$rd_xdg_config_logs_path/rclone_commands.log"
  echo "    --log-file=\"$logs_path/rclone-$system.log\"" >> "$rd_xdg_config_logs_path/rclone_commands.log"
  echo "" >> "$rd_xdg_config_logs_path/rclone_commands.log"

  # Build and log the rclone mount command
  local rclone_cmd="rclone mount"
  local rclone_remote="retrodeck-webdav:${remote_path}"
  local rclone_mount_point="$remote_visible"

  remote_roms_log_debug "mount_system: ====== EFFECTIVE RCLONE COMMAND ======"
  remote_roms_log_debug "mount_system: Command: $rclone_cmd"
  remote_roms_log_debug "mount_system: Remote: $rclone_remote"
  remote_roms_log_debug "mount_system: Mount Point: $rclone_mount_point"
  remote_roms_log_debug "mount_system: Full command line:"
  remote_roms_log_debug "mount_system:   $rclone_cmd \"$rclone_remote\" \"$rclone_mount_point\" \\"
  remote_roms_log_debug "mount_system:     --vfs-cache-mode=\"$cache_mode\" \\"
  remote_roms_log_debug "mount_system:     --vfs-read-ahead=\"$read_ahead\" \\"
  remote_roms_log_debug "mount_system:     --vfs-cache-max-size=\"$cache_size\" \\"
  remote_roms_log_debug "mount_system:     --cache-dir=\"$system_path/.vfs-cache\" \\"
  remote_roms_log_debug "mount_system:     --allow-other --allow-non-empty --daemon \\"
  remote_roms_log_debug "mount_system:     --log-file=\"$logs_path/rclone-$system.log\""
  remote_roms_log_debug "mount_system: ====== END RCLONE COMMAND ======"

  # Also write to a dedicated file for easy debugging
  echo "$(date +[%Y-%m-%d\ %H:%M:%S]) RCLONE MOUNT COMMAND for $system:" >> "$rd_xdg_config_logs_path/rclone_commands.log"
  echo "  $rclone_cmd \"$rclone_remote\" \"$rclone_mount_point\" \\" >> "$rd_xdg_config_logs_path/rclone_commands.log"
  echo "    --vfs-cache-mode=\"$cache_mode\" \\" >> "$rd_xdg_config_logs_path/rclone_commands.log"
  echo "    --vfs-read-ahead=\"$read_ahead\" \\" >> "$rd_xdg_config_logs_path/rclone_commands.log"
  echo "    --vfs-cache-max-size=\"$cache_size\" \\" >> "$rd_xdg_config_logs_path/rclone_commands.log"
  echo "    --cache-dir=\"$system_path/.vfs-cache\" \\" >> "$rd_xdg_config_logs_path/rclone_commands.log"
  echo "    --allow-other --allow-non-empty --daemon \\" >> "$rd_xdg_config_logs_path/rclone_commands.log"
  echo "    --log-file=\"$logs_path/rclone-$system.log\"" >> "$rd_xdg_config_logs_path/rclone_commands.log"
  echo "" >> "$rd_xdg_config_logs_path/rclone_commands.log"

  # Mount remote to visible remote/ folder
  remote_roms_log_debug "mount_system: Executing rclone mount..."
  if rclone mount "$rclone_remote" "$rclone_mount_point" \
  remote_roms_log_debug "mount_system: Executing rclone mount..."
  if rclone mount "$rclone_remote" "$rclone_mount_point" \
    --vfs-cache-mode="$cache_mode" \
    --vfs-read-ahead="$read_ahead" \
    --vfs-cache-max-size="$cache_size" \
    --cache-dir="$system_path/.vfs-cache" \
    --cache-dir="$system_path/.vfs-cache" \
    --allow-other --allow-non-empty --daemon \
    --log-file="$logs_path/rclone-$system.log"; then
    --log-file="$logs_path/rclone-$system.log"; then

    log i "Mounted $system remote to $remote_visible"
    remote_roms_log_debug "mount_system: Mount successful"
    remote_roms_log_debug "mount_system: Verifying mount with mountpoint command..."
    if mountpoint -q "$remote_visible" 2>/dev/null; then
      remote_roms_log_debug "mount_system: Verified - mountpoint is active"
    else
      remote_roms_log_debug "mount_system: WARNING - mountpoint command reports not mounted (may be timing issue)"
    fi
    remote_roms_log_debug "mount_system: ====== END MOUNT FOR $system (SUCCESS) ======"
    remote_roms_log_debug "mount_system: Mount successful"
    remote_roms_log_debug "mount_system: Verifying mount with mountpoint command..."
    if mountpoint -q "$remote_visible" 2>/dev/null; then
      remote_roms_log_debug "mount_system: Verified - mountpoint is active"
    else
      remote_roms_log_debug "mount_system: WARNING - mountpoint command reports not mounted (may be timing issue)"
    fi
    remote_roms_log_debug "mount_system: ====== END MOUNT FOR $system (SUCCESS) ======"
    return 0
  else
    log e "Failed to mount $system"
    remote_roms_log_debug "mount_system: ERROR - rclone mount command failed with exit code $?"
    remote_roms_log_debug "mount_system: Check rclone log at: $logs_path/rclone-$system.log"
    remote_roms_log_debug "mount_system: ====== END MOUNT FOR $system (FAILED) ======"
    remote_roms_log_debug "mount_system: ERROR - rclone mount command failed with exit code $?"
    remote_roms_log_debug "mount_system: Check rclone log at: $logs_path/rclone-$system.log"
    remote_roms_log_debug "mount_system: ====== END MOUNT FOR $system (FAILED) ======"
    return 1
  fi
}

remote_roms_unmount_system() {
  # Unmount a specific system
  # USAGE: remote_roms_unmount_system "$system"

  local system="$1"
  local mount_point="$roms_path/$system/remote"

  remote_roms_log_debug "unmount_system: ====== UNMOUNT $system ======"
  remote_roms_log_debug "unmount_system: mount_point=$mount_point"

  remote_roms_log_debug "unmount_system: ====== UNMOUNT $system ======"
  remote_roms_log_debug "unmount_system: mount_point=$mount_point"

  if mountpoint -q "$mount_point" 2>/dev/null; then
    remote_roms_log_debug "unmount_system: Mount is active, attempting unmount..."

    # Try fusermount3 first, then fusermount, then umount
    if command -v fusermount3 &> /dev/null && fusermount3 -u "$mount_point" 2>/dev/null; then
      remote_roms_log_debug "unmount_system: fusermount3 -u succeeded"
    elif command -v fusermount &> /dev/null && fusermount -u "$mount_point" 2>/dev/null; then
      remote_roms_log_debug "unmount_system: fusermount -u succeeded"
    elif umount "$mount_point" 2>/dev/null; then
      remote_roms_log_debug "unmount_system: umount succeeded"
    else
      remote_roms_log_debug "unmount_system: WARNING - All unmount methods failed"
    fi
    log i "Unmounted $system"
  else
    remote_roms_log_debug "unmount_system: Mount was not active (nothing to unmount)"
  else
    remote_roms_log_debug "unmount_system: Mount was not active (nothing to unmount)"
  fi
  remote_roms_log_debug "unmount_system: ====== END UNMOUNT ======"
  remote_roms_log_debug "unmount_system: ====== END UNMOUNT ======"
}

remote_roms_mount_all() {
  # Mount all enabled systems
  log i "Mounting all enabled remote ROM systems"
  remote_roms_log_debug "mount_all: ====== START MOUNT ALL ======"
  remote_roms_log_debug "mount_all: ====== START MOUNT ALL ======"

  local mounts=$(remote_roms_get_mounts)
  local count=0

  remote_roms_log_debug "mount_all: Found mounts config: $mounts"

  remote_roms_log_debug "mount_all: Found mounts config: $mounts"

  while IFS= read -r system; do
    if [[ -n "$system" ]]; then
      remote_roms_log_debug "mount_all: Attempting to mount: $system"
      if remote_roms_mount_system "$system"; then
        ((count++))
        remote_roms_log_debug "mount_all: $system mounted successfully"
      else
        remote_roms_log_debug "mount_all: $system mount failed"
      fi
      remote_roms_log_debug "mount_all: Attempting to mount: $system"
      if remote_roms_mount_system "$system"; then
        ((count++))
        remote_roms_log_debug "mount_all: $system mounted successfully"
      else
        remote_roms_log_debug "mount_all: $system mount failed"
      fi
    fi
  done < <(echo "$mounts" | jq -r 'to_entries[] | select(.value.enabled == true) | .key')

  log i "Mounted $count systems"
  remote_roms_log_debug "mount_all: Total systems mounted: $count"
  remote_roms_log_debug "mount_all: ====== END MOUNT ALL ======"
  remote_roms_log_debug "mount_all: Total systems mounted: $count"
  remote_roms_log_debug "mount_all: ====== END MOUNT ALL ======"
}

remote_roms_unmount_all() {
  # Unmount all systems
  log i "Unmounting all remote ROM systems"

  local mounts=$(remote_roms_get_mounts)

  while IFS= read -r system; do
    [[ -n "$system" ]] && remote_roms_unmount_system "$system"
  done < <(echo "$mounts" | jq -r 'keys[]')
}

remote_roms_is_mounted() {
  # Check if system is mounted
  # USAGE: if [[ $(remote_roms_is_mounted "$system") == "true" ]]; then ...

  local system="$1"
  local mount_point="$roms_path/$system/remote"
  if mountpoint -q "$mount_point" 2>/dev/null; then
  local mount_point="$roms_path/$system/remote"
  if mountpoint -q "$mount_point" 2>/dev/null; then
    echo "true"
  else
    echo "false"
  fi
}

# ============================================
# Download Functions
# ============================================

remote_roms_download_rom() {
  # Download a ROM from remote to local if not already present
  # USAGE: local_path=$(remote_roms_download_rom "$system" "$rom_name")
  # Returns: path to local file (either existing or newly downloaded)

  local system="$1"
  local rom_name="$2"
  local local_path="$roms_path/$system/$rom_name"
  local remote_path="$roms_path/$system/remote/$rom_name"

  remote_roms_log_debug "download_rom: ====== START DOWNLOAD ======"
  remote_roms_log_debug "download_rom: system=$system"
  remote_roms_log_debug "download_rom: rom_name=$rom_name"
  remote_roms_log_debug "download_rom: local_path=$local_path"
  remote_roms_log_debug "download_rom: remote_path=$remote_path"
  remote_roms_log_debug "download_rom: roms_path=$roms_path"

  remote_roms_log_debug "download_rom: ====== START DOWNLOAD ======"
  remote_roms_log_debug "download_rom: system=$system"
  remote_roms_log_debug "download_rom: rom_name=$rom_name"
  remote_roms_log_debug "download_rom: local_path=$local_path"
  remote_roms_log_debug "download_rom: remote_path=$remote_path"
  remote_roms_log_debug "download_rom: roms_path=$roms_path"

  # If already local, return immediately
  if [[ -f "$local_path" ]]; then
    remote_roms_log_debug "download_rom: File already exists locally, returning immediately"
    remote_roms_log_debug "download_rom: Local file size: $(stat -c%s "$local_path" 2>/dev/null || echo 'unknown') bytes"
    remote_roms_log_debug "download_rom: File already exists locally, returning immediately"
    remote_roms_log_debug "download_rom: Local file size: $(stat -c%s "$local_path" 2>/dev/null || echo 'unknown') bytes"
    echo "$local_path"
    return 0
  fi
  remote_roms_log_debug "download_rom: File not found locally, checking remote..."

  # Check if remote mount exists
  if [[ ! -d "$roms_path/$system/remote" ]]; then
    remote_roms_log_debug "download_rom: ERROR - Remote mount directory does not exist: $roms_path/$system/remote"
    remote_roms_log_debug "download_rom: The mount may not be active for system: $system"
    return 1
  fi

  # Check if mount is active
  if ! mountpoint -q "$roms_path/$system/remote" 2>/dev/null; then
    remote_roms_log_debug "download_rom: WARNING - Mountpoint check failed for: $roms_path/$system/remote"
    remote_roms_log_debug "download_rom: The mount may not be active"
  else
    remote_roms_log_debug "download_rom: Mountpoint is active"
  fi
  remote_roms_log_debug "download_rom: File not found locally, checking remote..."

  # Check if remote mount exists
  if [[ ! -d "$roms_path/$system/remote" ]]; then
    remote_roms_log_debug "download_rom: ERROR - Remote mount directory does not exist: $roms_path/$system/remote"
    remote_roms_log_debug "download_rom: The mount may not be active for system: $system"
    return 1
  fi

  # Check if mount is active
  if ! mountpoint -q "$roms_path/$system/remote" 2>/dev/null; then
    remote_roms_log_debug "download_rom: WARNING - Mountpoint check failed for: $roms_path/$system/remote"
    remote_roms_log_debug "download_rom: The mount may not be active"
  else
    remote_roms_log_debug "download_rom: Mountpoint is active"
  fi

  # If remote mount exists and has the file, copy it
  if [[ -f "$remote_path" ]]; then
    log i "Downloading $rom_name from remote..."
    remote_roms_log_debug "download_rom: Remote file found, starting copy..."
    remote_roms_log_debug "download_rom: Remote file size (if stat works): $(stat -c%s "$remote_path" 2>/dev/null || echo 'stat failed - mount may not be fully ready')"
    remote_roms_log_debug "download_rom: Remote file found, starting copy..."
    remote_roms_log_debug "download_rom: Remote file size (if stat works): $(stat -c%s "$remote_path" 2>/dev/null || echo 'stat failed - mount may not be fully ready')"

    # Copy entire file (cp from rclone mount downloads full file)
    remote_roms_log_debug "download_rom: Executing: cp \"$remote_path\" \"$local_path\""
    remote_roms_log_debug "download_rom: Executing: cp \"$remote_path\" \"$local_path\""
    if cp "$remote_path" "$local_path"; then
      remote_roms_log_debug "download_rom: Copy completed successfully"
      if [[ -f "$local_path" ]]; then
        remote_roms_log_debug "download_rom: Local file size after copy: $(stat -c%s "$local_path" 2>/dev/null || echo 'unknown') bytes"
      else
        remote_roms_log_debug "download_rom: ERROR - Local file not found after successful cp"
      fi
      remote_roms_log_debug "download_rom: Copy completed successfully"
      if [[ -f "$local_path" ]]; then
        remote_roms_log_debug "download_rom: Local file size after copy: $(stat -c%s "$local_path" 2>/dev/null || echo 'unknown') bytes"
      else
        remote_roms_log_debug "download_rom: ERROR - Local file not found after successful cp"
      fi
      log i "Downloaded $rom_name successfully"
      echo "$local_path"
      remote_roms_log_debug "download_rom: ====== END DOWNLOAD (SUCCESS) ======"
      remote_roms_log_debug "download_rom: ====== END DOWNLOAD (SUCCESS) ======"
      return 0
    else
      log e "Failed to download $rom_name"
      remote_roms_log_debug "download_rom: ERROR - cp command failed with exit code $?"
      remote_roms_log_debug "download_rom: ====== END DOWNLOAD (FAILED) ======"
      remote_roms_log_debug "download_rom: ERROR - cp command failed with exit code $?"
      remote_roms_log_debug "download_rom: ====== END DOWNLOAD (FAILED) ======"
      return 1
    fi
  fi

  # File not found in either location
  remote_roms_log_debug "download_rom: ERROR - File not found at remote path: $remote_path"
  remote_roms_log_debug "download_rom: Listing remote directory contents:"
  ls -la "$roms_path/$system/remote/" 2>/dev/null | head -20 | while read line; do
    remote_roms_log_debug "download_rom:   $line"
  done || remote_roms_log_debug "download_rom:   (directory listing failed)"
  remote_roms_log_debug "download_rom: ====== END DOWNLOAD (NOT FOUND) ======"
  remote_roms_log_debug "download_rom: ERROR - File not found at remote path: $remote_path"
  remote_roms_log_debug "download_rom: Listing remote directory contents:"
  ls -la "$roms_path/$system/remote/" 2>/dev/null | head -20 | while read line; do
    remote_roms_log_debug "download_rom:   $line"
  done || remote_roms_log_debug "download_rom:   (directory listing failed)"
  remote_roms_log_debug "download_rom: ====== END DOWNLOAD (NOT FOUND) ======"
  return 1
}

# ============================================
# Utility Functions
# ============================================

remote_roms_check_rclone() {
  # Check if rclone is available
  remote_roms_log_debug "check_rclone: Checking if rclone is available..."

  local rclone_path
  rclone_path=$(command -v rclone 2>/dev/null)

  if [[ -n "$rclone_path" ]]; then
    remote_roms_log_debug "check_rclone: rclone found at: $rclone_path"
    local version
    version=$(rclone version 2>/dev/null | head -1 || echo 'unknown')
    remote_roms_log_debug "check_rclone: rclone version: $version"
  remote_roms_log_debug "check_rclone: Checking if rclone is available..."

  local rclone_path
  rclone_path=$(command -v rclone 2>/dev/null)

  if [[ -n "$rclone_path" ]]; then
    remote_roms_log_debug "check_rclone: rclone found at: $rclone_path"
    local version
    version=$(rclone version 2>/dev/null | head -1 || echo 'unknown')
    remote_roms_log_debug "check_rclone: rclone version: $version"
    echo "true"
  else
    remote_roms_log_debug "check_rclone: rclone NOT found in PATH"
    remote_roms_log_debug "check_rclone: PATH=$PATH"
    remote_roms_log_debug "check_rclone: rclone NOT found in PATH"
    remote_roms_log_debug "check_rclone: PATH=$PATH"
    echo "false"
  fi
}

remote_roms_check_fuse() {
  # Check if FUSE is available (fusermount3 or fusermount)
  # USAGE: remote_roms_check_fuse
  # Returns: "fuse3", "fuse2", or "none"

  remote_roms_log_debug "check_fuse: Checking for FUSE support"

  if command -v fusermount3 &> /dev/null; then
    remote_roms_log_debug "check_fuse: Found fusermount3 at: $(command -v fusermount3)"
    echo "fuse3"
    return 0
  elif command -v fusermount &> /dev/null; then
    remote_roms_log_debug "check_fuse: Found fusermount (fuse2) at: $(command -v fusermount)"
    echo "fuse2"
    return 0
  else
    remote_roms_log_debug "check_fuse: No fusermount found in PATH"
    remote_roms_log_debug "check_fuse: PATH=$PATH"
    echo "none"
    return 1
  fi
}

remote_roms_diagnose_fuse() {
  # Diagnose FUSE issues
  # USAGE: remote_roms_diagnose_fuse

  local diag_log="$rd_xdg_config_logs_path/remote_roms_fuse_diagnosis.log"

  echo "=== FUSE Diagnosis ===" > "$diag_log"
  echo "Date: $(date)" >> "$diag_log"
  echo "" >> "$diag_log"

  echo "--- FUSE Binaries ---" >> "$diag_log"
  echo "fusermount3: $(command -v fusermount3 2>/dev/null || echo 'NOT FOUND')" >> "$diag_log"
  echo "fusermount: $(command -v fusermount 2>/dev/null || echo 'NOT FOUND')" >> "$diag_log"
  echo "" >> "$diag_log"

  echo "--- PATH ---" >> "$diag_log"
  echo "$PATH" >> "$diag_log"
  echo "" >> "$diag_log"

  echo "--- /usr/bin ---" >> "$diag_log"
  ls -la /usr/bin/fuse* 2>/dev/null >> "$diag_log" || echo "No fuse binaries in /usr/bin" >> "$diag_log"
  echo "" >> "$diag_log"

  echo "--- /app/bin ---" >> "$diag_log"
  ls -la /app/bin/fuse* 2>/dev/null >> "$diag_log" || echo "No fuse binaries in /app/bin" >> "$diag_log"
  echo "" >> "$diag_log"

  echo "--- Kernel FUSE Support ---" >> "$diag_log"
  ls -la /dev/fuse 2>/dev/null >> "$diag_log" || echo "/dev/fuse not found" >> "$diag_log"
  echo "" >> "$diag_log"

  echo "--- User Groups ---" >> "$diag_log"
  groups >> "$diag_log"
  echo "" >> "$diag_log"

  echo "Diagnosis complete. See: $diag_log"
  echo "$diag_log"
}
