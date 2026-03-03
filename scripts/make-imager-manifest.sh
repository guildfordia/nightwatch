#!/bin/bash
# Nightwatch — Generate Pi Imager manifest for custom image
#
# Creates a .rpi-imager-manifest file that enables the customization
# step (hostname, SSH, user, WiFi) in Raspberry Pi Imager when using
# our golden image.
#
# Usage:
#   ./scripts/make-imager-manifest.sh nightwatch.img.xz
#   ./scripts/make-imager-manifest.sh nightwatch.img
#
# Then to flash:
#   Double-click nightwatch.rpi-imager-manifest → Pi Imager opens
#   → Choose storage → Set hostname, SSH, user → Flash
#
# Or from command line:
#   rpi-imager --repo nightwatch.rpi-imager-manifest

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

if [ $# -lt 1 ]; then
    echo "Usage: $0 <image_file>"
    echo ""
    echo "  image_file: nightwatch.img.xz, nightwatch.img.gz, or nightwatch.img"
    echo ""
    echo "Generates a .rpi-imager-manifest file next to the image."
    echo "Double-click it to open Pi Imager with customization enabled."
    exit 1
fi

IMAGE="$1"

if [ ! -f "$IMAGE" ]; then
    echo -e "${RED}Error: File not found: $IMAGE${NC}"
    exit 1
fi

IMAGE_FULLPATH="$(cd "$(dirname "$IMAGE")" && pwd)/$(basename "$IMAGE")"
IMAGE_DIR="$(dirname "$IMAGE_FULLPATH")"
IMAGE_NAME="$(basename "$IMAGE")"
MANIFEST_NAME="nightwatch.rpi-imager-manifest"
MANIFEST_PATH="$IMAGE_DIR/$MANIFEST_NAME"

echo "[+] Computing image checksums and sizes..."

# Portable sha256: works on both Linux (sha256sum) and macOS (shasum -a 256)
portable_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@" | awk '{print $1}'
    else
        shasum -a 256 "$@" | awk '{print $1}'
    fi
}

# Get compressed file size
DOWNLOAD_SIZE=$(stat -c%s "$IMAGE_FULLPATH" 2>/dev/null || stat -f%z "$IMAGE_FULLPATH" 2>/dev/null)

# Get extracted size and sha256
case "$IMAGE_NAME" in
    *.img.xz)
        EXTRACT_SIZE=$(xz --robot --list "$IMAGE_FULLPATH" 2>/dev/null | grep totals | awk '{print $5}')
        EXTRACT_SHA256=$(xz -dc "$IMAGE_FULLPATH" | portable_sha256 /dev/stdin)
        ;;
    *.img.gz)
        EXTRACT_SHA256=$(gzip -dc "$IMAGE_FULLPATH" | portable_sha256 /dev/stdin)
        EXTRACT_SIZE=$(gzip -dc "$IMAGE_FULLPATH" | wc -c)
        ;;
    *.img)
        EXTRACT_SIZE=$DOWNLOAD_SIZE
        EXTRACT_SHA256=$(portable_sha256 "$IMAGE_FULLPATH")
        ;;
    *)
        echo -e "${RED}Error: Unsupported format. Use .img, .img.xz, or .img.gz${NC}"
        exit 1
        ;;
esac

RELEASE_DATE=$(date +%Y-%m-%d)

echo "[+] Generating manifest..."

cat > "$MANIFEST_PATH" << JSONEOF
{
  "os_list": [
    {
      "name": "Nightwatch",
      "description": "Nightwatch mesh network — pre-installed, auto-configures from hostname",
      "icon": "https://raw.githubusercontent.com/guildfordia/nightwatch/main/html/favicon.ico",
      "url": "file://$IMAGE_FULLPATH",
      "extract_size": $EXTRACT_SIZE,
      "extract_sha256": "$EXTRACT_SHA256",
      "image_download_size": $DOWNLOAD_SIZE,
      "release_date": "$RELEASE_DATE",
      "init_format": "systemd",
      "devices": [
        "pi4-32bit", "pi4-64bit",
        "pi5-32bit", "pi5-64bit",
        "pi3-32bit", "pi3-64bit",
        "pi400-32bit", "pi400-64bit"
      ]
    }
  ]
}
JSONEOF

echo ""
echo -e "${GREEN}${BOLD}======================================"
echo "  Manifest Created!"
echo "======================================${NC}"
echo ""
echo "  Image:     $IMAGE_FULLPATH"
echo "  Manifest:  $MANIFEST_PATH"
echo ""
echo -e "  ${BOLD}To flash:${NC}"
echo "  1. Double-click ${BOLD}$MANIFEST_NAME${NC}"
echo "     → Pi Imager opens with Nightwatch pre-selected"
echo "  2. Choose storage (SD card)"
echo "  3. Click Next → customize:"
echo "     - Hostname: nightwatch-1 (or nightwatch-2, etc.)"
echo "     - Enable SSH"
echo "     - Set username/password"
echo "  4. Flash!"
echo ""
echo "  Or from command line:"
echo "     rpi-imager --repo $MANIFEST_PATH"
echo ""
