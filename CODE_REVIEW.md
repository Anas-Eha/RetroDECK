# Architectural Review: Remote ROMs Feature

## Executive Summary
The Remote ROMs feature implementation is functionally correct but has several architectural issues that need addressing before production deployment.

## Critical Issues Found

### 1. DUPLICATE CODE in `run_game.sh` (FIXED)
**Location**: Lines 74-128 and 130-145
**Issue**: Two separate blocks handling the same remote/ folder logic
**Fix**: Removed duplicate block

### 2. Missing Error Handling in `remote_roms_test_connection()`
**Location**: `functions/remote_roms.sh:78-93`
**Issue**: Function returns "false" on error but doesn't distinguish between:
- Missing credentials
- Network failure
- Authentication failure
- rclone not installed

**Current Code**:
```bash
if RCLONE_CONFIG="$rclone_config" rclone ls "webdav-test:/" --max-depth 1 --contimeout 10s > /dev/null 2>&1; then
  echo "true"
else
  echo "false"
fi
```

**Recommended Fix**:
```bash
remote_roms_test_connection() {
  local url=$(remote_roms_get_setting "webdav_url")
  local user=$(remote_roms_get_setting "webdav_user")
  
  if [[ -z "$url" || -z "$user" ]]; then
    echo "missing_config"
    return 1
  fi
  
  if ! command -v rclone &> /dev/null; then
    echo "rclone_not_found"
    return 1
  fi
  
  # ... rest of test
}
```

### 3. Race Condition in Mount Check
**Location**: `remote_roms_mount_system()`
**Issue**: `mountpoint -q` check happens before verifying rclone config exists
**Risk**: Could attempt mount with stale/broken config

### 4. Inconsistent Variable Naming
**Issue**: Mix of snake_case and inconsistent prefixes
- `remote_visible` vs `system_path`
- `remote_hidden` (old name) vs `remote_visible` (new name)

### 5. Missing Cleanup on Failed Download
**Location**: `run_game.sh` download block
**Issue**: If download is interrupted, partial file remains
**Fix**: Download to temp file, then atomic move

### 6. No Validation of Downloaded File
**Issue**: No checksum or size verification after download
**Risk**: Corrupted files could be saved and used

## Style Issues

### 1. Inconsistent Function Documentation
Some functions have USAGE comments, others don't. Standardize on:
```bash
# Function: name
# Purpose: one line description
# Arguments: $1 - description
# Returns: description or exit codes
# Side Effects: any file/config changes
```

### 2. Missing `local` Declarations
Several variables in functions should be declared local:
- `mount_config`, `enabled`, `remote_path` in mount functions

### 3. Inconsistent Quote Usage
Mix of `"$var"` and `'$var'` in similar contexts

## Architecture Improvements

### 1. Separate Concerns Better
Current: `remote_roms.sh` handles config, mounting, AND downloading
Better: Split into:
- `remote_roms_config.sh` - Configuration management
- `remote_roms_mount.sh` - Mount/unmount operations
- `remote_roms_sync.sh` - Download/sync operations

### 2. Add State Machine
Track mount state explicitly rather than checking mountpoint each time:
```bash
# In config
"mount_state": "unmounted|mounting|mounted|error"
"last_error": "error message"
```

### 3. Implement Retry Logic
Downloads and mounts should have retry with exponential backoff

### 4. Add Health Checks
Periodic verification that mounts are still valid

## Security Issues

### 1. Password in Config (ACCEPTABLE FOR NOW)
WebDAV password stored in retrodeck.cfg
**Mitigation**: File is in user's home directory with appropriate permissions
**Future**: Consider using secret service or keyring

### 2. rclone Config Permissions
Generated rclone.conf should have 0600 permissions
**Fix**: Add `chmod 600 "$rclone_dir/rclone.conf"` after creation

## Performance Issues

### 1. Multiple jq Calls
Each setting get/set spawns jq process
**Optimization**: Cache config in memory during operations

### 2. Synchronous Downloads
Large ROMs block UI during download
**Current**: Progress dialog helps but still blocks
**Future**: Background download queue

## Testing Gaps

No automated tests for:
- Mount/unmount lifecycle
- Download resume after interruption
- Concurrent access to same ROM
- Network failure handling
- Config migration/upgrade

## Recommended Fixes (Priority Order)

### P0 (Critical)
1. ✅ Remove duplicate code in run_game.sh (DONE)
2. Add atomic download (temp file + move)
3. Fix rclone config permissions

### P1 (High)
4. Improve error handling in test_connection
5. Add file size validation after download
6. Standardize variable naming

### P2 (Medium)
7. Split into multiple files
8. Add retry logic
9. Implement health checks

### P3 (Low)
10. Add automated tests
11. Optimize jq calls
12. Background download queue

## Positive Aspects

✅ Clean separation between UI (dialogs.sh) and logic (remote_roms.sh)
✅ Good use of existing RetroDECK patterns (config, logging)
✅ Proper integration with run_game.sh
✅ README.txt helps users understand the structure
✅ No external dependencies beyond rclone (already in manifest)

## Dialog Functions Review (functions/dialogs.sh)

### Issues in `configurator_remote_roms_discover_dialog()`

**1. Predictable Temp File (Security)**
- Location: Line ~1380
- Issue: `/tmp/remote_roms_discovered` uses predictable filename
- Risk: Race condition if multiple RetroDECK instances run simultaneously
- Fix: Use `mktemp` with proper suffix: `$(mktemp /tmp/remote_roms_discovered.XXXXXX)`

**2. Silent Failures in Discovery**
- Location: rclone commands with `2>/dev/null`
- Issue: All rclone errors suppressed, user sees "0 folders found" with no explanation
- Fix: Capture stderr to log file and show meaningful error messages

**3. Unquoted Variable in grep**
- Location: `echo "$root_folders" | grep -q "^${subfolder}$"`
- Issue: If root_folders is empty or has special characters, grep may fail unexpectedly
- Fix: Use `[[ "$root_folders" =~ (^| )${subfolder}($| ) ]]` or proper quoting

### Issues in `configurator_remote_roms_manage_system_dialog()`

**4. Invalid Return Path (CRITICAL)**
- Location: Line ~1555 (cancel handler)
- Issue: `configurator_remote_roms_discover_dialog` - this function may not exist in current flow
- Fix: Change to `configurator_data_management_dialog`

**5. Infinite Recursion Risk**
- Location: End of function (line ~1598)
- Issue: Function calls itself to "refresh" - stack grows with each action
- Risk: Stack overflow after many operations
- Fix: Use a while loop instead of recursion:
```bash
configurator_remote_roms_manage_system_dialog() {
  local system="$1"
  while true; do
    # ... build menu and show dialog ...
    if [[ $rc -ne 0 || -z "$choice" ]]; then
      configurator_data_management_dialog
      return
    fi
    # ... handle choice ...
    # Remove the recursive call at end, loop will refresh
  done
}
```

**6. Missing Error Handling for Mount Operations**
- Location: "Mount" case
- Issue: `remote_roms_mount_system` return code checked, but no logging of WHY it failed
- Fix: Log the specific error before showing generic dialog

### Issues in `configurator_remote_roms_connection_dialog()`

**7. Form Parsing Fragility**
- Location: `cut -d'|' -f1` etc.
- Issue: If user enters `|` character in URL or password, parsing breaks
- Fix: Use different delimiter or validate input contains no `|`

**8. Password Obscuration Not Validated**
- Location: `rclone obscure "$pass"`
- Issue: If rclone fails (not installed), password stored in plaintext
- Fix: Check if obscure succeeded before saving

### Issues in `configurator_remote_roms_test_dialog()`

**9. Temp File Not Cleaned on Interrupt**
- Location: `/tmp/remote_roms_test_result`
- Issue: If user kills dialog mid-test, temp file remains
- Fix: Use `trap` or mktemp with cleanup

### General Issues

**10. Inconsistent Navigation Pattern**
- Some functions return to `configurator_data_management_dialog`
- Others try to return to non-existent intermediate dialogs
- Need consistent "Back" behavior throughout

**11. Missing `local` Declarations**
- Variables like `choice`, `rc`, `menu_options` not declared local
- Risk: Variable leakage between functions

**12. No Validation of remote_roms_get_available_systems**
- If this returns empty, discovery silently finds nothing
- Should warn user if no systems are configured

## Conclusion

The implementation is **functionally correct** and ready for testing. The critical duplicate code has been fixed. Address P0 and P1 items before production release.

Estimated effort to production-ready: 2-3 hours of focused work.