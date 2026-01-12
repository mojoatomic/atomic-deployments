#!/bin/bash
# deploy.sh - Atomic deployment via symlink swap
set -euo pipefail

SCRIPT_NAME="${0##*/}"
readonly SCRIPT_NAME

# Global state for cleanup and rollback
PREVIOUS_RELEASE=""
CLEANUP_RELEASE_DIR=""
CLEANUP_TEMP_SYMLINK=""
RELEASE_ACTIVATED="false"
SWAP_IN_PROGRESS="false"
LOCK_DIR=""

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
error() { log "ERROR: $*" >&2; }
die() { error "$*"; exit 1; }

acquire_lock() {
    local deploy_root="$1"
    LOCK_DIR="$deploy_root/.deploy.lock"

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        # Lock acquired - write PID for debugging
        printf '%s' "$$" > "$LOCK_DIR/pid"
        log "Lock acquired (PID: $$)"
        return 0
    fi

    # Lock exists - check if stale
    local existing_pid
    existing_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || printf '')"

    if [[ -n "$existing_pid" ]]; then
        if kill -0 "$existing_pid" 2>/dev/null; then
            die "Deployment already in progress (PID: $existing_pid)"
        fi

        # Stale lock - process not running
        log "Removing stale lock from PID: $existing_pid"
        rm -rf "$LOCK_DIR"

        if mkdir "$LOCK_DIR" 2>/dev/null; then
            printf '%s' "$$" > "$LOCK_DIR/pid"
            log "Lock acquired (PID: $$)"
            return 0
        fi
    fi

    die "Failed to acquire deployment lock"
}

release_lock() {
    if [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        log "Lock released"
    fi
}

rollback() {
    if [[ -z "$PREVIOUS_RELEASE" ]]; then
        log "No previous release to rollback to"
        return 0
    fi

    if [[ ! -d "$PREVIOUS_RELEASE" ]]; then
        error "Previous release directory missing: $PREVIOUS_RELEASE"
        return 1
    fi

    log "Rolling back to: $PREVIOUS_RELEASE"

    local platform
    platform="$(detect_platform)"

    local rollback_temp=".tmp/rollback.$$"

    if [[ "$platform" == "linux" ]]; then
        ln -s "$PREVIOUS_RELEASE" "$rollback_temp" || return 1
        mv -T "$rollback_temp" "current" || return 1
    else
        command -v python3 >/dev/null || { error "python3 required for rollback"; return 1; }
        ln -s "$(pwd)/$PREVIOUS_RELEASE" "$rollback_temp" || return 1
        python3 -c "import os; os.replace('$rollback_temp', 'current')" || return 1
    fi

    log "Rollback successful"
    return 0
}

cleanup() {
    local exit_code=$?

    # Attempt rollback if swap was in progress but didn't complete
    if [[ "$SWAP_IN_PROGRESS" == "true" && "$RELEASE_ACTIVATED" != "true" ]]; then
        rollback || true  # Don't fail cleanup if rollback fails
    fi

    # Only clean up release dir if not yet activated
    if [[ "$RELEASE_ACTIVATED" != "true" ]]; then
        if [[ -n "$CLEANUP_RELEASE_DIR" && -d "$CLEANUP_RELEASE_DIR" ]]; then
            log "Cleaning up incomplete release: $CLEANUP_RELEASE_DIR"
            rm -rf "$CLEANUP_RELEASE_DIR"
        fi
    fi

    # Always clean up temp symlink
    if [[ -n "$CLEANUP_TEMP_SYMLINK" && -e "$CLEANUP_TEMP_SYMLINK" ]]; then
        rm -f "$CLEANUP_TEMP_SYMLINK"
    fi

    # Release lock
    release_lock

    return "$exit_code"
}

# Set up signal handlers
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

create_directory_structure() {
    local deploy_root="$1"

    log "Creating directory structure"
    mkdir -p "$deploy_root/releases" \
        || die "Failed to create releases directory: $deploy_root/releases"
    mkdir -p "$deploy_root/.tmp" || die "Failed to create temp directory: $deploy_root/.tmp"
}

generate_release_id() {
    date +%Y%m%d%H%M%S
}

create_release() {
    local src_dir="$1"
    local rel_dir="$2"

    log "Creating release directory: $rel_dir"
    mkdir -p "$rel_dir" || die "Failed to create release directory: $rel_dir"

    log "Copying files from: $src_dir"
    cp -r "$src_dir/." "$rel_dir/" || die "Failed to copy files to release directory: $rel_dir"
}

validate_release() {
    local rel_dir="$1"

    log "Validating release"
    if [[ -z "$(ls -A "$rel_dir")" ]]; then
        die "Release directory is empty: $rel_dir"
    fi
    log "Release validated successfully"
}

detect_platform() {
    if mv --version 2>/dev/null | grep -q 'GNU'; then
        printf 'linux'
    else
        printf 'bsd'
    fi
}

activate_release() {
    local rel_id="$1"
    local platform

    platform="$(detect_platform)"
    log "Detected platform: $platform"

    # Store previous release for potential rollback (global variable)
    # Note: readlink returns relative path (e.g., "releases/20260112") on macOS.
    # This works because we've already cd'd to deployment_root in main().
    if [[ -L "current" ]]; then
        PREVIOUS_RELEASE="$(readlink "current")"
        log "Previous release: $PREVIOUS_RELEASE"
    else
        log "First deployment (no previous release)"
    fi

    log "Activating release: $rel_id"

    # Mark swap as in progress for rollback handling
    SWAP_IN_PROGRESS="true"

    # Track temp symlink for cleanup
    CLEANUP_TEMP_SYMLINK=".tmp/current.$$"

    if [[ "$platform" == "linux" ]]; then
        # Linux: use mv -T for atomic rename
        ln -s "releases/$rel_id" "$CLEANUP_TEMP_SYMLINK" \
            || die "Failed to create temporary symlink"
        mv -T "$CLEANUP_TEMP_SYMLINK" "current" \
            || die "Failed to activate release (atomic swap failed)"
    else
        # macOS/BSD: BSD mv follows symlinks, can't do atomic rename
        # Use Python os.replace() which calls rename(2) directly
        command -v python3 >/dev/null \
            || die "python3 required for atomic deploys on macOS/BSD"
        ln -s "releases/$rel_id" "$CLEANUP_TEMP_SYMLINK" \
            || die "Failed to create temporary symlink"
        python3 -c "import os; os.replace('$CLEANUP_TEMP_SYMLINK', 'current')" \
            || die "Failed to activate release (atomic swap failed)"
    fi

    # Clear temp symlink tracker (it's been moved/renamed)
    CLEANUP_TEMP_SYMLINK=""

    # Swap complete
    SWAP_IN_PROGRESS="false"

    log "Release activated successfully"
}

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME <source_dir> <deployment_root>

Atomic deployment via symlink swap with automatic rollback.

Arguments:
    source_dir       Directory containing files to deploy
    deployment_root  Root directory for deployments (will contain releases/)

Options:
    -h, --help      Show this help message

Example:
    $SCRIPT_NAME ./build /var/www/myapp

EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -*) die "Unknown option: $1" ;;
            *) break ;;
        esac
    done

    [[ $# -eq 2 ]] || { usage; exit 1; }

    local source_dir="$1"
    readonly deployment_root="$2"

    [[ -d "$source_dir" ]] || die "Source directory does not exist: $source_dir"

    # Convert to absolute path before cd'ing to deployment_root
    source_dir="$(cd "$source_dir" && pwd)"
    readonly source_dir

    log "Starting deployment"
    log "Source: $source_dir"
    log "Target: $deployment_root"

    mkdir -p "$deployment_root" || die "Failed to create deployment root: $deployment_root"
    cd "$deployment_root" || die "Cannot change to deployment root: $deployment_root"

    acquire_lock "."

    create_directory_structure "."

    local release_id
    release_id="$(generate_release_id)"
    readonly release_id
    # Use relative path since we've cd'd to deployment_root
    readonly release_dir="releases/$release_id"

    log "Release ID: $release_id"

    # Track release dir for cleanup on abort
    CLEANUP_RELEASE_DIR="$release_dir"

    create_release "$source_dir" "$release_dir"
    validate_release "$release_dir"

    activate_release "$release_id"

    # Mark as activated so cleanup won't remove it
    RELEASE_ACTIVATED="true"

    log "Deployment complete: $release_dir"
}

main "$@"
