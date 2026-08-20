#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 || ! -d "$1" ]]; then
    echo "Usage: $0 <modules dir> <kernel release> <output file>" >&2
    exit 1
fi

MODULES_DIR=$1
KERNEL_RELEASE=$2
OUTPUT_FILE=$3
MODULE_TREE="$MODULES_DIR/lib/modules/$KERNEL_RELEASE"

if [[ ! -d "$MODULE_TREE" ]]; then
    echo "No modules found at $MODULE_TREE" >&2
    exit 2
fi

if [[ -e "$OUTPUT_FILE" ]]; then
    echo "Refusing to overwrite existing file: $OUTPUT_FILE" >&2
    exit 3
fi

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# WSL's kernelModules setting mounts the VHDX root directly at
# /lib/modules/<kernel-release>. Keep the module files at the filesystem root;
# do not use the newer <kernel-release>/modules artifacts bundle layout.
STAGING_DIR="$TEMP_DIR/staging"
mkdir -p "$STAGING_DIR"
cp -r "$MODULE_TREE/." "$STAGING_DIR/"

# These links point into the ephemeral CI checkout and are unusable in WSL.
rm -f "$STAGING_DIR/build" "$STAGING_DIR/source"

STAGING_SIZE=$(du -bs "$STAGING_DIR" | awk '{print $1}')
IMAGE_SIZE=$((STAGING_SIZE + (256 * (1 << 20))))
IMAGE_BLOCKS=$(((IMAGE_SIZE + 1023) / 1024))
INODE_COUNT=$(find "$STAGING_DIR" -printf . | wc -c)
INODE_COUNT=$((INODE_COUNT + 4096))

mke2fs -q \
    -L '' \
    -d "$STAGING_DIR" \
    -N "$INODE_COUNT" \
    -b 1024 \
    -t ext4 \
    "$TEMP_DIR/modules.img" \
    "$IMAGE_BLOCKS"

qemu-img convert -O vhdx "$TEMP_DIR/modules.img" "$OUTPUT_FILE"

if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
    chown "$SUDO_UID:$SUDO_GID" "$OUTPUT_FILE"
fi
