#!/bin/bash
set -euo pipefail

# Build SonarQube + plugin container images locally for vulnerability work.
#
# Usage:
#   ./hack/build-images.sh [--target main|plugin|both]
#                          [--sonar-version VERSION]
#                          [--build-number NUMBER]
#                          [--tag TAG]
#                          [--skip-source]
#                          [--no-cache]
#
# Tag scheme:
#   sonarqube-main:${TAG}     for the main image
#   sonarqube-plugins:${TAG}  for the plugin image
#
# The sonar-application zip name is "sonar-application-${SONAR_VERSION}.zip"
# where SONAR_VERSION = "${BASE_VERSION}.${BUILD_NUMBER}" (e.g. 26.1.0.118079).
# Pass --sonar-version to override the full string, otherwise it is derived
# from gradle.properties + --build-number.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET="both"
SONAR_VERSION=""
BUILD_NUMBER="118079"
TAG="local-fix"
SKIP_SOURCE=false
NO_CACHE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)         TARGET="$2"; shift 2 ;;
    --sonar-version)  SONAR_VERSION="$2"; shift 2 ;;
    --build-number)   BUILD_NUMBER="$2"; shift 2 ;;
    --tag)            TAG="$2"; shift 2 ;;
    --skip-source)    SKIP_SOURCE=true; shift ;;
    --no-cache)       NO_CACHE="--no-cache"; shift ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--target main|plugin|both]
          [--sonar-version VERSION] [--build-number NUMBER]
          [--tag TAG] [--skip-source] [--no-cache]

  --target           Which image to build (default: both)
  --sonar-version    Full version string used by the Containerfile and zip
                     filename (e.g. 26.1.0.118079).
                     Default: derived from gradle.properties + --build-number.
  --build-number     Used when --sonar-version not given (default: 118079)
  --tag              Local tag suffix (default: local-fix)
  --skip-source      Reuse an existing sonar-application zip; only build container
  --no-cache         Pass --no-cache to docker build
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

cd "$REPO_ROOT"

if [ -z "$SONAR_VERSION" ]; then
  BASE_VERSION=$(awk -F= '/^version=/{print $2}' source/gradle.properties)
  if [ -z "$BASE_VERSION" ]; then
    echo "ERROR: could not parse version= from source/gradle.properties" >&2
    exit 1
  fi
  case "$BASE_VERSION" in
    *.*.*) SONAR_VERSION="${BASE_VERSION}.${BUILD_NUMBER}" ;;
    *.*)   SONAR_VERSION="${BASE_VERSION}.0.${BUILD_NUMBER}" ;;
    *)     SONAR_VERSION="${BASE_VERSION}.0.0.${BUILD_NUMBER}" ;;
  esac
fi
echo "==> Using SONAR_VERSION=$SONAR_VERSION"

build_main() {
  local zip="source/sonar-application/build/distributions/sonar-application-${SONAR_VERSION}.zip"

  if [ "$SKIP_SOURCE" = false ]; then
    if [ -f "$zip" ] && [ "${FORCE_SOURCE:-false}" != "true" ]; then
      echo "==> $zip exists — skip gradle (set FORCE_SOURCE=true to rebuild)"
    else
      echo "==> Building sonar-application via gradle (may take a few minutes)"
      local java_home="${JAVA_HOME:-}"
      if [ -z "$java_home" ] && [ -d "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home" ]; then
        java_home="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
      fi
      if [ -z "$java_home" ]; then
        echo "ERROR: JAVA_HOME not set and no openjdk@21 default found" >&2
        exit 1
      fi
      # Use an isolated env to bypass shell rc files (e.g. macOS gvm) that can
      # break the gradle wrapper with "GVM_ROOT not set".
      /usr/bin/env -i \
        PATH="$java_home/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
        HOME="$HOME" \
        JAVA_HOME="$java_home" \
        bash -c "cd '$REPO_ROOT/source' && ./gradlew :sonar-application:build -DbuildNumber='$BUILD_NUMBER' -x test --console plain --max-workers=4 --build-cache"
    fi

    if [ ! -f "$zip" ]; then
      echo "ERROR: expected artifact $zip not produced" >&2
      exit 1
    fi
  fi

  echo "==> docker build sonarqube-main:$TAG"
  docker build $NO_CACHE \
    -t "sonarqube-main:$TAG" \
    -f image/community-build/Containerfile \
    --build-arg "SONARQUBE_VERSION=$SONAR_VERSION" \
    .
}

build_plugin() {
  echo "==> docker build sonarqube-plugins:$TAG"
  docker build $NO_CACHE \
    -t "sonarqube-plugins:$TAG" \
    -f image/plugin/Containerfile \
    .
}

case "$TARGET" in
  main)    build_main ;;
  plugin)  build_plugin ;;
  both)    build_plugin; build_main ;;
  *) echo "Unknown --target: $TARGET" >&2; exit 1 ;;
esac

echo "==> Build complete."
echo "    Next: ./hack/scan-image.sh --image sonarqube-main:$TAG --image sonarqube-plugins:$TAG --summary-only"
