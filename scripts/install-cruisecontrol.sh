#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="ilovespectra"
REPO_NAME="CruiseControl"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

version_from_plist() {
  if [[ -f "${REPO_DIR}/Resources/Info.plist" ]]; then
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${REPO_DIR}/Resources/Info.plist" 2>/dev/null || echo "1.0.0"
    return
  fi
  echo "1.0.0"
}

APP_VERSION="$(version_from_plist)"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required. Install them with: xcode-select --install" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required to install Cruise Control." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required to install Cruise Control." >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

if [[ -d "${REPO_DIR}/.git" ]]; then
  echo "Using the checked-out repo at ${REPO_DIR}"
  repo_path="${REPO_DIR}"
else
  echo "Downloading Cruise Control v${APP_VERSION} from GitHub..."
  git clone --depth 1 "${REPO_URL}" "${tmp_dir}/${REPO_NAME}"
  repo_path="${tmp_dir}/${REPO_NAME}"
fi

if [[ -f "${repo_path}/scripts/build-app.sh" ]]; then
  echo "Installing Cruise Control v${APP_VERSION} to /Applications..."
  (cd "${repo_path}" && ./scripts/build-app.sh --install)
  echo "Installed: /Applications/Cruise Control.app"
  echo "Version: ${APP_VERSION}"
else
  echo "The source bundle is missing scripts/build-app.sh; download failed or the repo layout changed." >&2
  exit 1
fi
