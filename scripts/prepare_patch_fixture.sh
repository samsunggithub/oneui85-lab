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

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DOWNLOAD_SOURCE=false
FORCE=false
FIXTURE_DIR=""

PRINT_USAGE()
{
    cat <<EOF
Usage: scripts/prepare_patch_fixture.sh [options]

Creates a minimal source-only r12s patch fixture from an extracted firmware tree.

Options:
  --download              Download and extract the configured source firmware first.
  --force                 Replace an existing fixture directory.
  --output <directory>   Override the fixture output directory.
  -h, --help             Show this help text.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --download)
            DOWNLOAD_SOURCE=true
            ;;
        --force)
            FORCE=true
            ;;
        --output)
            shift
            [ -n "${1:-}" ] || { echo "Missing --output value" >&2; exit 1; }
            FIXTURE_DIR="$1"
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

# Reuse the production d2xks feature contract. No target firmware is read here.
# shellcheck disable=SC1091
source "$SRC_DIR/buildenv.sh" d2xks >/dev/null

SOURCE_FIRMWARE_PATH="$(cut -d "/" -f 1 <<< "$SOURCE_FIRMWARE")_$(cut -d "/" -f 2 <<< "$SOURCE_FIRMWARE")"
SOURCE_DIR="$FW_DIR/$SOURCE_FIRMWARE_PATH"
FIXTURE_DIR="${FIXTURE_DIR:-$OUT_DIR/patch-fixtures/$SOURCE_FIRMWARE_PATH}"
FIXTURE_SOURCE_DIR="$FIXTURE_DIR/source"

if $DOWNLOAD_SOURCE; then
    "$SRC_DIR/scripts/download_fw.sh" --ignore-target
    "$SRC_DIR/scripts/extract_fw.sh" --ignore-target
fi

if [ ! -d "$SOURCE_DIR" ]; then
    echo "Source firmware is not extracted: $SOURCE_DIR" >&2
    echo "Run this script with --download, or extract the configured source firmware first." >&2
    exit 1
fi

if [ -e "$FIXTURE_DIR" ]; then
    if $FORCE; then
        rm -rf "$FIXTURE_DIR"
    else
        echo "Fixture already exists: $FIXTURE_DIR" >&2
        echo "Use --force to replace it." >&2
        exit 1
    fi
fi

FIND_SOURCE_FILE()
{
    local RELATIVE_PATH="$1"
    local BASE

    for BASE in "$SOURCE_DIR" "$SOURCE_DIR/prism" "$SOURCE_DIR/optics"; do
        if [ -f "$BASE/$RELATIVE_PATH" ]; then
            printf '%s' "$BASE/$RELATIVE_PATH"
            return 0
        fi
    done

    find -L "$SOURCE_DIR/prism" "$SOURCE_DIR/optics" -type f -path "*/$RELATIVE_PATH" -print -quit 2> /dev/null
}

COPY_REQUIRED()
{
    local RELATIVE_PATH="$1"
    local SOURCE_PATH

    SOURCE_PATH="$(FIND_SOURCE_FILE "$RELATIVE_PATH")"
    if [ ! -f "$SOURCE_PATH" ]; then
        echo "Required r12s patch input is missing: $RELATIVE_PATH" >&2
        exit 1
    fi

    mkdir -p "$FIXTURE_SOURCE_DIR/$(dirname "$RELATIVE_PATH")"
    cp -a "$SOURCE_PATH" "$FIXTURE_SOURCE_DIR/$RELATIVE_PATH"
}

COPY_OPTIONAL()
{
    local RELATIVE_PATH="$1"
    local SOURCE_PATH

    SOURCE_PATH="$(FIND_SOURCE_FILE "$RELATIVE_PATH")"
    [ -f "$SOURCE_PATH" ] || return 0
    mkdir -p "$FIXTURE_SOURCE_DIR/$(dirname "$RELATIVE_PATH")"
    cp -a "$SOURCE_PATH" "$FIXTURE_SOURCE_DIR/$RELATIVE_PATH"
}

COPY_REQUIRED_ONE_OF()
{
    local RELATIVE_PATH

    for RELATIVE_PATH in "$@"; do
        if [ -f "$(FIND_SOURCE_FILE "$RELATIVE_PATH")" ]; then
            COPY_REQUIRED "$RELATIVE_PATH"
            return 0
        fi
    done

    echo "None of the required r12s patch inputs exists: $*" >&2
    exit 1
}

mkdir -p "$FIXTURE_SOURCE_DIR"

# Identity, framework decoding and source-contract inputs.
COPY_REQUIRED "system/system/build.prop"
COPY_OPTIONAL "vendor/build.prop"
COPY_OPTIONAL "product/etc/build.prop"
COPY_OPTIONAL "odm/etc/build.prop"
COPY_REQUIRED_ONE_OF \
    "system/system/system_ext/apex/com.android.vndk.v$SOURCE_VNDK_VERSION.apex" \
    "system_ext/apex/com.android.vndk.v$SOURCE_VNDK_VERSION.apex"
COPY_REQUIRED "system/system/etc/floating_feature.xml"
COPY_REQUIRED "system/system/framework/framework-res.apk"

# API and Smali/resource inputs used by product_feature, DVFS and RRO source-facing patches.
COPY_REQUIRED "system/system/framework/framework.jar"
COPY_REQUIRED "system/system/framework/services.jar"
COPY_REQUIRED "system/system/framework/ssrm.jar"
COPY_REQUIRED "system/system/framework/gamemanager.jar"
COPY_REQUIRED "system/system/framework/secinputdev-service.jar"
COPY_REQUIRED "system/system/framework/semwifi-service.jar"
COPY_REQUIRED "system/system/priv-app/BiometricSetting/BiometricSetting.apk"
COPY_REQUIRED "system/system/priv-app/SamsungDeviceHealthManagerService/SamsungDeviceHealthManagerService.apk"
COPY_REQUIRED "system/system/priv-app/SecSettings/SecSettings.apk"
COPY_REQUIRED "system/system/priv-app/SettingsProvider/SettingsProvider.apk"
COPY_REQUIRED "system/system/system_ext/priv-app/SystemUI/SystemUI.apk"

# Static Smali targets not covered by the first fixture revision. Keep the
# originals so all affected modules can be applied and rebuilt locally in one
# continuous pass after a single source-firmware extraction.
COPY_REQUIRED_ONE_OF \
    "system/system/app/DAAgent/DAAgent.apk" \
    "system/system/priv-app/DAAgent/DAAgent.apk"
COPY_REQUIRED_ONE_OF \
    "system/system/app/MotionPhoto/MotionPhoto.apk" \
    "system/system/priv-app/MotionPhoto/MotionPhoto.apk"
COPY_REQUIRED "system/system/framework/knoxsdk.jar"
COPY_REQUIRED "system/system/framework/samsungkeystoreutils.jar"
COPY_REQUIRED "system/system/priv-app/SecSettingsIntelligence/SecSettingsIntelligence.apk"
COPY_REQUIRED "system/system/system_ext/priv-app/StorageManager/StorageManager.apk"

# These files select conditional patch paths. Their absence is significant, so retain
# an existing file but do not fabricate one when the stock source does not provide it.
COPY_OPTIONAL "system/system/etc/permissions/com.sec.feature.cover.xml"
COPY_OPTIONAL "vendor/etc/permissions/android.hardware.strongbox_keystore.xml"

SYSTEM_BUILD_PROP="$(FIND_SOURCE_FILE "system/system/build.prop")"
SYSTEM_NAME="$(sed -n 's/^ro.product.system.name=//p' "$SYSTEM_BUILD_PROP" | head -n 1)"
[ -n "$SYSTEM_NAME" ] || { echo "ro.product.system.name is missing from source build.prop" >&2; exit 1; }
COPY_REQUIRED "product/overlay/framework-res__${SYSTEM_NAME}__auto_generated_rro_product.apk"

{
    echo "FIXTURE_REVISION=v2"
    echo "FIXTURE_STATIC_SMALI_TARGETS=true"
    echo "SOURCE_CODENAME=$SOURCE_CODENAME"
    echo "SOURCE_FIRMWARE=$SOURCE_FIRMWARE"
    echo "SOURCE_FIRMWARE_PATH=$SOURCE_FIRMWARE_PATH"
    echo "SOURCE_API_LEVEL=$SOURCE_API_LEVEL"
    echo "SOURCE_PRODUCT_FIRST_API_LEVEL=$SOURCE_PRODUCT_FIRST_API_LEVEL"
    echo "SOURCE_VNDK_VERSION=$SOURCE_VNDK_VERSION"
    echo "TARGET_CODENAME=$TARGET_CODENAME"
    echo "SYSTEM_NAME=$SYSTEM_NAME"
} > "$FIXTURE_DIR/fixture.properties"

(
    cd "$FIXTURE_SOURCE_DIR"
    find . -type f -print0 | sort -z | xargs -0 sha256sum
) > "$FIXTURE_DIR/manifest.sha256"

echo "Created r12s patch fixture: $FIXTURE_DIR"
echo "Fixture files: $(wc -l < "$FIXTURE_DIR/manifest.sha256")"

unset -f FIND_SOURCE_FILE COPY_REQUIRED COPY_OPTIONAL COPY_REQUIRED_ONE_OF
unset SYSTEM_BUILD_PROP
