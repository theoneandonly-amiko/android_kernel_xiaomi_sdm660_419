#!/usr/bin/env bash
set -euo pipefail

KERNEL_DIR="${KERNEL_DIR:-$PWD}"
TC_DIR="${TC_DIR:-$KERNEL_DIR/../toolchain/aosp-clang}"
OUT_DIR="${OUT_DIR:-$KERNEL_DIR/out}"
DEVICE="${DEVICE:-whyred}"
DEFCONFIG="${DEFCONFIG:-vendor/whyred-perf_defconfig}"
LTO_MODE="${LTO_MODE:-thin}"
KERNEL_NAME="${KERNEL_NAME:-Maya-Kernel-v2.0-Sienna}"
AK3_DIR="${AK3_DIR:-$KERNEL_DIR/AnyKernel3}"
ZIP_NAME="${KERNEL_NAME}-${DEVICE}-$(date +'%Y%m%d-%H%M').zip"

: "${BOT_TOKEN:?BOT_TOKEN not yet set}"
: "${CHAT_ID:?CHAT_ID not yet set}"

BUILD_START=$(date +%s)

push_message() {
    [ "${OC_BUILD:-0}" = "1" ] && return 0
    local resp
    resp=$(curl -s --retry 3 --retry-delay 3 --connect-timeout 15 --max-time 60 \
        -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d text="$1" \
        -d parse_mode="html" \
        -d disable_web_page_preview="true") || { echo "[telegram] curl failed (exit $?)"; return 0; }
    echo "$resp" | grep -q '"ok":true' || echo "[telegram] sendMessage failed: $resp"
}

push_document() {
    [ "${OC_BUILD:-0}" = "1" ] && return 0
    local resp
    resp=$(curl -s --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 300 \
        -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" \
        -F chat_id="${CHAT_ID}" \
        -F document=@"$1" \
        --form-string caption="$2" \
        -F parse_mode="html") || { echo "[telegram] curl failed (exit $?)"; return 0; }
    echo "$resp" | grep -q '"ok":true' || echo "[telegram] sendDocument failed: $resp"
}

export PATH="$TC_DIR/bin:$PATH"
CLANG_VER="$(clang --version | head -n1)"
CORES="$(nproc --all)"
BRANCH="$(git -C "$KERNEL_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
LAST_COMMIT="$(git -C "$KERNEL_DIR" log --pretty=format:'%s' -1 2>/dev/null || echo -)"

push_message "<b>🔨 Build Started</b>
<b>Device:</b> <code>${DEVICE}</code>
<b>Defconfig:</b> <code>${DEFCONFIG}</code>
<b>LTO:</b> <code>${LTO_MODE}</code>
<b>Compiler:</b> <code>${CLANG_VER}</code>
<b>Cores:</b> <code>${CORES}</code>
<b>Branch:</b> <code>${BRANCH}</code>
<b>Last commit:</b> <code>${LAST_COMMIT}</code>"

cd "$KERNEL_DIR"
mkdir -p "$OUT_DIR"

TOOLCHAIN_ARGS=(
    ARCH=arm64
    CC="ccache clang"
    HOSTCC="ccache clang"
    HOSTCXX="ccache clang++"
    LD=ld.lld
    AR=llvm-ar
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    STRIP=llvm-strip
    LLVM=1
    LLVM_IAS=1
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-
)
[ "$LTO_MODE" != "none" ] && TOOLCHAIN_ARGS+=(LTO="$LTO_MODE")

make O="$OUT_DIR" "${TOOLCHAIN_ARGS[@]}" "$DEFCONFIG"

set +e
make -j"$CORES" O="$OUT_DIR" "${TOOLCHAIN_ARGS[@]}" 2>&1 | tee >(grep -iE --line-buffered "error|warning" >&2)
BUILD_STATUS=${PIPESTATUS[0]}
set -e

BUILD_END=$(date +%s)
DIFF=$((BUILD_END - BUILD_START))
MIN=$((DIFF / 60)); SEC=$((DIFF % 60))

IMG="$OUT_DIR/arch/arm64/boot/Image.gz-dtb"
[ -f "$IMG" ] || IMG="$OUT_DIR/arch/arm64/boot/Image.gz"

if [ "$BUILD_STATUS" -ne 0 ] || [ ! -f "$IMG" ]; then
    push_message "<b>❌ Build Failed</b>
<b>Device:</b> <code>${DEVICE}</code>
<b>Duration:</b> <code>${MIN}m ${SEC}s</code>
Check the runner log for error details; use grep 'error' on the output above."
    exit 1
fi

if [ ! -f "$AK3_DIR/tools/magiskboot" ]; then
    push_message "<b>⚠️ AnyKernel3 not yet prepared</b>
Folder <code>${AK3_DIR}</code> none yet <code>tools/magiskboot</code>.
First, manually extract a package that has been proven to work; see the comments at build.sh."
    echo "[ak3] GAGAL: $AK3_DIR/tools/magiskboot not found."
    echo "[ak3] First, manually extract the AK3 package:"
    echo "       mkdir -p \"$AK3_DIR\" && cd \"$AK3_DIR\""
    echo "       unzip -o /path/paket-working.zip -d ."
    echo "       rm -f Image.gz-dtb"
    exit 1
fi

cat > "$AK3_DIR/anykernel.sh" <<'EOF'
### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
properties() { '
kernel.string=MayaKernel by gusssamm
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=whyred
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
'; } # end properties

block=/dev/block/bootdevice/by-name/boot;
is_slot_device=0;
ramdisk_compression=auto;
patch_vbmeta_flag=auto;

. tools/ak3-core.sh;

set_perm_recursive 0 0 755 644 $ramdisk/*;
set_perm_recursive 0 0 750 750 $ramdisk/init* $ramdisk/sbin;

dump_boot;
write_boot;
EOF

cp -f "$IMG" "$AK3_DIR/Image.gz-dtb"
PACK_ITEMS=(anykernel.sh Image.gz-dtb META-INF tools)
for item in modules patch ramdisk; do
    [ -e "$AK3_DIR/$item" ] && PACK_ITEMS+=("$item")
done
( cd "$AK3_DIR" && zip -r9 "$KERNEL_DIR/$ZIP_NAME" "${PACK_ITEMS[@]}" -x ".git*" )

MD5=$(md5sum "$KERNEL_DIR/$ZIP_NAME" | cut -d' ' -f1)

push_document "$KERNEL_DIR/$ZIP_NAME" "<b>✅ Build Success</b>
<b>Device:</b> <code>${DEVICE}</code>
<b>Defconfig:</b> <code>${DEFCONFIG}</code>
<b>LTO:</b> <code>${LTO_MODE}</code>
<b>MD5:</b> <code>${MD5}</code>
<b>Durasi:</b> <code>${MIN}m ${SEC}s</code>"

echo "Selesai: $ZIP_NAME (md5: $MD5)"
