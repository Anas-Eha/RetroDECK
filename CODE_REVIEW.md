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

## Conclusion

The implementation is **functionally correct** and ready for testing. The critical duplicate code has been fixed. Address P0 and P1 items before production release.

Estimated effort to production-ready: 2-3 hours of focused work.