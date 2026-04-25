#!/bin/sh /etc/rc.common
# Auto-APN boot-time init — detects SIM operator BEFORE network starts
# Uses flat file + awk for O(1*)/early-exit lookup

START=15
STOP=90

MAPFILE="/etc/mcc-mnc-apn.txt"
MODEM_INDEX=0
MAX_WAIT=30
FALLBACK="internet"

boot() {
    logger -t auto-apn-init "Starting APN detection at boot"

    # Wait for modem to appear in ModemManager
    waited=0
    while [ $waited -lt $MAX_WAIT ]; do
        if mmcli -L 2>/dev/null | grep -q "/Modem/"; then
            logger -t auto-apn-init "ModemManager ready after ${waited}s"
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if [ $waited -ge $MAX_WAIT ]; then
        logger -t auto-apn-init "Timeout waiting for modem"
        return 1
    fi

    # Get operator MCC-MNC
    OPID=$(mmcli -m "$MODEM_INDEX" 2>/dev/null | grep "operator id" | awk '{print $NF}')
    if [ -z "$OPID" ]; then
        IMSI=$(mmcli -m "$MODEM_INDEX" 2>/dev/null | grep "imsi" | grep -oE '[0-9]{6,15}' | head -1)
        [ -n "$IMSI" ] && OPID="${IMSI:0:5}"
    fi

    if [ -z "$OPID" ]; then
        logger -t auto-apn-init "Could not detect MCC-MNC"
        return 1
    fi

    logger -t auto-apn-init "Detected MCC-MNC: $OPID"

    # Lookup APN from flat file via awk
    if [ -f "$MAPFILE" ]; then
        APN=$(awk -v mcc="$OPID" '$1==mcc {print $2; exit}' "$MAPFILE")
    fi

    [ -z "$APN" ] && APN="$FALLBACK"
    logger -t auto-apn-init "APN lookup: $APN"

    CURRENT=$(uci get network.wwan.apn 2>/dev/null)
    if [ "$CURRENT" != "$APN" ]; then
        uci set network.wwan.apn="$APN"
        uci commit network
        logger -t auto-apn-init "APN updated: $CURRENT -> $APN"
    else
        logger -t auto-apn-init "APN unchanged: $APN"
    fi
}
