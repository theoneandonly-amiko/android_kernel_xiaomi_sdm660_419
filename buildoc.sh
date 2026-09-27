#!/usr/bin/env bash
set -euo pipefail

KERNEL_DIR="${KERNEL_DIR:-$PWD}"
OC_PATCH="$KERNEL_DIR/oc/oc.patch"
OC_FILES=(
	arch/arm64/boot/dts/vendor/qcom/sdm660.dtsi
	arch/arm64/boot/dts/vendor/qcom/sdm660-gpu-oc.dtsi
	arch/arm64/boot/dts/vendor/qcom/sdm660-thermal.dtsi
	block/ssg-iosched.c
)
DEVICE="${DEVICE:-whyred}"
KERNEL_NAME="${KERNEL_NAME:-Maya-Kernel-v2.0-Sienna-OC}"
OUT_DIR="${OUT_DIR:-$KERNEL_DIR/out-oc}"
LOG_FILE="${LOG_FILE:-$OUT_DIR/build-oc.log}"


: "${BOT_TOKEN:?BOT_TOKEN not yet set}"
: "${CHAT_ID:?CHAT_ID not yet set}"

push_message() {
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
    local resp
    resp=$(curl -s --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 300 \
        -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" \
        -F chat_id="${CHAT_ID}" \
        -F document=@"$1" \
        --form-string caption="$2" \
        -F parse_mode="html") || { echo "[telegram] curl failed (exit $?)"; return 0; }
    echo "$resp" | grep -q '"ok":true' || echo "[telegram] sendDocument failed: $resp"
}

restore_stock() {
    echo "[oc] Restoring stock files..."
    git -C "$KERNEL_DIR" checkout -- "${OC_FILES[@]}" 2>/dev/null || true
    echo "[oc] Stock restored — tree clean."
}
trap restore_stock EXIT

# Info build
BRANCH="$(git -C "$KERNEL_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
LAST_COMMIT="$(git -C "$KERNEL_DIR" log --pretty=format:'%s' -1 2>/dev/null || echo -)"
CLANG_VER="$(clang --version 2>/dev/null | head -n1 || echo unknown)"
CORES="$(nproc --all)"

push_message "<b>🔨 Build OC Started</b>
<b>Variant:</b> <code>Overclock</code>
<b>Device:</b> <code>${DEVICE}</code>
<b>Defconfig:</b> <code>vendor/whyred-oc_defconfig</code>
<b>Patch:</b> <code>oc/oc.patch</code>
<b>Compiler:</b> <code>${CLANG_VER}</code>
<b>Cores:</b> <code>${CORES}</code>
<b>Branch:</b> <code>${BRANCH}</code>
<b>Last commit:</b> <code>${LAST_COMMIT}</code>"

# 1) Apply the patch if you haven't already
if git -C "$KERNEL_DIR" apply --check "$OC_PATCH" 2>/dev/null; then
    echo "[oc] Applying oc/oc.patch ..."
    git -C "$KERNEL_DIR" apply "$OC_PATCH"
else
    echo "[oc] oc/oc.patch already applied or cannot be applied — continue building."
fi

# 2) Build using OC variables
# OC_BUILD=1 → `push_message`/`push_document` in `build.sh` are silenced,
#              all notifications from this script (to avoid duplicates).
export OC_BUILD=1
export DEFCONFIG="${DEFCONFIG:-vendor/whyred-oc_defconfig}"
export KERNEL_NAME
export OUT_DIR

BUILD_START=$(date +%s)
mkdir -p "$OUT_DIR"

set +e
"$KERNEL_DIR/build.sh" 2>&1 | tee "$LOG_FILE"
BUILD_STATUS=${PIPESTATUS[0]}
set -e

BUILD_END=$(date +%s)
DIFF=$((BUILD_END - BUILD_START))
MIN=$((DIFF / 60)); SEC=$((DIFF % 60))

IMG="$OUT_DIR/arch/arm64/boot/Image.gz-dtb"
[ -f "$IMG" ] || IMG="$OUT_DIR/arch/arm64/boot/Image.gz"

# 3) Send the results
if [ "$BUILD_STATUS" -ne 0 ] || [ ! -f "$IMG" ]; then
    ERR_TAIL="$(tail -n 25 "$LOG_FILE" 2>/dev/null | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
    push_message "<b>❌ Build OC Failed</b>
<b>Device:</b> <code>${DEVICE}</code>
<b>Duration:</b> <code>${MIN}m ${SEC}s</code>
<b>Status:</b> <code>${BUILD_STATUS}</code>

<code>${ERR_TAIL}</code>"
    exit 1
fi

ZIP="$(ls -t "$KERNEL_DIR"/"${KERNEL_NAME}"-*.zip 2>/dev/null | head -n1)"
if [ -n "${ZIP:-}" ] && [ -f "$ZIP" ]; then
    MD5="$(md5sum "$ZIP" | cut -d' ' -f1)"
    push_document "$ZIP" "<b> Build OC Success</b>
<b>Device:</b> <code>${DEVICE}</code>
<b>Variant:</b> <code>Overclock</code>
<b>Defconfig:</b> <code>vendor/whyred-oc_defconfig</code>
<b>MD5:</b> <code>${MD5}</code>
<b>Duration:</b> <code>${MIN}m ${SEC}s</code>"
    echo "Done: $(basename "$ZIP") (md5: $MD5)"
else
    push_message "<b> Build OC Success</b>
<b>Device:</b> <code>${DEVICE}</code>
<b>Duration:</b> <code>${MIN}m ${SEC}s</code>
 Zip not found — check manually <code>$OUT_DIR</code>."
fi

exit 0