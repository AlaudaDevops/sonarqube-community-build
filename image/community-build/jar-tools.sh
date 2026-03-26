#!/bin/bash
# jar-tools.sh - Unified JAR file management
#
# Usage: jar-tools.sh <subcommand> [args...]
#
# Subcommands:
#   overlay <source-jar> <target-jar> [target-prefix] [prune-path...]
#       Merge source JAR contents into target JAR, preserving target manifest/signatures.
#
#   overlay-from-maven <group_id> <artifact_id> <version> <target-jar> [repository]
#       Download JAR from Maven and overlay into target JAR.
#
#   replace <group_id> <artifact_id> <old_version> <new_version> [target_dir]
#       Download new version from Maven and replace old version in target directory.
#       Set MAVEN_REPOSITORY env var to override the default Maven Central URL.

set -euo pipefail

DEFAULT_REPOSITORY="https://repo1.maven.org/maven2"

log_info()    { echo "[INFO] $*"; }
log_success() { echo "[SUCCESS] $*"; }
log_warning() { echo "[WARNING] $*" >&2; }
log_error()   { echo "[ERROR] $*" >&2; }

# Global temp dir — all subcommands drop their temp files here.
# Single EXIT trap avoids the local-variable-scope issue with bash traps.
_WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$_WORK_DIR"' EXIT

_maven_url() {  # <group_id> <artifact_id> <version> [repository]
    local group_path="${1//.//}"
    echo "${4:-$DEFAULT_REPOSITORY}/${group_path}/$2/$3/$2-$3.jar"
}

_delete_from_jar() {  # <jar-file> <entry-path>
    zip -qd "$1" "$2" "$2/*" 2>/dev/null || true
}

# ─── overlay ────────────────────────────────────────────────────────────────

cmd_overlay() {
    if [[ $# -lt 2 ]]; then
        log_error "Usage: $0 overlay <source-jar> <target-jar> [target-prefix] [prune-path...]"
        exit 1
    fi

    local source_jar="$1"
    local target_jar="$2"
    local target_prefix=""
    local prune_paths=()

    if [[ $# -ge 3 ]]; then
        target_prefix="$3"
        shift 3
        prune_paths=("$@")
    else
        shift 2
    fi

    [[ -f "$source_jar" ]] || { log_error "Source jar not found: $source_jar"; exit 1; }
    [[ -f "$target_jar" ]] || { log_error "Target jar not found: $target_jar"; exit 1; }

    local extract_dir="$_WORK_DIR/extracted"
    mkdir -p "$extract_dir"
    (cd "$extract_dir"; jar xf "$source_jar")

    # Strip manifest and signing metadata so the target's are preserved
    rm -f "$extract_dir/META-INF/MANIFEST.MF"
    rm -f "$extract_dir"/META-INF/*.SF \
          "$extract_dir"/META-INF/*.DSA \
          "$extract_dir"/META-INF/*.RSA 2>/dev/null || true

    target_prefix="${target_prefix%/}"

    if [[ -z "$target_prefix" ]]; then
        for p in "${prune_paths[@]+"${prune_paths[@]}"}"; do
            _delete_from_jar "$target_jar" "$p"
        done
        (cd "$extract_dir"; jar uf "$target_jar" .)
    else
        for p in "${prune_paths[@]+"${prune_paths[@]}"}"; do
            _delete_from_jar "$target_jar" "$target_prefix/$p"
        done
        local stage_dir="$_WORK_DIR/staged"
        mkdir -p "$stage_dir/$target_prefix"
        cp -R "$extract_dir/." "$stage_dir/$target_prefix/"
        (cd "$stage_dir"; jar uf "$target_jar" "$target_prefix")
    fi
}

# ─── overlay-from-maven ─────────────────────────────────────────────────────

cmd_overlay_from_maven() {
    if [[ $# -lt 4 ]]; then
        log_error "Usage: $0 overlay-from-maven <group_id> <artifact_id> <version> <target-jar> [target-prefix [repository]]"
        exit 1
    fi

    local group_id="$1" artifact_id="$2" version="$3" target_jar="$4"
    local target_prefix="${5:-}"
    local repository="${6:-${MAVEN_REPOSITORY:-$DEFAULT_REPOSITORY}}"
    local url
    url="$(_maven_url "$group_id" "$artifact_id" "$version" "$repository")"

    local tmp_jar="$_WORK_DIR/${artifact_id}-${version}.jar"

    if [[ ! -f "$target_jar" ]]; then
        log_warning "Target jar not found, skipping: $target_jar"
        return 0
    fi
    
    # Download only once even if called multiple times with the same version
    if [[ ! -f "$tmp_jar" ]]; then
        log_info "Downloading ${group_id}:${artifact_id}:${version}..."
        curl -fsSL "$url" -o "$tmp_jar"
    fi
    cmd_overlay "$tmp_jar" "$target_jar" "$target_prefix"
    log_success "Overlay of ${artifact_id}:${version} into $(basename "$target_jar")${target_prefix:+ (prefix: $target_prefix)} completed"
}

# ─── replace ────────────────────────────────────────────────────────────────

cmd_replace() {
    if [[ $# -lt 4 ]]; then
        log_error "Usage: $0 replace <group_id> <artifact_id> <old_version> <new_version> [target_dir]"
        exit 1
    fi

    local group_id="$1" artifact_id="$2" old_version="$3" new_version="$4"
    local target_dir="${5:-.}"
    local repository="${MAVEN_REPOSITORY:-$DEFAULT_REPOSITORY}"

    log_info "Replacing ${group_id}:${artifact_id} ${old_version} -> ${new_version} in ${target_dir}"

    local old_files=()
    while IFS= read -r -d '' f; do
        old_files+=("$f")
    done < <(find "$target_dir" -name "${artifact_id}-${old_version}.jar" -type f -print0 2>/dev/null)

    if [[ ${#old_files[@]} -eq 0 ]]; then
        log_warning "No jar found for ${artifact_id}-${old_version}.jar in ${target_dir} — skipping"
        return 0
    fi

    local url
    url="$(_maven_url "$group_id" "$artifact_id" "$new_version" "$repository")"
    local tmp_jar="$_WORK_DIR/${artifact_id}-${new_version}.jar"

    log_info "Downloading ${artifact_id}:${new_version}..."
    curl -fsSL "$url" -o "$tmp_jar"

    for old_file in "${old_files[@]}"; do
        local dir new_file
        dir="$(dirname "$old_file")"
        new_file="$dir/${artifact_id}-${new_version}.jar"
        cp "$tmp_jar" "$new_file"
        rm -f "$old_file"
        log_success "Replaced: $(basename "$old_file") -> $(basename "$new_file") in $dir"
    done
}

# ─── dispatch ───────────────────────────────────────────────────────────────

COMMAND="${1:-}"
if [[ -z "$COMMAND" ]]; then
    cat >&2 <<'EOF'
Usage: jar-tools.sh <subcommand> [args...]

Subcommands:
  overlay <source-jar> <target-jar> [target-prefix] [prune-path...]
  overlay-from-maven <group_id> <artifact_id> <version> <target-jar> [repository]
  replace <group_id> <artifact_id> <old_version> <new_version> [target_dir]
EOF
    exit 1
fi

shift
case "$COMMAND" in
    overlay)            cmd_overlay "$@" ;;
    overlay-from-maven) cmd_overlay_from_maven "$@" ;;
    replace)            cmd_replace "$@" ;;
    *)
        log_error "Unknown subcommand: $COMMAND"
        exit 1
        ;;
esac
