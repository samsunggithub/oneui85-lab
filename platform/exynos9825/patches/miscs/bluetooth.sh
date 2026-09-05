#
# Copyright (C) 2026
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#

PATCH_BLUETOOTH_JNI()
{
    local APEX_PATH="$WORK_DIR/system/system/apex/com.android.bt.apex"
    local JNI_PATH="$WORK_DIR/system/system/lib64/libbluetooth_jni.so"
    local BT_TMP_DIR="$TMP_DIR/bt-lib-patch"

    if [ ! -f "$JNI_PATH" ]; then
        [ -f "$APEX_PATH" ] || { LOGE "Bluetooth APEX not found: ${APEX_PATH//$WORK_DIR/}"; return 1; }

        LOG_STEP_IN "- Extracting libbluetooth_jni.so from com.android.bt.apex"

        rm -rf "$BT_TMP_DIR"
        mkdir -p "$BT_TMP_DIR" "$(dirname "$JNI_PATH")"

        EVAL "unzip -p \"$APEX_PATH\" apex_payload.img > \"$BT_TMP_DIR/apex_payload.img\"" || return 1
        EVAL "debugfs -R \"dump -p /lib64/libbluetooth_jni.so $JNI_PATH\" \"$BT_TMP_DIR/apex_payload.img\"" || return 1

        rm -rf "$BT_TMP_DIR"
        SET_METADATA "system" "system/lib64/libbluetooth_jni.so" 0 0 644 "u:object_r:system_lib_file:s0" || return 1

        LOG_STEP_OUT
    fi

    # https://github.com/duhansysl/Bluetooth-Library-Patcher/blob/67e598ad142ed296b487a7a4585927c993d4f35d/hexpatcher.sh#L43
    HEX_PATCH "$JNI_PATH" \
        "289765394805003736008052" "289765392a00001436008052"
}
