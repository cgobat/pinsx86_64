#!/usr/bin/env bash
set -Eeuo pipefail

IFS=$'\n\t'

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

run_as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    fail "This script requires root privileges (run as root or install sudo)"
  fi
}

is_truthy() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

GITHUB_OWNER="${GITHUB_OWNER:-acocalypso}"
GITHUB_REPO="${GITHUB_REPO:-pinsx64}"
RELEASE_TAG="${RELEASE_TAG:-v08052026-8}"

DOWNLOAD_DIR="${DOWNLOAD_DIR:-/tmp/pinsx64-release-${RELEASE_TAG}}"
OPENCV_VERSION="${OPENCV_VERSION:-4.11.0}"
OPENCV_INSTALL_PREFIX="${OPENCV_INSTALL_PREFIX:-/usr/local}"
OPENCV_BUILD_ROOT="${OPENCV_BUILD_ROOT:-/tmp/opencv-build-${OPENCV_VERSION}}"

TARGET_USER="${TARGET_USER:-${SUDO_USER:-$USER}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
if [[ -z "$TARGET_HOME" ]]; then
  TARGET_HOME="/home/$TARGET_USER"
fi

SETUP_ASTAP="${SETUP_ASTAP:-true}"
SETUP_FRAMINGASSISTANT_CACHE="${SETUP_FRAMINGASSISTANT_CACHE:-true}"

FRAMINGASSISTANT_CACHE_URL="${FRAMINGASSISTANT_CACHE_URL:-https://nighttime-imaging.eu/downloads/Setup/Releases/FramingAssistantCache_Full.zip}"
FRAMINGASSISTANT_CACHE_ROOT="${FRAMINGASSISTANT_CACHE_ROOT:-$TARGET_HOME/.local/share/NINA}"
FRAMINGASSISTANT_CACHE_DIR="${FRAMINGASSISTANT_CACHE_DIR:-$FRAMINGASSISTANT_CACHE_ROOT/FramingAssistantCache}"

SYSTEM_ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
INSTALL_DEBS=()
SKIPPED_DEBS=()

release_api_url() {
  echo "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tags/${RELEASE_TAG}"
}

check_platform() {
  [[ "$(uname -s)" == "Linux" ]] || fail "This installer must run on Linux"

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "debian" || "${VERSION_CODENAME:-}" != "trixie" ]]; then
      warn "This script targets Debian Trixie. Detected: ${PRETTY_NAME:-unknown}"
    fi
  fi
}

install_bootstrap_tools() {
  log "Installing bootstrap tools"
  run_as_root apt-get update
  run_as_root apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
    unzip \
    wget \
    rsync \
    build-essential \
    cmake \
    pkg-config
}

fetch_release_json() {
  local api_url
  api_url="$(release_api_url)"

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      "$api_url"
  else
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      "$api_url"
  fi
}

download_release_debs() {
  log "Downloading release assets from ${GITHUB_OWNER}/${GITHUB_REPO} tag ${RELEASE_TAG}"

  local release_json
  release_json="$(fetch_release_json)" || fail "Unable to fetch release metadata for tag ${RELEASE_TAG}"

  rm -rf "$DOWNLOAD_DIR"
  mkdir -p "$DOWNLOAD_DIR"

  mapfile -t deb_assets < <(
    printf '%s' "$release_json" | jq -r '.assets[] | [.name, .browser_download_url] | @tsv' | \
      awk -F '\t' '$1 ~ /\.deb$/ && ($1 ~ /_amd64\.deb$/ || $1 ~ /_all\.deb$/) { print $0 }'
  )

  [[ ${#deb_assets[@]} -gt 0 ]] || fail "No amd64/all .deb assets found in release ${RELEASE_TAG}"

  local line name url
  for line in "${deb_assets[@]}"; do
    name="${line%%$'\t'*}"
    url="${line#*$'\t'}"
    log "Downloading ${name}"
    curl -fL --retry 5 --retry-delay 3 -o "${DOWNLOAD_DIR}/${name}" "$url"

    local sha_name="${name}.sha256"
    local sha_url
    sha_url="$(printf '%s' "$release_json" | jq -r --arg n "$sha_name" '.assets[] | select(.name == $n) | .browser_download_url' | head -n 1)"
    if [[ -n "$sha_url" && "$sha_url" != "null" ]]; then
      curl -fL --retry 5 --retry-delay 3 -o "${DOWNLOAD_DIR}/${sha_name}" "$sha_url"
    fi
  done

  mapfile -t downloaded_debs < <(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -name '*.deb' | sort)
  [[ ${#downloaded_debs[@]} -gt 0 ]] || fail "No .deb files were downloaded"

  local deb_file sum_file expected actual
  for deb_file in "${downloaded_debs[@]}"; do
    sum_file="${deb_file}.sha256"
    if [[ -f "$sum_file" ]]; then
      expected="$(awk 'NR==1 { print $1 }' "$sum_file")"
      actual="$(sha256sum "$deb_file" | awk '{ print $1 }')"
      [[ -n "$expected" ]] || fail "Invalid checksum file: $sum_file"
      [[ "$expected" == "$actual" ]] || fail "Checksum mismatch for $(basename "$deb_file")"
    fi
  done

  INSTALL_DEBS=()
  SKIPPED_DEBS=()

  local pkg_arch
  for deb_file in "${downloaded_debs[@]}"; do
    pkg_arch="$(dpkg-deb -f "$deb_file" Architecture 2>/dev/null || true)"
    if [[ -z "$pkg_arch" ]]; then
      warn "Unable to read package architecture for $(basename "$deb_file"); skipping"
      SKIPPED_DEBS+=("$deb_file (unknown)")
      continue
    fi

    if [[ "$pkg_arch" == "$SYSTEM_ARCH" || "$pkg_arch" == "all" ]]; then
      INSTALL_DEBS+=("$deb_file")
    else
      warn "Skipping $(basename "$deb_file"): internal architecture is '${pkg_arch}', expected '${SYSTEM_ARCH}' or 'all'"
      SKIPPED_DEBS+=("$deb_file ($pkg_arch)")
    fi
  done

  [[ ${#INSTALL_DEBS[@]} -gt 0 ]] || fail "No installable .deb packages remain after architecture validation"

  if [[ ${#SKIPPED_DEBS[@]} -gt 0 ]]; then
    warn "Skipped ${#SKIPPED_DEBS[@]} package(s) due to architecture mismatch"
  fi

  log "Downloaded ${#downloaded_debs[@]} Debian package(s) to ${DOWNLOAD_DIR}"
}

opencv_version_matches() {
  local version="$1"
  [[ "$version" == "${OPENCV_VERSION}" || "$version" == "${OPENCV_VERSION%.*}"* ]]
}

get_current_opencv_version() {
  local version=""

  if command -v opencv_version >/dev/null 2>&1; then
    version="$(opencv_version 2>/dev/null || true)"
  fi

  if [[ -z "$version" ]]; then
    if command -v pkg-config >/dev/null 2>&1; then
      version="$(pkg-config --modversion opencv4 2>/dev/null || true)"
    fi
  fi

  echo "$version"
}

install_opencv_4_11() {
  local current_version
  current_version="$(get_current_opencv_version)"

  if [[ -n "$current_version" ]] && opencv_version_matches "$current_version"; then
    log "OpenCV ${current_version} already installed"
    return
  fi

  log "Installing OpenCV ${OPENCV_VERSION} from source"

  run_as_root apt-get update
  run_as_root apt-get install -y --no-install-recommends \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libdc1394-dev \
    libgtk-3-dev \
    libjpeg-dev \
    libpng-dev \
    libswscale-dev \
    libtiff-dev \
    libv4l-dev \
    zlib1g-dev

  rm -rf "$OPENCV_BUILD_ROOT"
  mkdir -p "$OPENCV_BUILD_ROOT"

  local archive="${OPENCV_BUILD_ROOT}/opencv-${OPENCV_VERSION}.tar.gz"
  curl -fL --retry 5 --retry-delay 3 \
    "https://codeload.github.com/opencv/opencv/tar.gz/refs/tags/${OPENCV_VERSION}" \
    -o "$archive"

  tar -xzf "$archive" -C "$OPENCV_BUILD_ROOT"

  local src_dir="${OPENCV_BUILD_ROOT}/opencv-${OPENCV_VERSION}"
  local build_dir="${src_dir}/build"

  cmake -S "$src_dir" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$OPENCV_INSTALL_PREFIX" \
    -DBUILD_LIST=core,imgproc,highgui,videoio,imgcodecs \
    -DBUILD_TESTS=OFF \
    -DBUILD_PERF_TESTS=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DWITH_FFMPEG=ON \
    -DWITH_GSTREAMER=OFF \
    -DWITH_OPENCL=OFF \
    -DWITH_IPP=OFF \
    -DWITH_TBB=OFF

  cmake --build "$build_dir" --parallel "$(nproc)"
  run_as_root cmake --install "$build_dir"
  run_as_root ldconfig

  local final_version
  final_version="$(get_current_opencv_version)"
  if ! opencv_version_matches "$final_version"; then
    fail "OpenCV install check failed. Found '${final_version:-none}', expected ${OPENCV_VERSION}"
  fi

  log "OpenCV ${final_version} is ready"
}

install_release_packages() {
  log "Installing release Debian packages"

  [[ ${#INSTALL_DEBS[@]} -gt 0 ]] || fail "No validated release .deb packages available for installation"

  run_as_root dpkg -i "${INSTALL_DEBS[@]}" || true
  run_as_root apt-get -f install -y
  run_as_root dpkg -i "${INSTALL_DEBS[@]}"
}

verify_indi_server_version() {
  local version
  version="$(dpkg-query -W -f='${Version}' indi-bin 2>/dev/null || true)"
  [[ -n "$version" ]] || fail "indi-bin package is not installed"

  if [[ "$version" != 2.1.9* ]]; then
    fail "indi-bin version is ${version}, expected 2.1.9.x"
  fi

  log "INDI server package version ${version} installed"
}

setup_astap() {
  if ! is_truthy "$SETUP_ASTAP"; then
    log "Skipping ASTAP setup"
    return
  fi

  log "Installing ASTAP"
  run_as_root apt-get update
  run_as_root apt-get install -y astap

  if command -v astap >/dev/null 2>&1; then
    log "ASTAP installed at $(command -v astap)"
  else
    warn "ASTAP package installed but binary not found in PATH"
  fi
}

setup_framingassistant_cache() {
  if ! is_truthy "$SETUP_FRAMINGASSISTANT_CACHE"; then
    log "Skipping FramingAssistant cache setup"
    return
  fi

  log "Installing FramingAssistant cache"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local zip_path="${tmp_dir}/FramingAssistantCache_Full.zip"
  local unzip_dir="${tmp_dir}/unzipped"

  mkdir -p "$FRAMINGASSISTANT_CACHE_ROOT"
  curl -fL --retry 5 --retry-delay 3 -o "$zip_path" "$FRAMINGASSISTANT_CACHE_URL"

  rm -rf "$FRAMINGASSISTANT_CACHE_DIR"
  mkdir -p "$FRAMINGASSISTANT_CACHE_DIR"
  unzip -q "$zip_path" -d "$unzip_dir"

  if [[ -d "$unzip_dir/FramingAssistantCache" ]]; then
    rsync -a "$unzip_dir/FramingAssistantCache/" "$FRAMINGASSISTANT_CACHE_DIR/"
  elif [[ -d "$unzip_dir/framingassistantcache" ]]; then
    rsync -a "$unzip_dir/framingassistantcache/" "$FRAMINGASSISTANT_CACHE_DIR/"
  else
    rsync -a "$unzip_dir/" "$FRAMINGASSISTANT_CACHE_DIR/"
  fi

  run_as_root chown -R "$TARGET_USER:$TARGET_USER" "$FRAMINGASSISTANT_CACHE_ROOT" || true
  rm -rf "$tmp_dir"

  log "FramingAssistant cache installed at ${FRAMINGASSISTANT_CACHE_DIR}"
}

print_summary() {
  log "Installer completed"
  echo
  echo "Release source: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${RELEASE_TAG}"
  echo "Downloaded packages:"
  find "$DOWNLOAD_DIR" -maxdepth 1 -type f -name '*.deb' -printf '  - %f\n' | sort
  if [[ ${#SKIPPED_DEBS[@]} -gt 0 ]]; then
    echo
    echo "Skipped packages (architecture mismatch):"
    printf '  - %s\n' "${SKIPPED_DEBS[@]}" | sed 's|.*/||'
  fi
  echo
  echo "Key versions:"
  echo "  OpenCV: $(get_current_opencv_version || true)"
  echo "  indi-bin: $(dpkg-query -W -f='${Version}' indi-bin 2>/dev/null || echo not-installed)"
}

main() {
  check_platform
  install_bootstrap_tools
  download_release_debs
  install_opencv_4_11
  install_release_packages
  verify_indi_server_version
  setup_astap
  setup_framingassistant_cache
  print_summary
}

main "$@"
