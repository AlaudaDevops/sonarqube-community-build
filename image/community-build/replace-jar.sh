#!/bin/bash

# SonarQube JAR File Management Script
# Function: Find jar files of specified version, download new version from Maven repository, delete old version
# Author: Alauda DevOps Team
# Version: 1.0.0

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Show help information
show_help() {
    cat << EOF
SonarQube JAR File Management Script

Usage: $0 [options] <group_id> <artifact_id> <old_version> <new_version> [target_directory]

Parameters:
    group_id         Maven group ID (e.g.: net.minidev)
    artifact_id      Maven artifact ID (e.g.: json-smart)
    old_version      Current version number (e.g.: 2.4.3)
    new_version      New version number (e.g.: 2.5.2)
    target_directory Target directory (optional, defaults to current directory)
                     Supports multiple directories, separated by spaces (e.g.: "/opt/sonarqube/lib /opt/sonarqube/extensions/plugins")

Options:
    -h, --help       Show this help information
    -r, --repository Maven repository URL (default: https://repo1.maven.org/maven2)
    -d, --dry-run    Only show operations to be performed, do not actually execute
    -v, --verbose    Verbose output
    -f, --force      Force replacement even if file is in use
    --backup         Backup old files to backup directory
    --checksum       Verify checksum of downloaded files

Features:
    - Automatically detect jar files of the same version in multiple directories
    - Smart download: Download the same plugin only once, then copy to various directories
    - Place new version jar files in the same directory as the old version
    - Support multiple jar file naming patterns
    - Provide detailed execution logs and error handling
    - Automatically clean up temporary files

Examples:
    # Single directory replacement
    $0 net.minidev json-smart 2.4.3 2.5.2 /opt/sonarqube/lib
    
    # Multi-directory replacement (automatically detect all directories containing the jar)
    $0 net.minidev json-smart 2.4.3 2.5.2 "/opt/sonarqube/lib /opt/sonarqube/extensions/plugins"
    
    # Replacement with backup
    $0 io.netty netty-handler 4.1.100.Final 4.1.123.Final --backup
    
    # Using Alibaba Cloud mirror source
    $0 -r https://maven.aliyun.com/repository/central net.minidev json-smart 2.4.3 2.5.2

EOF
}

# Default configuration
DEFAULT_REPOSITORY="https://repo1.maven.org/maven2"
DRY_RUN=false
VERBOSE=false
FORCE=false
BACKUP=false
CHECKSUM=false
TARGET_DIR="."

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -r|--repository)
                REPOSITORY="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            --backup)
                BACKUP=true
                shift
                ;;
            --checksum)
                CHECKSUM=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                if [[ -z "${GROUP_ID:-}" ]]; then
                    GROUP_ID="$1"
                elif [[ -z "${ARTIFACT_ID:-}" ]]; then
                    ARTIFACT_ID="$1"
                elif [[ -z "${OLD_VERSION:-}" ]]; then
                    OLD_VERSION="$1"
                elif [[ -z "${NEW_VERSION:-}" ]]; then
                    NEW_VERSION="$1"
                elif [[ -z "${TARGET_DIR:-}" ]] || [[ "$TARGET_DIR" == "." ]]; then
                    TARGET_DIR="$1"
                else
                    log_error "Too many parameters: $1"
                    show_help
                    exit 1
                fi
                shift
                ;;
        esac
    done
}

# Validate required parameters
validate_arguments() {
    if [[ -z "${GROUP_ID:-}" || -z "${ARTIFACT_ID:-}" || -z "${OLD_VERSION:-}" || -z "${NEW_VERSION:-}" ]]; then
        log_error "Missing required parameters"
        show_help
        exit 1
    fi

    # Check target directories (supports multiple directories)
    IFS=' ' read -ra DIRS <<< "$TARGET_DIR"
    local missing_dirs=()
    
    for dir in "${DIRS[@]}"; do
        if [[ ! -d "$dir" ]]; then
            missing_dirs+=("$dir")
        fi
    done
    
    if [[ ${#missing_dirs[@]} -gt 0 ]]; then
        log_error "The following directories do not exist: ${missing_dirs[*]}"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    local missing_deps=()
    
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    if ! command -v find &> /dev/null; then
        missing_deps+=("find")
    fi
    
    if ! command -v rm &> /dev/null; then
        missing_deps+=("rm")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_deps[*]}"
        exit 1
    fi
}

# Find jar files of specified version (supports multiple directories)
find_jar_files() {
    local group_id="$1"
    local artifact_id="$2"
    local version="$3"
    local target_dirs="$4"
    
    log_info "Searching for jar files of $group_id:$artifact_id:$version in directories..."
    
    # Build possible filename patterns
    local patterns=(
        "${artifact_id}-${version}.jar"
    )
    
    local found_files=()
    local found_dirs=()
    
    # If target_dirs contains multiple directories, split by space
    IFS=' ' read -ra DIRS <<< "$target_dirs"
    
    for target_dir in "${DIRS[@]}"; do
        if [[ ! -d "$target_dir" ]]; then
            log_warning "Directory does not exist, skipping: $target_dir"
            continue
        fi
        
        log_info "Searching directory: $target_dir"
        local dir_has_files=false
        
        for pattern in "${patterns[@]}"; do
            while IFS= read -r -d '' file; do
                found_files+=("$file")
                if [[ "$dir_has_files" == "false" ]]; then
                    found_dirs+=("$target_dir")
                    dir_has_files=true
                fi
            done < <(find "$target_dir" -name "$pattern" -type f -print0 2>/dev/null || true)
        done
    done
    
    if [[ ${#found_files[@]} -eq 0 ]]; then
        log_warning "No jar files found for $group_id:$artifact_id:$version"
        return 1
    fi
    
    # Output found files and directory information
    printf '%s\n' "${found_files[@]}"
    return 0
}

# Get list of directories containing jar files
get_jar_directories() {
    local group_id="$1"
    local artifact_id="$2"
    local version="$3"
    local target_dirs="$4"
    
    local found_dirs=()
    
    # Build possible filename patterns
    local patterns=(
        "${artifact_id}-${version}.jar"
        "${artifact_id}-${version}-all.jar"
        "${artifact_id}-${version}-sources.jar"
        "${artifact_id}-${version}-javadoc.jar"
        "*${artifact_id}*${version}*.jar"
    )
    
    # If target_dirs contains multiple directories, split by space
    IFS=' ' read -ra DIRS <<< "$target_dirs"
    
    for target_dir in "${DIRS[@]}"; do
        if [[ ! -d "$target_dir" ]]; then
            continue
        fi
        
        local dir_has_files=false
        for pattern in "${patterns[@]}"; do
            if find "$target_dir" -name "$pattern" -type f -print0 2>/dev/null | grep -q .; then
                dir_has_files=true
                break
            fi
        done
        
        if [[ "$dir_has_files" == "true" ]]; then
            found_dirs+=("$target_dir")
        fi
    done
    
    printf '%s\n' "${found_dirs[@]}"
    return 0
}

# Build Maven repository URL
build_maven_url() {
    local group_id="$1"
    local artifact_id="$2"
    local version="$3"
    local repository="$4"
    
    # Replace dots in group_id with slashes
    local group_path="${group_id//.//}"
    
    echo "${repository}/${group_path}/${artifact_id}/${version}/${artifact_id}-${version}.jar"
}

# Download jar file
download_jar() {
    local url="$1"
    local target_file="$2"
    local checksum_url="${url}.sha1"
    
    log_info "Downloading jar file from $url to $target_file"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would download: $url -> $target_file"
        return 0
    fi
    
    # Create temporary file
    local temp_file="${target_file}.tmp"
    
    # Download file
    if ! curl -L -f -o "$temp_file" "$url"; then
        log_error "Download failed: $url"
        return 1
    fi
    
    # Verify checksum (if enabled)
    if [[ "$CHECKSUM" == "true" ]]; then
        log_info "Verifying file checksum..."
        if curl -L -f -s "$checksum_url" | sha1sum -c - <(echo "$(cat "$temp_file" | sha1sum | cut -d' ' -f1)  -"); then
            log_success "Checksum verification passed"
        else
            log_warning "Checksum verification failed, but continuing execution"
        fi
    fi
    
    # Move temporary file to target location
    mv "$temp_file" "$target_file"
    log_success "Download completed: $target_file"
}

# Backup file
backup_file() {
    local file="$1"
    local backup_dir="$2"
    
    if [[ "$BACKUP" != "true" ]]; then
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would backup: $file -> $backup_dir/"
        return 0
    fi
    
    mkdir -p "$backup_dir"
    local backup_file="$backup_dir/$(basename "$file").backup.$(date +%Y%m%d_%H%M%S)"
    
    if cp "$file" "$backup_file"; then
        log_success "File backed up to: $backup_file"
    else
        log_warning "Backup failed: $file"
    fi
}

# Remove file
remove_file() {
    local file="$1"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would delete: $file"
        return 0
    fi
    
    # Check if file is in use
    if [[ "$FORCE" != "true" ]] && lsof "$file" &>/dev/null; then
        log_warning "File is in use: $file"
        if [[ "$FORCE" != "true" ]]; then
            log_error "Use --force option to force deletion, or stop the process using the file first"
            return 1
        fi
    fi
    
    if rm -f "$file"; then
        log_success "Deleted: $file"
    else
        log_error "Deletion failed: $file"
        return 1
    fi
}

# Main function
main() {
    # Set default values
    REPOSITORY="${REPOSITORY:-$DEFAULT_REPOSITORY}"
    
    # Parse arguments
    parse_arguments "$@"
    
    # Validate arguments
    validate_arguments
    
    # Check dependencies
    check_dependencies
    
    log_info "Starting JAR file management operation"
    log_info "Group ID: $GROUP_ID"
    log_info "Artifact ID: $ARTIFACT_ID"
    log_info "Old version: $OLD_VERSION"
    log_info "New version: $NEW_VERSION"
    log_info "Target directory: $TARGET_DIR"
    log_info "Maven repository: $REPOSITORY"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Run mode: Dry run"
    fi
    
    # Find old version jar files
    local old_files
    if ! old_files=$(find_jar_files "$GROUP_ID" "$ARTIFACT_ID" "$OLD_VERSION" "$TARGET_DIR"); then
        log_error "No old version jar files found, operation terminated"
        exit 1
    fi
    
    # Get list of directories containing jar files
    local jar_directories
    jar_directories=$(get_jar_directories "$GROUP_ID" "$ARTIFACT_ID" "$OLD_VERSION" "$TARGET_DIR") || {
        log_error "Failed to get jar file directory list"
        exit 1
    }
    
    # Build new version jar file URL
    local new_jar_url
    new_jar_url=$(build_maven_url "$GROUP_ID" "$ARTIFACT_ID" "$NEW_VERSION" "$REPOSITORY") || {
        log_error "Failed to build Maven URL"
        exit 1
    }
    
    log_info "Found old version files:"
    while IFS= read -r file; do
        if [[ -n "$file" && "$file" != *"[INFO]"* ]]; then
            log_info "  - $file"
        fi
    done <<< "$old_files"
    
    log_info "Directories containing jar files:"
    while IFS= read -r dir; do
        if [[ -n "$dir" ]]; then
            log_info "  - $dir"
        fi
    done <<< "$jar_directories"
    
    # Backup old files
    if [[ "$BACKUP" == "true" ]]; then
        echo "$old_files" | while read -r file; do
            local backup_dir
            backup_dir="$(dirname "$file")/backup"
            backup_file "$file" "$backup_dir"
        done
    fi
    
    # Download new version jar to temporary location first
    local temp_new_jar="/tmp/${ARTIFACT_ID}-${NEW_VERSION}.jar"
    log_info "Downloading new version jar file to temporary location: $temp_new_jar"
    
    if ! download_jar "$new_jar_url" "$temp_new_jar"; then
        log_error "Failed to download new version jar file, operation terminated"
        exit 1
    fi
    
    # Copy new version jar to same directory for each old version jar file
    local copy_failed=false
    while IFS= read -r old_file; do
        if [[ -n "$old_file" && "$old_file" != *"[INFO]"* ]]; then
            local old_dir="$(dirname "$old_file")"
            local new_jar_file="$old_dir/${ARTIFACT_ID}-${NEW_VERSION}.jar"
            log_info "Copying new version jar to directory: $old_dir"
            
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would copy: $temp_new_jar -> $new_jar_file"
            else
                if cp "$temp_new_jar" "$new_jar_file"; then
                    log_success "New version jar file copy completed: $new_jar_file"
                else
                    log_error "Failed to copy new version jar file: $new_jar_file"
                    copy_failed=true
                fi
            fi
        fi
    done <<< "$old_files"
    
    # Clean up temporary files
    if [[ "$DRY_RUN" != "true" ]]; then
        rm -f "$temp_new_jar"
    fi
    
    if [[ "$copy_failed" == "true" ]]; then
        log_error "Failed to copy new version jar for some files, operation terminated"
        exit 1
    fi
    
    # Delete old version jar files
    echo "$old_files" | while read -r file; do
        if ! remove_file "$file"; then
            log_error "Failed to delete old file: $file"
            exit 1
        fi
    done
    
    log_success "JAR file management operation completed!"
    log_info "New files have been placed in the following locations:"
    while IFS= read -r old_file; do
        if [[ -n "$old_file" && "$old_file" != *"[INFO]"* ]]; then
            local old_dir="$(dirname "$old_file")"
            log_info "  - $old_dir/${ARTIFACT_ID}-${NEW_VERSION}.jar"
        fi
    done <<< "$old_files"
    
    if [[ "$BACKUP" == "true" ]]; then
        log_info "Backup file locations: backup/ folder in each directory"
    fi
}

main "$@"
