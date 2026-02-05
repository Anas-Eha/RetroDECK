#!/bin/bash

# Remote ROMs Folder Management Functions
# This file handles mounting remote WebDAV folders using rclone with VFS caching

# Default rclone VFS settings
readonly REMOTE_ROMS_DEFAULT_VFS_CACHE_MODE="writes"
readonly REMOTE_ROMS_DEFAULT_VFS_READ_AHEAD="0"
readonly REMOTE_ROMS_DEFAULT_VFS_CACHE_MAX_SIZE="50M"

# Internal helper: Debug logging function
remote_roms_log_debug() {
  # Only log if remote ROMs debug logging is enabled
  if [[ "${REMOTE_ROMS_DEBUG:-0}" == "1" ]]; then
    log d "$1"
  fi
}

# Internal helper: Write rclone config file
_remote_roms_write_rclone_config() {
  local config_file="$1"
  local section="$2"
  local url="$3"
  local user="$4"
  local pass="$5"

  local obscured_pass=$(rclone obscure "$pass" 2>/dev/null || echo "$pass")

  echo "[$section]" > "$config_file"
  echo "type = webdav" >> "$config_file"
  echo "url = $url" >> "$config_file"
  echo "vendor = other" >> "$config_file"
  echo "user = $user" >> "$config_file"
  echo "pass = $obscured_pass" >> "$config_file"
}

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

  # Create temporary rclone config using shared helper
  local rclone_config=$(mktemp)
  _remote_roms_write_rclone_config "$rclone_config" "webdav-test" "$url" "$user" "$pass"

  # Test connection with timeout
  local rclone_output
  rclone_output=$(RCLONE_CONFIG="$rclone_config" rclone ls "webdav-test:/" --max-depth 1 --contimeout 10s --timeout 10s 2>&1)
  local rclone_exit_code=$?

  rm -f "$rclone_config"

  if [[ $rclone_exit_code -eq 0 ]]; then
    echo "connected"
    return 0
  else
    echo "connection_failed"
    return 1
  fi
}

# ============================================
# Mount Management
# ============================================

remote_roms_add_mount() {
  # Add a system mount configuration
  # USAGE: remote_roms_add_mount "$system" "$remote_path"

  local system="$1"
  local remote_path="$2"

  local mount_obj=$(jq -n \
    --arg system "$system" \
    --arg remote_path "$remote_path" \
    '{
      "system": $system,
      "remote_path": $remote_path,
      "enabled": true,
      "automount": false
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

remote_roms_set_mount_automount() {
  # Enable/disable auto-mount for a system
  # USAGE: remote_roms_set_mount_automount "$system" "true|false"

  local system="$1"
  local automount="$2"

  jq --arg s "$system" --argjson a "$automount" '.remote_roms.mounts[$s].automount = $a' "$rd_conf" > "$rd_conf.tmp" && mv "$rd_conf.tmp" "$rd_conf"

  log i "Auto-mount for $system set to $automount"
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

  local url=$(remote_roms_get_setting "webdav_url")
  local user=$(remote_roms_get_setting "webdav_user")
  local pass=$(remote_roms_get_setting "webdav_pass")

  if [[ -z "$url" || -z "$user" ]]; then
    log e "Cannot generate rclone config: missing URL or username"
    return 1
  fi

  if ! command -v rclone &> /dev/null; then
    log e "rclone not found in PATH"
    return 1
  fi

  local rclone_dir="$XDG_CONFIG_HOME/rclone"
  mkdir -p "$rclone_dir"

  _remote_roms_write_rclone_config "$rclone_dir/rclone.conf" "retrodeck-webdav" "$url" "$user" "$pass"
  chmod 600 "$rclone_dir/rclone.conf"
}

remote_roms_mount_system() {
  # Mount a specific system
  # Remote is mounted to roms/<system>/remote/ (visible)
  # Downloaded files go to roms/<system>/ (local cache)
  # USAGE: remote_roms_mount_system "$system"

  local system system_path remote_visible mount_config enabled remote_path
  local cache_mode read_ahead cache_size

  system="$1"
  system_path="$roms_path/$system"
  remote_visible="$roms_path/$system/remote"

  remote_roms_log_debug "mount_system: mounting $system (path: $system_path, remote: $remote_visible)"

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

  remote_roms_generate_rclone_config || return 1

  # Use VFS defaults directly (simpler, no config needed)
  # VFS cache helps with directory listing but files are copied locally anyway
  local cache_mode="$REMOTE_ROMS_DEFAULT_VFS_CACHE_MODE"
  local read_ahead="$REMOTE_ROMS_DEFAULT_VFS_READ_AHEAD"
  local cache_size="$REMOTE_ROMS_DEFAULT_VFS_CACHE_MAX_SIZE"




  # Create directories
  mkdir -p "$system_path" "$remote_visible"

  # Build and log the rclone mount command
  local rclone_cmd="rclone mount"
  local rclone_remote="retrodeck-webdav:${remote_path}"
  local rclone_mount_point="$remote_visible"

  # Build rclone command arguments array
  local rclone_args=(
    --vfs-cache-mode="$cache_mode"
    --vfs-read-ahead="$read_ahead"
    --vfs-cache-max-size="$cache_size"
    --cache-dir="$system_path/.vfs-cache"
    --allow-other
    --allow-non-empty
    --daemon
    --log-file="$logs_path/rclone-$system.log"
  )

  # Log command
  remote_roms_log_debug "mount_system: rclone mount $rclone_remote -> $rclone_mount_point (cache: $cache_mode, read_ahead: $read_ahead, max_size: $cache_size)"

  # Write to dedicated debug file
  {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] RCLONE MOUNT COMMAND for $system:"
    printf '  rclone mount %q %q \\n' "$rclone_remote" "$rclone_mount_point"
    printf '    %s \\n' "${rclone_args[@]}"
    echo ""
  } >> "$rd_xdg_config_logs_path/rclone_commands.log"

  # Mount remote to visible remote/ folder
  if rclone mount "$rclone_remote" "$rclone_mount_point" "${rclone_args[@]}"; then

    log i "Mounted $system remote to $remote_visible"

    # Create QuickResume ROM if setting enabled
    if [[ $(get_setting_value "$rd_conf" "remote_roms_quickresume" "retrodeck" "options") == "true" ]]; then
      remote_roms_create_quickresume "$system"
    fi

    remote_roms_log_debug "mount_system: $system mounted successfully"
    return 0
  else
    log e "Failed to mount $system (check $logs_path/rclone-$system.log)"
    remote_roms_log_debug "mount_system: $system mount failed"
    return 1
  fi
}

remote_roms_unmount_system() {
  # Unmount a specific system
  # USAGE: remote_roms_unmount_system "$system"

  local system="$1"
  local mount_point="$roms_path/$system/remote"

  if mountpoint -q "$mount_point" 2>/dev/null; then
    # Try fusermount3 first, then fusermount, then umount
    if command -v fusermount3 &> /dev/null && fusermount3 -u "$mount_point" 2>/dev/null; then
      : # success
    elif command -v fusermount &> /dev/null && fusermount -u "$mount_point" 2>/dev/null; then
      : # success
    elif umount "$mount_point" 2>/dev/null; then
      : # success
    else
      log w "Failed to unmount $system - all methods failed"
    fi
    log i "Unmounted $system"
  fi
}

remote_roms_mount_all() {
  # Mount all enabled systems
  log i "Mounting all enabled remote ROM systems"

  local mounts=$(remote_roms_get_mounts)
  local count=0

  while IFS= read -r system; do
    if [[ -n "$system" ]] && remote_roms_mount_system "$system"; then
      ((count++))
    fi
  done < <(echo "$mounts" | jq -r 'to_entries[] | select(.value.enabled == true) | .key')

  log i "Mounted $count systems"
}

remote_roms_mount_automount_enabled() {
  # Mount only systems with automount=true (called at startup)
  # Non-blocking - failures are logged but don't stop RetroDECK startup
  # USAGE: remote_roms_mount_automount_enabled

  log i "Checking for auto-mount enabled remote ROM systems"

  # Initialize config if needed
  remote_roms_init_config

  # Check global automount setting
  if [[ $(get_setting_value "$rd_conf" "remote_roms_automount" "retrodeck" "options") == "false" ]]; then
    return 0
  fi

  local mounts=$(remote_roms_get_mounts)
  local count=0

  # Mount only automount-enabled systems
  while IFS= read -r system; do
    if [[ -n "$system" ]] && remote_roms_mount_system "$system"; then
      ((count++))
    fi
  done < <(echo "$mounts" | jq -r 'to_entries[] | select(.value.automount == true) | .key')

  log i "Auto-mounted $count systems"
}

remote_roms_unmount_all() {
  # Unmount all systems
  log i "Unmounting all remote ROM systems"

  local mounts=$(remote_roms_get_mounts)

  while IFS= read -r system; do
    [[ -n "$system" ]] && remote_roms_unmount_system "$system"
  done < <(echo "$mounts" | jq -r 'keys[]')
}

remote_roms_create_quickresume() {
  # Create 999RepairRemote.zip file for mount repair after Quick Resume
  # Creates the file in the LOCAL folder ($roms_path/$system/), NOT in the remote mount ($roms_path/$system/remote/)
  # USAGE: remote_roms_create_quickresume "$system"
  
  local system="$1"
  local system_path="$roms_path/$system"
  
  # Create in LOCAL folder (NOT in the remote/ mount subdirectory)
  local qr_file="$system_path/999RepairRemote.zip"
  
  # Create small dummy file (ES-DE needs a real file to show)
  if [[ ! -f "$qr_file" ]]; then
    echo "QUICKRESUME" > "$qr_file"
    log i "Created repair file for $system: 999RepairRemote.zip"
    remote_roms_log_debug "create_quickresume: Created $qr_file"
  fi
}

remote_roms_check_mount_health() {
  # Check if a mount is healthy (responding to I/O)
  # Returns: "healthy", "stale", or "not_mounted"
  # USAGE: health=$(remote_roms_check_mount_health "$system")
  
  local system="$1"
  local mount_point="$roms_path/$system/remote"
  
  # Check if mountpoint exists
  if ! mountpoint -q "$mount_point" 2>/dev/null; then
    echo "not_mounted"
    return 0
  fi
  
  # Try actual I/O operation with timeout
  if timeout 2 ls "$mount_point" >/dev/null 2>&1; then
    echo "healthy"
  else
    echo "stale"
  fi
}

remote_roms_check_and_repair_mount() {
  # Check mount health and repair if stale (one attempt)
  # Returns: 0 if healthy or repaired, 1 if failed
  # USAGE: if remote_roms_check_and_repair_mount "$system"; then ...

  local system="$1"
  local health=$(remote_roms_check_mount_health "$system")

  if [[ "$health" == "healthy" ]]; then
    return 0
  fi

  if [[ "$health" == "not_mounted" ]]; then
    remote_roms_mount_system "$system"
    return $?
  fi

  # Stale mount - repair it
  log i "Repairing stale mount for $system"
  remote_roms_unmount_system "$system"
  sleep 1

  if remote_roms_mount_system "$system"; then
    log i "Successfully repaired mount for $system"
    return 0
  else
    log e "Failed to repair mount for $system"
    return 1
  fi
}

remote_roms_repair_all_mounts() {
  # Repair all configured mounts (for manual repair menu)
  # Returns: count of repaired mounts
  # USAGE: repaired=$(remote_roms_repair_all_mounts)

  log i "Repairing all remote ROM mounts"

  local mounts=$(remote_roms_get_mounts)
  local repaired=0

  while IFS= read -r system; do
    if [[ -n "$system" ]] && remote_roms_check_and_repair_mount "$system"; then
      ((repaired++))
    fi
  done < <(echo "$mounts" | jq -r 'keys[]')

  log i "Repaired $repaired systems"
  echo "$repaired"
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

remote_roms_get_available_systems() {
  # Get list of available RetroDECK systems for remote ROMs
  # Returns: Space-separated list of system folder names (gba snes ps2 etc.)
  # This is used by the discovery dialog to match remote folders
  # Sources systems from bios.json reference file for consistency

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
  # This ensures consistency with RetroDECK's supported systems
  if [[ -f "$bios_checklist" ]]; then
    jq -r '.bios[].system' "$bios_checklist" 2>/dev/null | sort -u | tr '\n' ' '
    return 0
  fi

  # Final fallback: return empty (caller should handle gracefully)
  echo ""
  return 1
}

# ============================================
# Download Functions
# ============================================

remote_roms_download_rom() {
  # Download a ROM from remote to local if not already present
  # Uses atomic download (temp file + move) to prevent corruption
  # Handles QuickResume specially for Quick Resume repair
  # USAGE: local_path=$(remote_roms_download_rom "$system" "$rom_name")
  # Returns: path to local file (either existing or newly downloaded)

  local system="$1"
  local rom_name="$2"
  local local_path="$roms_path/$system/$rom_name"
  local remote_path="$roms_path/$system/remote/$rom_name"

  # Handle 999RepairRemote.zip specially - repair ALL mounts instead of downloading
  if [[ "$rom_name" == "999RepairRemote.zip" ]]; then
    log i "Repair triggered for $system - repairing ALL remote mounts"
    local repaired_count=$(remote_roms_repair_all_mounts)
    echo "$local_path"
    return 0
  fi

  # If already local, return immediately
  if [[ -f "$local_path" ]]; then
    echo "$local_path"
    return 0
  fi

  # Check if remote mount exists and is active
  if [[ ! -d "$roms_path/$system/remote" ]] || ! mountpoint -q "$roms_path/$system/remote" 2>/dev/null; then
    return 1
  fi

  # If remote mount has the file, copy it
  if [[ -f "$remote_path" ]]; then
    log i "Downloading $rom_name from remote..."

    # Copy using atomic download (temp file + move)
    local temp_file="$local_path.tmp.$$"
    if cp "$remote_path" "$temp_file" && mv "$temp_file" "$local_path"; then
      log i "Downloaded $rom_name successfully"
      echo "$local_path"
      return 0
    else
      rm -f "$temp_file" 2>/dev/null
      log e "Failed to download $rom_name"
      return 1
    fi
  fi

  return 1
}

# ============================================
# Utility Functions
# ============================================

remote_roms_check_rclone() {
  # Check if rclone is available
  # Returns: "true" or "false"
  if command -v rclone &> /dev/null; then
    echo "true"
  else
    echo "false"
  fi
}

remote_roms_check_fuse() {
  # Check if FUSE is available (fusermount3 or fusermount)
  # USAGE: remote_roms_check_fuse
  # Returns: "fuse3", "fuse2", or "none"

  if command -v fusermount3 &> /dev/null; then
    echo "fuse3"
    return 0
  elif command -v fusermount &> /dev/null; then
    echo "fuse2"
    return 0
  else
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
