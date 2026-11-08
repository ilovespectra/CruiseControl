#!/usr/bin/env bash
# Downloads a version-pinned package; does not execute downloaded scripts or disable macOS security.
set -euo pipefail
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Cruise Control requires macOS 14 or later." >&2
  exit 1
fi
REPO="https://github.com/ilovespectra/CruiseControl"
RELEASE="$(curl --proto '=https' --tlsv1.2 -fsSL -o /dev/null -w '%{url_effective}' "$REPO/releases/latest")"
if ! printf '%s\n' "$RELEASE" | grep -Eq '^https://github.com/ilovespectra/CruiseControl/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "No valid public binary release is available." >&2
  exit 1
fi
DOWNLOAD="${RELEASE/\/tag\//\/download\/}"
STAGE="$(mktemp -d -t cruise-download)"
trap 'rm -rf "$STAGE"' EXIT
curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL "$DOWNLOAD/SHA256SUMS" -o "$STAGE/SHA256SUMS"
curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL "$DOWNLOAD/CruiseControl.pkg" -o "$STAGE/CruiseControl.pkg"
if ! grep -Eq '^[0-9a-f]{64}  CruiseControl\.pkg$' "$STAGE/SHA256SUMS" || [[ "$(wc -l < "$STAGE/SHA256SUMS" | tr -d ' ')" != 1 ]]; then
  echo "Invalid checksum metadata. Download cancelled." >&2
  exit 1
fi
(cd "$STAGE" && shasum -a 256 -c SHA256SUMS)
DESTINATION="$HOME/Downloads/CruiseControl-${RELEASE##*/}.pkg"
mkdir -p "$HOME/Downloads"
cp "$STAGE/CruiseControl.pkg" "$DESTINATION"
echo "Verified package saved to: $DESTINATION"
echo "Unsigned releases trigger macOS warnings. Review the source before approving in Privacy & Security."
open "$DESTINATION"
