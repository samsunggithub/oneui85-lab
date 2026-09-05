#!/usr/bin/env bash
#
# Copyright (C) 2026
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#

set -eE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_DIR=""
OUTPUT_DIR=""
KEEP_WORK_DIR=false
FIXTURE_STATIC_SMALI_TARGETS=false

PRINT_USAGE()
{
    cat <<EOF
Usage: scripts/test_patch_fixture.sh --fixture <directory> [options]

Applies source-facing r12s patches to a minimal fixture using the d2xks
configuration contract, then rebuilds every decoded APK/JAR. This does not
extract target firmware, create partition images, or create a ROM ZIP.

Options:
  --fixture <directory>  Fixture created by prepare_patch_fixture.sh.
  --output <directory>   Override the transient test output directory.
  --keep-work-dir        Keep the result directory after a successful test.
  -h, --help             Show this help text.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --fixture)
            shift
            [ -n "${1:-}" ] || { echo "Missing --fixture value" >&2; exit 1; }
            FIXTURE_DIR="$1"
            ;;
        --output)
            shift
            [ -n "${1:-}" ] || { echo "Missing --output value" >&2; exit 1; }
            OUTPUT_DIR="$1"
            ;;
        --keep-work-dir)
            KEEP_WORK_DIR=true
            ;;
        -h|--help)
            PRINT_USAGE
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            PRINT_USAGE >&2
            exit 1
            ;;
    esac
    shift
done

[ -n "$FIXTURE_DIR" ] || { echo "--fixture is required" >&2; exit 1; }
[ -d "$FIXTURE_DIR" ] || { echo "Fixture directory not found: $FIXTURE_DIR" >&2; exit 1; }
FIXTURE_DIR="$(cd "$FIXTURE_DIR" && pwd)"
[ -f "$FIXTURE_DIR/fixture.properties" ] || { echo "Missing fixture.properties: $FIXTURE_DIR" >&2; exit 1; }
[ -d "$FIXTURE_DIR/source" ] || { echo "Missing fixture source tree: $FIXTURE_DIR/source" >&2; exit 1; }
if grep -qx "FIXTURE_STATIC_SMALI_TARGETS=true" "$FIXTURE_DIR/fixture.properties"; then
    FIXTURE_STATIC_SMALI_TARGETS=true
fi

# Reuse the exact generated configuration that a complete d2xks build consumes.
# shellcheck disable=SC1091
source "$SRC_DIR/buildenv.sh" d2xks >/dev/null
"$SRC_DIR/scripts/check_prebuilt_contract.sh" "$TARGET_CODENAME"

SOURCE_FIRMWARE_PATH="$(cut -d "/" -f 1 <<< "$SOURCE_FIRMWARE")_$(cut -d "/" -f 2 <<< "$SOURCE_FIRMWARE")"
FIXTURE_SOURCE_DIR="$FIXTURE_DIR/source"
OUTPUT_DIR="${OUTPUT_DIR:-$OUT_DIR/patch-test/$TARGET_CODENAME}"

if [ -e "$OUTPUT_DIR" ]; then
    rm -rf "$OUTPUT_DIR"
fi

export FW_DIR="$OUTPUT_DIR/fw"
export WORK_DIR="$OUTPUT_DIR/work_dir"
export APKTOOL_DIR="$OUTPUT_DIR/apktool"
export PATCH_TEST_MODE=true
# r12s includes an unmodified framework classes3.dex that the current smali
# toolchain cannot round-trip at the 16-bit method-reference boundary. Preserve
# byte-identical Dex files only in this fixture; production builds retain the
# repository's normal apktool behavior.
export PATCH_TEST_SKIP_UNCHANGED_DEX=true
REPORT_DIR="$OUTPUT_DIR/report"
TEST_SOURCE_DIR="$FW_DIR/$SOURCE_FIRMWARE_PATH"

mkdir -p "$FW_DIR" "$WORK_DIR" "$REPORT_DIR"
cp -a "$FIXTURE_SOURCE_DIR" "$TEST_SOURCE_DIR"

# The source OTA stores system and product in prism, and vendor and odm in
# optics. Recreate that layout only in the transient fixture copy so source
# contract modules exercise their production paths without duplicating files.
mkdir -p "$TEST_SOURCE_DIR/prism" "$TEST_SOURCE_DIR/optics"
ln -s ../system "$TEST_SOURCE_DIR/prism/system"
ln -s ../product "$TEST_SOURCE_DIR/prism/product"
ln -s ../vendor "$TEST_SOURCE_DIR/optics/vendor"
ln -s ../odm "$TEST_SOURCE_DIR/optics/odm"

rsync -a "$FIXTURE_SOURCE_DIR/" "$WORK_DIR/"

# Keep a pre-mutation checksum record. The source fixture itself remains immutable.
(
    cd "$WORK_DIR"
    find . -type f -print0 | sort -z | xargs -0 sha256sum
) > "$REPORT_DIR/work-dir.before.sha256"

# module_utils supplies exactly the same DECODE_APK, APPLY_PATCH, property and
# floating-feature helpers used by scripts/internal/apply_modules.sh.
# shellcheck disable=SC1091
source "$SRC_DIR/scripts/utils/module_utils.sh"

REPORT_FAILURE()
{
    local STATUS="$1"
    local SECSETTINGS_DIR="$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk"
    local SYSTEMUI_LSRUNE="$APKTOOL_DIR/system_ext/priv-app/SystemUI/SystemUI.apk/smali/com/android/systemui/LsRune.smali"
    local SMALI_FILE

    trap - ERR
    set +e
    mkdir -p "$REPORT_DIR/smali"

    {
        echo "status=$STATUS"
        echo "failed_after_module=${MODPATH:-unknown}"
        echo
        echo "[decoded-targets]"
        find "$APKTOOL_DIR" -type d \( -name "*.apk" -o -name "*.jar" \) 2>/dev/null | sort
        echo
        echo "[secsettings-fingerprint-biometric-candidates]"
        if [ -d "$SECSETTINGS_DIR" ]; then
            find "$SECSETTINGS_DIR" -type f \( -iname "*fingerprint*.smali" -o -iname "*biometric*.smali" \) | sort
        fi
        echo
        echo "[source-fingerprint-config-occurrences]"
        grep -RIlF --include="*.smali" "$SOURCE_FP_SENSOR_CONFIG" "$APKTOOL_DIR" 2>/dev/null | sort
        echo
        echo "[secsettings-display-candidates]"
        if [ -d "$SECSETTINGS_DIR" ]; then
            find "$SECSETTINGS_DIR" -type f -iname "*display*.smali" | sort
        fi
        echo
        echo "[systemui-lsrune]"
        printf '%s\n' "$SYSTEMUI_LSRUNE"
    } > "$REPORT_DIR/failure.txt"

    if [ -d "$SECSETTINGS_DIR" ]; then
        while IFS= read -r SMALI_FILE; do
            REPORT_FILE="$REPORT_DIR/smali/${SMALI_FILE#$APKTOOL_DIR/}"
            mkdir -p "$(dirname "$REPORT_FILE")"
            cp -a "$SMALI_FILE" "$REPORT_FILE"
        done < <(find "$SECSETTINGS_DIR" -type f \( -iname "*fingerprint*.smali" -o -iname "*biometric*.smali" \) | sort)
    fi

    if [ -d "$SECSETTINGS_DIR" ]; then
        while IFS= read -r SMALI_FILE; do
            REPORT_FILE="$REPORT_DIR/smali/${SMALI_FILE#$APKTOOL_DIR/}"
            mkdir -p "$(dirname "$REPORT_FILE")"
            cp -a "$SMALI_FILE" "$REPORT_FILE"
        done < <(find "$SECSETTINGS_DIR" -type f -iname "*display*.smali" | sort)
    fi

    if [ -f "$SYSTEMUI_LSRUNE" ]; then
        REPORT_FILE="$REPORT_DIR/smali/${SYSTEMUI_LSRUNE#$APKTOOL_DIR/}"
        mkdir -p "$(dirname "$REPORT_FILE")"
        cp -a "$SYSTEMUI_LSRUNE" "$REPORT_FILE"
    fi

    exit "$STATUS"
}

trap 'REPORT_FAILURE $?' ERR

RUN_SOURCE_MODULE()
{
    MODPATH="$1"
    [ -f "$MODPATH/customize.sh" ] || { echo "Missing customize.sh: $MODPATH" >&2; return 1; }
    echo "==> Testing ${MODPATH#$SRC_DIR/}"
    # shellcheck disable=SC1090
    source "$MODPATH/customize.sh"
}

APPLY_STATIC_SMALI_PATCHES()
{
    local PATCHES_PATH="$1"
    local TARGET="$2"
    local PARTITION="$(cut -d "/" -f 1 <<< "$TARGET")"
    local FILE="$TARGET"
    local PATCH

    if [ "$PARTITION" != "system" ]; then
        FILE="$(cut -d "/" -f 2- <<< "$FILE")"
    fi

    while IFS= read -r PATCH; do
        APPLY_PATCH "$PARTITION" "$FILE" "$PATCH"
    done < <(find "$PATCHES_PATH/$TARGET" -type f -name "*.patch" | sort -n)
}

APPLY_MODULE_STATIC_SMALI()
{
    local MODPATH="$1"
    local TARGET

    [ -d "$MODPATH/smali" ] || return 0
    while IFS= read -r TARGET; do
        TARGET="${TARGET#$MODPATH/smali/}"
        APPLY_STATIC_SMALI_PATCHES "$MODPATH/smali" "$TARGET"
    done < <(find "$MODPATH/smali" -type d \( -name "*.apk" -o -name "*.jar" \) | sort)
}

RUN_ORDERED_APK_JAR_MODULES()
{
    local MODPATH

    # This is the APK/JAR-affecting subset of make_rom.sh's production order:
    # ROM patches, Exynos 9825 platform patches, then ROM mods. Modules which
    # only add target-firmware blobs are separately covered by the full build;
    # this fixture verifies every source r12s APK/JAR decode, Smali path and
    # recompile operation before another remote ROM build is requested.
    for MODPATH in \
        "$SRC_DIR/unica/patches/dvfs" \
        "$SRC_DIR/unica/patches/miscs" \
        "$SRC_DIR/unica/patches/product_feature" \
        "$SRC_DIR/unica/patches/rro" \
        "$SRC_DIR/unica/patches/signature" \
        "$SRC_DIR/platform/exynos9825/patches/camera" \
        "$SRC_DIR/platform/exynos9825/patches/extradim" \
        "$SRC_DIR/unica/mods/applock" \
        "$SRC_DIR/unica/mods/csc" \
        "$SRC_DIR/unica/mods/daagent" \
        "$SRC_DIR/unica/mods/deknox" \
        "$SRC_DIR/unica/mods/hma" \
        "$SRC_DIR/unica/mods/keybox" \
        "$SRC_DIR/unica/mods/knoxpatch" \
        "$SRC_DIR/unica/mods/settings"; do
        [ -d "$MODPATH" ] || continue
        [ -f "$MODPATH/disable" ] && continue
        case "$MODPATH" in
            "$SRC_DIR/unica/patches/dvfs"|\
            "$SRC_DIR/unica/patches/product_feature"|\
            "$SRC_DIR/unica/patches/rro"|\
            "$SRC_DIR/unica/patches/signature"|\
            "$SRC_DIR/unica/mods/csc"|\
            "$SRC_DIR/unica/mods/settings")
                RUN_SOURCE_MODULE "$MODPATH"
                ;;
        esac
        APPLY_MODULE_STATIC_SMALI "$MODPATH"
    done
}

APPLY_STATIC_RESOURCE_FIXTURES()
{
    local SETTINGS_OVERLAY="$SRC_DIR/unica/mods/settings/SecSettings.apk"
    local SECSETTINGS_APKTOOL_DIR="$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk"

    if [ -d "$SETTINGS_OVERLAY" ] && [ -d "$SECSETTINGS_APKTOOL_DIR" ]; then
        echo "==> Applying static resource fixtures"
        cp -fa "$SETTINGS_OVERLAY/"* "$SECSETTINGS_APKTOOL_DIR"
        [ -f "$SECSETTINGS_APKTOOL_DIR/res/drawable/logo.png" ]
    fi
}

TEST_PLATFORM_BLUETOOTH_PATCH()
{
    local MODPATH="$SRC_DIR/platform/exynos9825/patches/miscs"
    local WORK_DIR="$OUTPUT_DIR/bluetooth-work-dir"
    local TMP_DIR="$OUTPUT_DIR/bluetooth-tmp"
    local B0S_PREBUILT="$SRC_DIR/prebuilts/samsung/b0sxxx"
    local JNI_PATH="$WORK_DIR/system/system/lib64/libbluetooth_jni.so"

    echo "==> Testing platform/exynos9825/patches/miscs Bluetooth library patch"

    rm -rf "$WORK_DIR" "$TMP_DIR"
    mkdir -p "$WORK_DIR/configs"
    cp -a "$B0S_PREBUILT/fs_config-system" "$WORK_DIR/configs/fs_config-system"
    cp -a "$B0S_PREBUILT/file_context-system" "$WORK_DIR/configs/file_context-system"

    ADD_TO_WORK_DIR "b0sxxx" "system" "system/apex/com.android.bt.apex" 0 0 644 "u:object_r:system_file:s0"

    # shellcheck disable=SC1091
    source "$MODPATH/bluetooth.sh"
    PATCH_BLUETOOTH_JNI

    [ -f "$JNI_PATH" ] || { echo "Bluetooth JNI library was not extracted" >&2; return 1; }
    xxd -p "$JNI_PATH" | tr -d "\n" | grep -q "289765392a00001436008052"
    ! xxd -p "$JNI_PATH" | tr -d "\n" | grep -q "289765394805003736008052"
    grep -q '^system/lib64/libbluetooth_jni.so 0 0 644 capabilities=0x0$' "$WORK_DIR/configs/fs_config-system"
    grep -qF '/system/lib64/libbluetooth_jni\.so u:object_r:system_lib_file:s0' "$WORK_DIR/configs/file_context-system"

    {
        echo "apex_sha256=$(sha256sum "$WORK_DIR/system/system/apex/com.android.bt.apex" | cut -d " " -f 1)"
        echo "jni_sha256=$(sha256sum "$JNI_PATH" | cut -d " " -f 1)"
        echo "old_anchor=absent"
        echo "new_anchor=present"
    } > "$REPORT_DIR/bluetooth-patch.properties"
}

# The complete r12s fixture contains every source APK/JAR targeted by the
# enabled patch and mod modules. Replay their production order before compiling
# every decoded target. No source-contract module is present or executed.
if ! $FIXTURE_STATIC_SMALI_TARGETS; then
    echo "Fixture must provide static Smali targets for complete r12s validation" >&2
    exit 1
fi
RUN_ORDERED_APK_JAR_MODULES
TEST_PLATFORM_BLUETOOTH_PATCH

if [ -d "$APKTOOL_DIR" ]; then
    while IFS= read -r f; do
        RELATIVE_PATH="${f#$APKTOOL_DIR/}"
        PARTITION="$(cut -d "/" -f 1 <<< "$RELATIVE_PATH")"
        if [ "$PARTITION" = "system" ]; then
            "$SRC_DIR/scripts/apktool.sh" b system "$RELATIVE_PATH"
        else
            "$SRC_DIR/scripts/apktool.sh" b "$PARTITION" "$(cut -d "/" -f 2- <<< "$RELATIVE_PATH")"
        fi
    done < <(find "$APKTOOL_DIR" -type d \( -name "*.apk" -o -name "*.jar" \) | sort)
fi

(
    cd "$WORK_DIR"
    find . -type f -print0 | sort -z | xargs -0 sha256sum
) > "$REPORT_DIR/work-dir.after.sha256"

diff -u "$REPORT_DIR/work-dir.before.sha256" "$REPORT_DIR/work-dir.after.sha256" > "$REPORT_DIR/work-dir.sha256.diff" || true

{
    echo "target=$TARGET_CODENAME"
    echo "source=$SOURCE_FIRMWARE"
    echo "fixture=$FIXTURE_DIR"
    echo "source_api=$SOURCE_API_LEVEL"
    echo "source_first_api=$SOURCE_PRODUCT_FIRST_API_LEVEL"
    echo "source_vndk=$SOURCE_VNDK_VERSION"
    echo "source_fingerprint=$SOURCE_FP_SENSOR_CONFIG"
    echo "target_fingerprint=$TARGET_FP_SENSOR_CONFIG"
    echo "source_hfr=$SOURCE_HFR_MODE/$SOURCE_HFR_SUPPORTED_REFRESH_RATE/$SOURCE_HFR_DEFAULT_REFRESH_RATE"
    echo "target_hfr=$TARGET_HFR_MODE/$TARGET_HFR_SUPPORTED_REFRESH_RATE/$TARGET_HFR_DEFAULT_REFRESH_RATE"
    echo "source_dvfs=$SOURCE_DVFS_CONFIG_NAME"
    echo "target_dvfs=$TARGET_DVFS_CONFIG_NAME"
    echo "fixture_static_smali_targets=$FIXTURE_STATIC_SMALI_TARGETS"
    echo "decoded_targets=$(find "$APKTOOL_DIR" -type d \( -name "*.apk" -o -name "*.jar" \) | wc -l)"
} > "$REPORT_DIR/test.properties"

printf 'r12s_patch_fixture_test=passed\n'

if ! $KEEP_WORK_DIR; then
    # The workflow uploads this directory before cleanup. Local callers can pass
    # --keep-work-dir to inspect decoded Smali and rebuilt files directly.
    rm -rf "$OUTPUT_DIR"
fi
