#!/bin/sh
# Auto-APN hotplug: detect SIM operator, set correct APN, reconnect
# Trigger: runs on wwan interface events
# Uses flat file + awk lookup

MAPFILE="/etc/mcc-mnc-apn.txt"
MODEM_INDEX=0
FALLBACK="internet"

get_mccmnc() {
    OPID=$(mmcli -m "$MODEM_INDEX" 2>/dev/null | grep "operator id" | awk '{print $NF}')
    if [ -n "$OPID" ]; then
        echo "$OPID"
        return 0
    fi
    IMSI=$(mmcli -m "$MODEM_INDEX" 2>/dev/null | grep "imsi" | grep -oE '[0-9]{6,15}' | head -1)
    if [ -n "$IMSI" ]; then
        echo "${IMSI:0:5}"
        return 0
    fi
    return 1
}

update_apn() {
    local MCCMNC="$1"

    if [ -z "$MCCMNC" ]; then
        logger -t auto-apn "Could not detect MCC-MNC"
        return 1
    fi

    logger -t auto-apn "MCC-MNC: $MCCMNC"

    # Lookup from flat file
    if [ -f "$MAPFILE" ]; then
        APN=$(awk -v mcc="$MCCMNC" '$1==mcc {print $2; exit}' "$MAPFILE")
    fi

    [ -z "$APN" ] && APN="$FALLBACK"
    logger -t auto-apn "APN: $APN"

    CURRENT=$(uci get network.wwan.apn 2>/dev/null)
    if [ "$CURRENT" != "$APN" ]; then
        uci set network.wwan.apn="$APN"
        uci commit network
        logger -t auto-apn "APN changed: $CURRENT -> $APN"
        return 0
    else
        logger -t auto-apn "APN unchanged: $APN"
        return 2
    fi
}

case "$ACTION" in
    ifup|add)
        MCCMNC=$(get_mccmnc)
        if update_apn "$MCCMNC"; then
            logger -t auto-apn "APN updated for interface"
        fi
        ;;
    *)
        MCCMNC=$(get_mccmnc)
        echo "MCC-MNC: $MCCMNC"
        update_apn "$MCCMNC"
        ;;
esac
