#!/usr/bin/env bash
set -euo pipefail

BUILDER_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=versions.env
source "$BUILDER_ROOT/versions.env"

for required_var in \
    WSL_REPOSITORY WSL_REF WSL_COMMIT \
    ZFS_REPOSITORY ZFS_REF ZFS_COMMIT BUILD_SUFFIX; do
    if [[ -z "${!required_var:-}" ]]; then
        echo "Missing required variable: $required_var" >&2
        exit 1
    fi
done

BUILD_ROOT=${BUILD_WORK_DIR:-${RUNNER_TEMP:-$BUILDER_ROOT/.work}/wsl-zfs-builder}
OUTPUT_DIR="$BUILDER_ROOT/output"
KERNEL_DIR="$BUILD_ROOT/kernel"
ZFS_DIR="$BUILD_ROOT/zfs"
MODULES_DIR="$BUILD_ROOT/modules"

case "$BUILD_ROOT" in
    ""|/|"$BUILDER_ROOT")
        echo "Refusing unsafe BUILD_ROOT: $BUILD_ROOT" >&2
        exit 1
        ;;
esac

rm -rf -- "$BUILD_ROOT" "$OUTPUT_DIR"
mkdir -p "$BUILD_ROOT" "$OUTPUT_DIR"

echo ">>> [1/6] Installing build dependencies..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y \
    autoconf automake bc binutils bison build-essential cpio curl dwarves \
    e2fsprogs flex gawk git libaio-dev libattr1-dev libblkid-dev libelf-dev \
    libffi-dev libssl-dev libtirpc-dev libtool libudev-dev python3 \
    python3-cffi python3-dev python3-setuptools qemu-utils rsync uuid-dev \
    zlib1g-dev

fetch_pinned_source() {
    local repository=$1
    local ref=$2
    local expected_commit=$3
    local destination=$4
    local actual_commit

    git init -q "$destination"
    git -C "$destination" remote add origin "$repository"
    echo "Fetching $ref at $expected_commit"
    git -C "$destination" fetch --depth 1 origin "$expected_commit"
    git -C "$destination" checkout -q --detach "$expected_commit"

    actual_commit=$(git -C "$destination" rev-parse HEAD)
    if [[ "$actual_commit" != "$expected_commit" ]]; then
        echo "Source verification failed for $repository" >&2
        echo "Expected: $expected_commit" >&2
        echo "Actual:   $actual_commit" >&2
        exit 1
    fi
}

echo ">>> [2/6] Fetching pinned WSL kernel..."
fetch_pinned_source "$WSL_REPOSITORY" "$WSL_REF" "$WSL_COMMIT" "$KERNEL_DIR"

echo ">>> [3/6] Preparing kernel and pinned OpenZFS..."
export KCONFIG_CONFIG="$KERNEL_DIR/Microsoft/config-wsl"
# An explicitly set empty LOCALVERSION suppresses the SCM '+' suffix.
export LOCALVERSION=""

make -C "$KERNEL_DIR" olddefconfig
make -C "$KERNEL_DIR" prepare scripts

fetch_pinned_source "$ZFS_REPOSITORY" "$ZFS_REF" "$ZFS_COMMIT" "$ZFS_DIR"
pushd "$ZFS_DIR"
sh autogen.sh
./configure \
    --prefix=/ \
    --libdir=/lib \
    --includedir=/usr/include \
    --datarootdir=/usr/share \
    --enable-linux-builtin=yes \
    --with-linux="$KERNEL_DIR" \
    --with-linux-obj="$KERNEL_DIR"
./copy-builtin "$KERNEL_DIR"
popd

"$KERNEL_DIR/scripts/config" --file "$KCONFIG_CONFIG" \
    --enable ZFS \
    --set-str LOCALVERSION "-microsoft-standard-WSL2-$ZFS_REF-$BUILD_SUFFIX"
make -C "$KERNEL_DIR" olddefconfig

BUILD_JOBS=$(nproc)
if [[ "${CI:-}" == "true" && "$BUILD_JOBS" -gt 1 ]]; then
    BUILD_JOBS=$((BUILD_JOBS - 1))
elif [[ "$BUILD_JOBS" -gt 2 ]]; then
    BUILD_JOBS=$((BUILD_JOBS / 2))
fi

echo ">>> [4/6] Building kernel and modules with $BUILD_JOBS jobs..."
make -C "$KERNEL_DIR" -j"$BUILD_JOBS"
make -C "$KERNEL_DIR" -j"$BUILD_JOBS" \
    INSTALL_MOD_PATH="$MODULES_DIR" modules_install

KERNEL_RELEASE=$(make -s -C "$KERNEL_DIR" kernelrelease)
KERNEL_VERSION=$(make -s -C "$KERNEL_DIR" kernelversion)

echo ">>> [5/6] Packaging WSL kernel modules..."
install -m 0644 "$KERNEL_DIR/arch/x86/boot/bzImage" "$OUTPUT_DIR/bzImage"
sudo "$BUILDER_ROOT/scripts/gen_modules_vhdx.sh" \
    "$MODULES_DIR" \
    "$KERNEL_RELEASE" \
    "$OUTPUT_DIR/modules.vhdx"

cat > "$OUTPUT_DIR/build-manifest.txt" <<EOF
WSL_REPOSITORY=$WSL_REPOSITORY
WSL_REF=$WSL_REF
WSL_COMMIT=$WSL_COMMIT
ZFS_REPOSITORY=$ZFS_REPOSITORY
ZFS_REF=$ZFS_REF
ZFS_COMMIT=$ZFS_COMMIT
KERNEL_VERSION=$KERNEL_VERSION
KERNEL_RELEASE=$KERNEL_RELEASE
EOF

echo ">>> [6/6] Build complete: $OUTPUT_DIR"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "kernel_release=$KERNEL_RELEASE"
        echo "kernel_version=$KERNEL_VERSION"
        echo "zfs_ref=$ZFS_REF"
        echo "release_tag=linux-msft-wsl-$KERNEL_VERSION-$ZFS_REF"
    } >> "$GITHUB_OUTPUT"
fi

if [[ "${KEEP_BUILD_DIR:-0}" != "1" ]]; then
    rm -rf -- "$BUILD_ROOT"
fi
