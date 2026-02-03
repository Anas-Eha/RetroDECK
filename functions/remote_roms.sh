#!/bin/bash

# Remote ROMs Folder Management Functions
# This file handles mounting remote WebDAV folders using rclone with VFS caching

# Default rclone VFS settings
readonly REMOTE_ROMS_DEFAULT_VFS_CACHE_MODE="full"
readonly REMOTE_ROMS_DEFAULT_VFS_READ_AHEAD="8G"
readonly REMOTE_ROMS_DEFAULT_VFS_CACHE_MAX_SIZE="20G"

# ============================================
# Configuration Functions
# ============================================

remote_roms_init_config() {
  # Initialize remote ROMs configuration if not present
  # USAGE: remote_roms_init_config

  if ! jq -e '.remote_roms' "$rd_conf" > /dev/null 2>&1; then
    log i "Creating remote_roms configuration"
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

  local url=$(remote_roms_get_setting "webdav_url")
  local user=$(remote_roms_get_setting "webdav_user")
  local pass=$(remote_roms_get_setting "webdav_pass")

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
  rclone_config=$(mktemp)
  local obscured_pass
  obscured_pass=$(rclone obscure "$pass" 2>/dev/null || echo "$pass")

  cat > "$rclone_config" << EOF
[webdav-test]
type = webdav
url = $url
vendor = other
user = $user
pass = $obscured_pass
EOF

  # Test connection with timeout
  local test_result
  if RCLONE_CONFIG="$rclone_config" rclone ls "webdav-test:/" --max-depth 1 --contimeout 10s --timeout 10s > /dev/null 2>&1; then
    test_result="connected"
  else
    test_result="connection_failed"
  fi

  # Cleanup
  rm -f "$rclone_config"

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

  local mount_obj=$(jq -n \
    --arg system "$system" \
    --arg remote_path "$remote_path" \
    --arg cache_size "$cache_size" \
    '{
      "system": $system,
      "remote_path": $remote_path,
      "enabled": true,
      "cache_size": (if $cache_size == "" then null else $cache_size end)
    }')

  jq --arg system "$system" --argjson obj "$mount_obj" '.remote_roms.mounts[$system] = $obj' "$rd_conf" > "$rd_conf.tmp" && mv "$rd_conf.tmp" "$rd_conf"
  log i "Added mount for $system"
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

  url=$(remote_roms_get_setting "webdav_url")
  user=$(remote_roms_get_setting "webdav_user")
  pass=$(remote_roms_get_setting "webdav_pass")

  rclone_dir="$XDG_CONFIG_HOME/rclone"
  mkdir -p "$rclone_dir"

  obscured_pass=$(rclone obscure "$pass" 2>/dev/null || echo "$pass")

  cat > "$rclone_dir/rclone.conf" << EOF
[retrodeck-webdav]
type = webdav
url = $url
vendor = other
user =$user
pass = $obscured_pass
EOF

  # Secure the config file (contains credentials)
  chmod 600 "$rclone_dir/rclone.conf"
}

remote_roms_mount_system() {
  # Mount a specific system
  # Remote is mounted to roms/<system>/remote/ (visible)
  # Downloaded files go to roms/<system>/ (local cache)
  # USAGE: remote_roms_mount_system "$system"

  local system system_path remote_visible mount_config enabled remote_path
  local custom_cache cache_mode read_ahead cache_size

  system="$1"
  system_path="$roms_path/$system"
  remote_visible="$roms_path/$system/remote"

  # Check if already mounted
  if mountpoint -q "$remote_visible" 2>/dev/null; then
    log i "$system already mounted"
    return 0
  fi

  mount_config=$(jq --arg s "$system" '.remote_roms.mounts[$s] // empty' "$rd_conf")
  if [[ -z "$mount_config" ]]; then
    log e "No mount config for $system"
    return 1
  fi

  enabled=$(echo "$mount_config" | jq -r '.enabled')
  [[ "$enabled" != "true" ]] && return 0

  remote_path=$(echo "$mount_config" | jq -r '.remote_path')
  custom_cache=$(echo "$mount_config" | jq -r '.cache_size // empty')

  remote_roms_generate_rclone_config

  # Get VFS settings
  cache_mode=$(remote_roms_get_setting "vfs_cache_mode")
  read_ahead=$(remote_roms_get_setting "vfs_read_ahead")
  cache_size=$(remote_roms_get_setting "vfs_cache_max_size")

  # Use custom cache size if set
  [[ -n "$custom_cache" ]] && cache_size="$custom_cache"

  # Create directories
  mkdir -p "$system_path"
  mkdir -p "$remote_visible"

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

  # Mount remote to visible remote/ folder
  if rclone mount "retrodeck-webdav:$remote_path" "$remote_visible" \
    --vfs-cache-mode="$cache_mode" \
    --vfs-read-ahead="$read_ahead" \
    --vfs-cache-max-size="$cache_size" \
    --cache-dir="$system_path/.vfs-cache" \
    --allow-other --allow-non-empty --daemon \
    --log-file="$logs_path/rclone-$system.log"; then

    log i "Mounted $system remote to $remote_visible"
    return 0
  else
    log e "Failed to mount $system"
    return 1
  fi
}

remote_roms_unmount_system() {
  # Unmount a specific system
  # USAGE: remote_roms_unmount_system "$system"

  local system="$1"
  local mount_point="$roms_path/$system/remote"

  if mountpoint -q "$mount_point" 2>/dev/null; then
    fusermount -u "$mount_point" 2>/dev/null || umount "$mount_point" 2>/dev/null
    log i "Unmounted $system"
  fi
}

remote_roms_mount_all() {
  # Mount all enabled systems
  log i "Mounting all enabled remote ROM systems"

  local mounts=$(remote_roms_get_mounts)
  local count=0

  while IFS= read -r system; do
    if [[ -n "$system" ]]; then
      remote_roms_mount_system "$system" && ((count++))
    fi
  done < <(echo "$mounts" | jq -r 'to_entries[] | select(.value.enabled == true) | .key')

  log i "Mounted $count systems"
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

  # If already local, return immediately
  if [[ -f "$local_path" ]]; then
    echo "$local_path"
    return 0
  fi

  # If remote mount exists and has the file, copy it
  if [[ -f "$remote_path" ]]; then
    log i "Downloading $rom_name from remote..."

    # Copy entire file (cp from rclone mount downloads full file)
    if cp "$remote_path" "$local_path"; then
      log i "Downloaded $rom_name successfully"
      echo "$local_path"
      return 0
    else
      log e "Failed to download $rom_name"
      return 1
    fi
  fi

  # File not found in either location
  return 1
}

# ============================================
# Utility Functions
# ============================================

remote_roms_check_rclone() {
  # Check if rclone is available
  if command -v rclone &> /dev/null; then
    echo "true"
  else
    echo "false"
  fi
}

remote_roms_set_global_enabled() {
  # Enable/disable remote ROMs globally
  jq --argjson e "$1" '.remote_roms.global_enabled = $e' "$rd_conf" > "$rd_conf.tmp" && mv "$rd_conf.tmp" "$rd_conf"
}

remote_roms_is_global_enabled() {
  # Check if remote ROMs is enabled
  jq -r '.remote_roms.global_enabled // false' "$rd_conf"
}

remote_roms_get_available_systems() {
  # Get list of available ROM systems
  if [[ -d "$roms_path" ]]; then
    find "$roms_path" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
  fi
}
