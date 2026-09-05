#!/usr/bin/env bash
#
# Copyright (C) 2026
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_CODENAME="${1:-d2xks}"

source "$SRC_DIR/buildenv.sh" "$TARGET_CODENAME" >/dev/null

FAILURES=0
WARNINGS=0

FAIL()
{
    echo "! $*" >&2
    FAILURES=$((FAILURES + 1))
}

WARN()
{
    echo "! $*" >&2
    WARNINGS=$((WARNINGS + 1))
}

CHECK_SOURCE()
{
    local SOURCE_NAME="$1"
    local PARTITION="$2"
    local RELATIVE_PATH="$3"
    local SOURCE_DIR="$SRC_DIR/prebuilts/samsung/$SOURCE_NAME"
    local SOURCE_RELATIVE_PATH="$RELATIVE_PATH"

    # Match ADD_TO_WORK_DIR: prebuilts with a single system tree store
    # system/system/* build paths as system/* on disk.
    if [ "$PARTITION" = "system" ] && [ ! -d "$SOURCE_DIR/system/system" ]; then
        SOURCE_RELATIVE_PATH="${SOURCE_RELATIVE_PATH#system/}"
    fi
    local SOURCE_PATH="$SOURCE_DIR/$PARTITION/$SOURCE_RELATIVE_PATH"

    if [ ! -d "$SOURCE_DIR" ]; then
        FAIL "Missing prebuilt source: prebuilts/samsung/$SOURCE_NAME"
        return
    fi
    if [ ! -f "$SOURCE_DIR/.current" ]; then
        FAIL "Missing firmware lock: prebuilts/samsung/$SOURCE_NAME/.current"
    elif grep -qE '^(BOMB|$)' "$SOURCE_DIR/.current"; then
        FAIL "Invalid firmware lock: prebuilts/samsung/$SOURCE_NAME/.current"
    fi

    if [ ! -e "$SOURCE_PATH" ] && [ ! -e "$SOURCE_PATH.00" ]; then
        FAIL "Missing prebuilt resource: $SOURCE_NAME/$PARTITION/$RELATIVE_PATH"
    fi

    if [ ! -f "$SOURCE_DIR/fs_config-$PARTITION" ] || [ ! -f "$SOURCE_DIR/file_context-$PARTITION" ]; then
        FAIL "Missing $PARTITION metadata in prebuilt source: $SOURCE_NAME"
    fi
}

CHECK_SOURCE "b0sxxx" "system" "system/apex/com.android.bt.apex"

# r9sxxx has a placeholder lock. These paths are intentionally sourced from
# the version-locked p3sxxx tree, matching the current Exynos 9825 strategy.
CHECK_SOURCE "p3sxxx" "system" "system/lib64/libeden_wrapper_system.so"
CHECK_SOURCE "p3sxxx" "system" "system/lib64/libsnap_aidl.snap.samsung.so"
CHECK_SOURCE "p3sxxx" "system" "system/lib64/libSwIsp_core.camera.samsung.so"
CHECK_SOURCE "p3sxxx" "system" "system/lib64/libSwIsp_wrapper_v1.camera.samsung.so"
CHECK_SOURCE "p3sxxx" "system" "system/priv-app/SingleTakeService/SingleTakeService.apk"
CHECK_SOURCE "p3sxxx" "system" "system/cameradata/singletake/service-feature.xml"
CHECK_SOURCE "p3sxxx" "system" "system/bin/remotedisplay"
CHECK_SOURCE "p3sxxx" "system" "system/lib"
CHECK_SOURCE "p3sxxx" "vendor" "saiv/swisp_1.0"
CHECK_SOURCE "p3sxxx" "vendor" "bin/hw/vendor.samsung.hardware.light-service"
CHECK_SOURCE "p3sxxx" "vendor" "lib64/android.hardware.light-V1-ndk_platform.so"
CHECK_SOURCE "p3sxxx" "vendor" "lib64/vendor.samsung.hardware.light-V1-ndk_platform.so"

CHECK_SOURCE "a26xxx" "system" "system/etc/public.libraries-polarr.txt"
CHECK_SOURCE "a26xxx" "system" "system/lib64/libBestComposition.polarr.so"
CHECK_SOURCE "a26xxx" "system" "system/lib64/libFeature.polarr.so"
CHECK_SOURCE "a26xxx" "system" "system/lib64/libTracking.polarr.so"

if $SOURCE_HAS_MASS_CAMERA_APP && ! $TARGET_HAS_MASS_CAMERA_APP; then
    CHECK_SOURCE "e2sxxx" "system" "system/priv-app/SamsungCamera/SamsungCamera.apk"
    CHECK_SOURCE "e2sxxx" "system" "system/priv-app/SamsungCamera/oat"
fi

if [[ "$SOURCE_VNDK_VERSION" != "$TARGET_VNDK_VERSION" ]]; then
    CHECK_SOURCE "r11sxxx" "system_ext" "apex/com.android.vndk.v$TARGET_VNDK_VERSION.apex"
fi

# b0sxxx remains a deliberate special case for the Bluetooth APEX. It is not
# in the automatic updater matrix, so surface that provenance rather than
# treating it as an implicit r12s source dependency.
WARN "b0sxxx Bluetooth APEX is a deliberate version-locked special source; validate its byte anchor before changing its firmware origin"

echo "prebuilt_contract_target=$TARGET_CODENAME"
echo "prebuilt_contract_source=$SOURCE_CODENAME"
echo "prebuilt_contract_failures=$FAILURES"
echo "prebuilt_contract_warnings=$WARNINGS"

[ "$FAILURES" -eq 0 ]
