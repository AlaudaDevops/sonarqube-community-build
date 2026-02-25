#!/bin/bash
# Simple script to update image tag in values.yaml file using shell + regex
# Usage: ./update-image-tag.sh <full-image-url> [values-file]
# Examples: 
#   ./update-image-tag.sh build-harbor.alauda.cn/devops/gitlab-org/build/cng/kubectl:1.32.4-68777
#   ./update-image-tag.sh build-harbor.alauda.cn/devops/gitlab-org/build/cng/gitlab-rust:1.73.0-884436e@sha256:42a4dd272191e258c23c810dc6998651d7e2ae153d944b830fa35b70ddee131b

set -euo pipefail

# Default registry to remove
DEFAULT_REGISTRY="build-harbor.alauda.cn"

# Function to display usage
usage() {
    echo "Usage: $0 <full-image-url> [values-file]"
    echo "Examples:"
    echo "  $0 build-harbor.alauda.cn/devops/gitlab-org/build/cng/kubectl:1.32.4-68777"
    echo "  $0 build-harbor.alauda.cn/devops/gitlab-org/build/cng/gitlab-rust:1.73.0-884436e@sha256:42a4dd272191e258c23c810dc6998651d7e2ae153d944b830fa35b70ddee131b"
    echo "  $0 build-harbor.alauda.cn/devops/gitlab-org/build/cng/kubectl:1.32.4-68777 modules/gitlab-chart/values.yaml"
    exit 1
}

# Function to extract tag from image URL
extract_tag() {
    local image_url="$1"
    
    if [[ ! "$image_url" =~ : ]]; then
        echo "Error: Image URL must contain a tag (separated by ':')" >&2
        exit 1
    fi
    
    # First, handle the @sha256: case by removing it if present
    local image_without_hash="${image_url%%@sha256:*}"
    
    # Then extract the tag (everything after the last :)
    echo "${image_without_hash##*:}"
}

# Function to extract image name from URL
extract_image_name() {
    local image_url="$1"
    # First, handle the @sha256: case by removing it if present
    local image_without_hash="${image_url%%@sha256:*}"
    # Remove registry and tag, then get the last part
    local without_tag="${image_without_hash%:*}"
    local without_registry="${without_tag#*${DEFAULT_REGISTRY}/}"
    echo "${without_registry}"
}

# Function to update tags using sed/awk - cross-platform compatible
update_tags() {
    local image_url="$1"
    local values_file="$2"
    
    local tag
    tag=$(extract_tag "$image_url")
    local image_name
    image_name=$(extract_image_name "$image_url")
    
    echo "Updating all '$image_name' tags to: $tag"
    
    # Create a temporary file
    local temp_file="${values_file}.tmp.$$"
    local updated_count=0
    local skipped_count=0
    
    # Read file into array to access next line
    local lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done < "$values_file"
    
    # Process lines with next line lookahead
    local total_lines=${#lines[@]}
    for ((i=0; i<total_lines; i++)); do
        local current_line="${lines[i]}"
        local line_num=$((i + 1))
        
        # Check if current line contains our target repository
        if [[ "$current_line" =~ repository:.*$image_name$ || "$current_line" =~ image:.*$image_name$ ]]; then
            echo "Found $image_name at line $line_num: $current_line"
            echo "$current_line" >> "$temp_file"
            
            # Check if next line exists and is a tag line
            if [[ $((i + 1)) -lt $total_lines ]]; then
                local next_line="${lines[$((i + 1))]}"
                local next_line_num=$((i + 2))
                
                if [[ "$next_line" =~ ^[[:space:]]*tag: ]]; then
                    # Found tag line right after repository line - update it
                    local old_tag=$(echo "$next_line" | sed 's/.*tag: *//')
                    local new_line=$(echo "$next_line" | sed "s/tag: .*/tag: $tag/")
                    echo "  ✅ Updated tag at line $next_line_num: $old_tag -> $tag"
                    echo "$new_line" >> "$temp_file"
                    updated_count=$((updated_count + 1))
                    i=$((i + 1)) # Skip the next line since we've processed it
                else
                    # Next line is not a tag line - skip this repository
                    echo "  ⚠️  Skipped: Next line $next_line_num is not a tag line: $next_line"
                    ((skipped_count++))
                fi
            else
                # No next line - skip this repository
                echo "  ⚠️  Skipped: No next line after repository line"
                ((skipped_count++))
            fi
        else
            # Regular line - just copy it
            echo "$current_line" >> "$temp_file"
        fi
    done
    
    if [[ $updated_count -gt 0 ]]; then
        mv "$temp_file" "$values_file"
        echo ""
        echo "✅ Successfully updated $updated_count '$image_name' tag(s) to '$tag'"
        if [[ $skipped_count -gt 0 ]]; then
            echo "⚠️  Skipped $skipped_count '$image_name' repository(ies) where tag was not on the next line"
        fi
    else
        rm -f "$temp_file"
        echo ""
        if [[ $skipped_count -gt 0 ]]; then
            echo "⚠️  Found $skipped_count '$image_name' repository(ies) but no valid tag lines to update"
        else
            echo "⚠️  No '$image_name' repositories found in $values_file"
        fi
        echo "Available image names:"
        grep "repository:" "$values_file" | sed 's/.*\///' | sort | uniq | head -10
        return 1
    fi
}

# Main execution
main() {
    local image_url="$1"
    local values_file="${2:-modules/gitlab-chart/values.yaml}"
    
    echo "🚀 Processing: $image_url"
    echo "📝 Target file: $values_file"
    
    # Validate parameters
    if [[ -z "$image_url" ]]; then
        echo "❌ Error: Image URL is required"
        usage
    fi
    
    if [[ ! -f "$values_file" ]]; then
        echo "❌ Error: File $values_file does not exist"
        exit 1
    fi
    
    if [[ ! -w "$values_file" ]]; then
        echo "❌ Error: File $values_file is not writable"
        exit 1
    fi
    
    # Update tags
    update_tags "$image_url" "$values_file"
}

# Execute if script is run directly
if [[ "${0}" == "${BASH_SOURCE[0]:-$0}" ]]; then
    if [[ $# -lt 1 ]]; then
        usage
    fi
    main "$@"
fi 