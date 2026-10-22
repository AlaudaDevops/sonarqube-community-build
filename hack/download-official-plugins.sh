#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
manifest=${1:-$script_dir/official-plugins-26.1.txt}
[ -f "$manifest" ] || { echo "manifest not found: $manifest" >&2; exit 1; }
output_dir=${2:-/tmp/sonarqube-official-plugins-26.1}
# Change this default or export MAVEN_REPO_URL to use an internal proxy.
repo_url=${MAVEN_REPO_URL:-https://repo1.maven.org/maven2}
archive_name=sonarqube-official-plugins-26.1.tgz
archive_path="$(dirname "$output_dir")/$archive_name"
mkdir -p "$output_dir"

# sonar-javascript-plugin's `multi` classifier has no linux-arm64 Node runtime: for
# SonarQube on arm64 nodes run with JS_CLASSIFIER=linux-arm64.
while IFS=: read -r group artifact version classifier; do
  [[ -z "${group:-}" || "$group" == \#* ]] && continue
  if [[ "$artifact" == "sonar-javascript-plugin" && -n "${JS_CLASSIFIER:-}" ]]; then
    classifier=$JS_CLASSIFIER
  fi
  path="${group//.//}/$artifact/$version"
  suffix="${artifact}-${version}"
  [[ -n "${classifier:-}" ]] && suffix="${suffix}-${classifier}"
  url="$repo_url/$path/$suffix.jar"
  target="$output_dir/$suffix.jar"
  echo "Downloading $url"
  curl --fail --location --retry 3 --output "$target" "$url"
done < "$manifest"

tar -czf "$archive_path" -C "$output_dir" .
echo "Downloaded $(find "$output_dir" -maxdepth 1 -name '*.jar' | wc -l | tr -d ' ') plugin JAR(s) to $output_dir"
echo "Created $archive_path"
