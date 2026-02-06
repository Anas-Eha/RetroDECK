#!/bin/bash

# Remote ROMs Functions
# Provides WebDAV-based remote ROM browsing and downloading
# Uses rclone for all remote operations - no FUSE mounts required

# ============================================
# Configuration & Constants
# ============================================

readonly REMOTE_ROMS_CACHE_DIR="${rd_cache}/remote_roms"
readonly REMOTE_ROMS_LISTING_FILE="listing.json"
readonly REMOTE_ROMS_GAMELIST_FILE="gamelist.xml"

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
  # Write rclone config file
  # USAGE: _remote_roms_write_rclone_config "$config_file" "$section" "$url" "$user" "$pass"

  local config_file="$1"
  local section="$2"
  local url="$3"
  local user="$4"
  local pass="$5"

  local obscured_pass=$(rclone obscure "$pass" 2>/dev/null ; echo "$pass")

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
      "systems": {},
      "global_enabled": false
    }'
    jq --argjson config "$default_config" '.remote_roms = $config' "$rd_conf" > "$rd_conf.tmp" ; mv "$rd_conf.tmp" "$rd_conf"
  fi
}

remote_roms_get_setting() {
  # Get a remote ROMs setting value (global or system-specific)
  # USAGE: value=$(remote_roms_get_setting "setting_name")
  # USAGE: value=$(remote_roms_get_setting "$system" "property")

  if [[ $# -eq 1 ]]; then
    # Global setting
    jq -r ".remote_roms.$1 // empty" "$rd_conf"
  else
    # System-specific setting
    local system="$1"
    local property="$2"
    jq -r ".remote_roms.systems[\"$system\"].$property // empty" "$rd_conf"
  fi
}

remote_roms_set_setting() {
  # Set a remote ROMs setting value (global or system-specific)
  # USAGE: remote_roms_set_setting "setting_name" "value"
  # USAGE: remote_roms_set_setting "$system" "property" "value"
  if [[ $# -eq 2 ]]; then
    # Global setting
    jq --arg val "$2" ".remote_roms.$1 = \$val" "$rd_conf" > "$rd_conf.tmp" ; mv "$rd_conf.tmp" "$rd_conf"
  else
    # System-specific setting
    local system="$1"
    local property="$2"
    local value="$3"
    jq --arg s "$system" --arg p "$property" --arg v "$value" \
      '.remote_roms.systems[$s][$p] = $v' "$rd_conf" > "$rd_conf.tmp" ; mv "$rd_conf.tmp" "$rd_conf"
  fi
}

remote_roms_get_webdav_creds() {
  # Get WebDAV credentials
  # USAGE: eval $(remote_roms_get_webdav_creds)  # sets $url, $user, $pass
  # OR: local url=$(remote_roms_get_webdav_creds url)

  local field="${1:-all}"
  local url=$(remote_roms_get_setting "webdav_url")
  local user=$(remote_roms_get_setting "webdav_user")
  local pass=$(remote_roms_get_setting "webdav_pass")

  case "$field" in
    url)  echo "$url" ;;
    user) echo "$user" ;;
    pass) echo "$pass" ;;
    *)    echo "url='$url'; user='$user'; pass='$pass'" ;;
  esac
}

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

  eval $(remote_roms_get_webdav_creds)

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
# System Management Functions
# ============================================

remote_roms_add_system() {
  # Add a system to remote ROMs configuration
  # USAGE: remote_roms_add_system "$system" "$remote_path"

  local system="$1"
  local remote_path="$2"

  local system_obj=$(jq -n \
    --arg system "$system" \
    --arg remote_path "$remote_path" \
    '{
      "system": $system,
      "remote_path": $remote_path,
      "enabled": true
    }')

  jq --arg system "$system" --argjson obj "$system_obj" '.remote_roms.systems[$system] = $obj' "$rd_conf" > "$rd_conf.tmp" ; mv "$rd_conf.tmp" "$rd_conf"
  log i "Added remote ROM system: $system"
}

remote_roms_remove_system() {
  # Remove a system from remote ROMs configuration
  # USAGE: remote_roms_remove_system "$system"

  local system="$1"

  # Clear cache
  rm -rf "${REMOTE_ROMS_CACHE_DIR}/${system}"

  jq --arg s "$system" 'del(.remote_roms.systems[$s])' "$rd_conf" > "$rd_conf.tmp" ; mv "$rd_conf.tmp" "$rd_conf"
  log i "Removed remote ROM system: $system"
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
  # Returns: JSON object with discovered systems and their paths

  eval $(remote_roms_get_webdav_creds)

  if [[ -z "$url" || -z "$user" ]]; then
    echo "{}"
    return 1
  fi

  # Create temporary rclone config
  local rclone_config=$(mktemp)
  _remote_roms_write_rclone_config "$rclone_config" "webdav-discover" "$url" "$user" "$pass"

  local available_systems=$(remote_roms_get_available_systems)
  local discovered="{}"

  # Scan root and common subfolders for system folders
  for scan_path in "/" "/roms" "/games" "/library"; do
    local folders=$(RCLONE_CONFIG="$rclone_config" rclone lsf "webdav-discover:$scan_path" --max-depth 1 --dirs-only 2>/dev/null | sed 's|/$||')

    while IFS= read -r folder; do
      [[ -z "$folder" ]] && continue

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

  rm -f "$rclone_config"
  echo "$discovered"
}

# ============================================
# ROM Listing & Gamelist Functions
# ============================================

remote_roms_generate_rclone_config() {
  # Generate rclone config file for operations
  # USAGE: remote_roms_generate_rclone_config

  eval $(remote_roms_get_webdav_creds)

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

remote_roms_fetch_gamelist() {
  # Fetch gamelist.xml from remote server
  # USAGE: remote_roms_fetch_gamelist "$system"
  # Returns: 0 on success, 1 on failure

  local system="$1"
  local cache_dir="${REMOTE_ROMS_CACHE_DIR}/${system}"
  mkdir -p "$cache_dir"
  local gamelist_path="${cache_dir}/${REMOTE_ROMS_GAMELIST_FILE}"

  remote_roms_log_debug "fetch_gamelist: fetching for $system"

  # Get remote path
  local remote_path=$(remote_roms_get_setting "$system" "remote_path")
  if [[ -z "$remote_path" ]]; then
    return 1
  fi

  remote_roms_generate_rclone_config || return 1

  # Try to fetch gamelist.xml from remote
  local temp_file=$(mktemp)
  if rclone copyto "retrodeck-webdav:${remote_path}/gamelist.xml" "$temp_file" 2>/dev/null; then
    mv "$temp_file" "$gamelist_path"
    remote_roms_log_debug "fetch_gamelist: downloaded gamelist.xml for $system"
    return 0
  else
    rm -f "$temp_file"
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
  local temp_file=$(mktemp)
  if rclone lsjson "retrodeck-webdav:${remote_path}" --recursive > "$temp_file" 2>/dev/null; then
    # Filter only files and format
    local listing=$(jq '[.[] | select(.IsDir == false) | {
      "name": .Name,
      "display_name": .Name,
      "size": .Size,
      "path": .Path,
      "modtime": .ModTime
    }]' "$temp_file")
    rm -f "$temp_file"
    echo "$listing"
    return 0
  else
    rm -f "$temp_file"
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

  # Create temp file for atomic download
  local temp_file="${local_path}.tmp.$$"
  mkdir -p "$(dirname "$local_path")"

  log i "Downloading $rom_name from remote..."

  # Use rclone copyto
  if rclone copyto "retrodeck-webdav:${remote_path}/${rom_name}" "$temp_file" --progress 2>/dev/null; then
    mv "$temp_file" "$local_path"
    log i "Downloaded $rom_name successfully"
    echo "$local_path"
    return 0
  else
    rm -f "$temp_file"
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

  local system="$1"

  remote_roms_log_debug "browse_system: opening browser for $system"

  # Ensure listing is available (with automatic refresh)
  local listing=$(remote_roms_ensure_listing "$system")
  local count=$(echo "$listing" | jq 'length')

  if [[ "$count" -eq 0 ]]; then
    zenity --error --title "Remote ROMs" --text "No ROMs found for $system"
    return 1
  fi

  # For large libraries (>200), use alphabetical bucketing
  if [[ "$count" -gt 200 ]]; then
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

  local system="$1"
  local query="${2:-}"

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
  else
    # Show matches
    remote_roms_show_game_list "$system" "$matches"
  fi
}

remote_roms_virtual_browser_menu() {
  # Main entry point for virtual browser
  # USAGE: local_path=$(remote_roms_virtual_browser_menu "$system")
  # Returns: Path to downloaded/local ROM

  local system="$1"

  # Initialize and check config
  remote_roms_init_config

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
      selected_file=$(remote_roms_browse_system "$system")
      ;;
    search)
      selected_file=$(remote_roms_search_dialog "$system")
      ;;
    latest)
      # Show last 50 added
      local listing=$(remote_roms_get_system_listing "$system")
      local latest=$(echo "$listing" | jq 'sort_by(.modtime) | reverse | .[0:50]')
      selected_file=$(remote_roms_show_game_list "$system" "$latest")
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

  local system="$1"
  local system_roms_path="${roms_path}/${system}"
  local remote_folder="${system_roms_path}/remote"

  # Create remote folder
  mkdir -p "$remote_folder"

  # Create trigger file that opens the virtual browser when "launched"
  # This is a placeholder file that run_game.sh detects
  local trigger_file="${remote_folder}/Browse Remote ROMs.remote_trigger"
  echo "# This file triggers the virtual browser when selected in ES-DE" > "$trigger_file"
  echo "# System: $system" >> "$trigger_file"

  # Create gamelist.xml entry for the remote folder if gamelist exists
  local gamelist_path="${system_roms_path}/gamelist.xml"
  if [[ -f "$gamelist_path" ]]; then
    # Check if entry already exists
    if ! grep -q "Browse Remote ROMs" "$gamelist_path" 2>/dev/null; then
      # Add entry before closing </gameList> tag
      local temp_gamelist=$(mktemp)
      awk '
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
      ' "$gamelist_path" > "$temp_gamelist"
      mv "$temp_gamelist" "$gamelist_path"
    fi
  fi

  log i "ES-DE integration created for $system"
}

remote_roms_remove_esde_integration() {
  # Remove ES-DE integration files for a system
  # USAGE: remote_roms_remove_esde_integration "$system"

  local system="$1"
  local remote_folder="${roms_path}/${system}/remote"

  # Remove remote folder and trigger file
  if [[ -d "$remote_folder" ]]; then
    rm -rf "$remote_folder"
  fi

  # Remove from gamelist.xml if present
  local gamelist_path="${roms_path}/${system}/gamelist.xml"
  if [[ -f "$gamelist_path" ]] && grep -q "Browse Remote ROMs" "$gamelist_path" 2>/dev/null; then
    local temp_gamelist=$(mktemp)
    awk '
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
    ' "$gamelist_path" > "$temp_gamelist"
    mv "$temp_gamelist" "$gamelist_path"
  fi

  log i "ES-DE integration removed for $system"
}

remote_roms_set_system_auto_refresh() {
  # Set auto_refresh flag for a system
  # USAGE: remote_roms_set_system_auto_refresh "$system" "true|false"
  local system="$1"
  local value="$2"
  remote_roms_set_setting "$system" "auto_refresh" "$value"
}