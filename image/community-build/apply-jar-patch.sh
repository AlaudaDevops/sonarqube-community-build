#!/bin/bash

# Apply jar patches to replace vulnerable jar files in target directory
# Usage: apply-jar-patch.sh <patches_directory> [target_directory]

set -euo pipefail

# Global variables
readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_TARGET_DIR="/opt"
readonly LOG_PREFIX="[JAR-PATCH]"

# Cleanup function for trap
cleanup() {
    local exit_code=$?
    echo "${LOG_PREFIX} Script exited with code ${exit_code}"
    exit ${exit_code}
}

# Set up trap for cleanup
trap cleanup EXIT

# Print usage information
usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <patches_directory> [target_directory]

Apply jar patches to replace vulnerable jar files in target directory.

Arguments:
    patches_directory    Directory containing jar patch files
    target_directory     Target directory to search for jar files (default: ${DEFAULT_TARGET_DIR})

Examples:
    ${SCRIPT_NAME} /home/patches
    ${SCRIPT_NAME} /home/patches /opt/sonarqube
    ${SCRIPT_NAME} patches ./test-env/opt

EOF
}

# Log function with timestamp
log() {
    echo "${LOG_PREFIX} $(date '+%Y-%m-%d %H:%M:%S') $*"
}

# Extract base name from jar filename by removing version
# Example: json-smart-2.5.2.jar -> json-smart
extract_base_name() {
    local jar_file="$1"
    local filename
    local base_name
    
    filename="$(basename "${jar_file}" .jar)"
    # Remove version pattern - handles various formats:
    # - json-smart-2.5.2.jar -> json-smart
    # - netty-handler-4.1.118.Final.jar -> netty-handler
    # - commons-lang3-3.12.0.jar -> commons-lang3
    # - spring-boot-2.7.0-SNAPSHOT.jar -> spring-boot
    # First try to remove standard version patterns
    base_name="$(echo "${filename}" | sed -E 's/-[0-9]+(\.[0-9]+)*(\.[0-9]+)*(-[A-Za-z0-9]+)*$//')"
    # If no change, try a more aggressive pattern for complex versions
    if [ "${base_name}" = "${filename}" ]; then
        base_name="$(echo "${filename}" | sed -E 's/-[0-9]+(\.[0-9]+)*(\.[0-9]+)*\.([A-Za-z0-9]+)*$//')"
    fi
    echo "${base_name}"
}

# Find all jar files matching base name in target directory
find_target_jars() {
    local base_name="$1"
    local target_dir="$2"
    
    find "${target_dir}" -name "${base_name}-*.jar" -type f 2>/dev/null || true
}

# Replace jar file with patch
replace_jar() {
    local patch_jar="$1"
    local target_jar="$2"
    
    log "Replacing ${target_jar} with ${patch_jar}"
    
    # Replace with patch
    cp "${patch_jar}" $(dirname ${target_jar})
    rm "${target_jar}"
    log "Successfully replaced ${target_jar}"
}

# Process single patch jar file
process_patch_jar() {
    local patch_jar="$1"
    local target_dir="$2"
    local base_name
    local target_jars
    local target_jar
    local count=0
    
    log "Processing patch jar: ${patch_jar}"
    
    # Extract base name
    base_name="$(extract_base_name "${patch_jar}")"
    log "Base name extracted: ${base_name}"
    
    # Find target jars
    target_jars="$(find_target_jars "${base_name}" "${target_dir}")"
    
    if [ -z "${target_jars}" ]; then
        log "No target jars found for base name: ${base_name}"
        return 0
    fi
    
    # Replace each target jar
    while IFS= read -r target_jar; do
        if [ -n "${target_jar}" ]; then
            replace_jar "${patch_jar}" "${target_jar}"
            count=$((count + 1))
        fi
    done <<< "${target_jars}"
    
    log "Replaced ${count} jar(s) for base name: ${base_name}"
    return 0
}

# Main function
main() {
    local patches_dir="${1:-}"
    local target_dir="${2:-${DEFAULT_TARGET_DIR}}"
    local patch_count=0
    local success_count=0
    
    # Check for help argument
    if [ "${patches_dir}" = "--help" ] || [ "${patches_dir}" = "-h" ]; then
        usage
        exit 0
    fi
    
    # Check arguments
    if [ -z "${patches_dir}" ]; then
        log "Error: patches directory is required"
        usage
        exit 1
    fi
    
    # Check if patches directory exists
    if [ ! -d "${patches_dir}" ]; then
        log "Error: patches directory does not exist: ${patches_dir}"
        exit 1
    fi
    
    # Check if target directory exists
    if [ ! -d "${target_dir}" ]; then
        log "Error: target directory does not exist: ${target_dir}"
        exit 1
    fi
    
    log "Starting jar patch process"
    log "Patches directory: ${patches_dir}"
    log "Target directory: ${target_dir}"
    
    # Process each jar file in patches directory
    for patch_jar in "${patches_dir}"/*.jar; do
        # Check if glob matched any files
        if [ ! -f "${patch_jar}" ]; then
            log "No jar files found in patches directory: ${patches_dir}"
            continue
        fi
        
        patch_count=$((patch_count + 1))
        
        # Process patch jar
        if process_patch_jar "${patch_jar}" "${target_dir}"; then
            success_count=$((success_count + 1))
        else
            log "Warning: Failed to process patch jar: ${patch_jar}"
        fi
    done
    
    # Summary
    log "Patch process completed"
    log "Total patches processed: ${patch_count}"
    log "Successfully applied: ${success_count}"
    
    if [ ${success_count} -eq ${patch_count} ]; then
        log "All patches applied successfully"
        exit 0
    else
        log "Some patches failed to apply"
        exit 1
    fi
}

# Execute main function with all arguments
main "$@"
