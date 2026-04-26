#!/usr/bin/env bash
# setup-dw5821e-modem.sh — One-shot DW5821e modem setup on OpenWrt
# Usage: ./setup-dw5821e-modem.sh [router_ip] [--force]
#   router_ip: default 192.168.1.1
#   --force:   skip reboot safety check, re-run all steps
#
# Prerequisites: SSH key already on router (add via LuCI or ssh-copy-id)
# Tested: OpenWrt SNAPSHOT (APK-based), squashfs-sysupgrade, GL-MT3600BE
# Modem:  Dell DW5821e / Foxconn T77W968 (413c:81d7)

set -euo pipefail

ROUTER="${1:-root@192.168.1.1}"
FORCE=false
[[ "${2:-}" == "--force" ]] && FORCE=true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*"; exit 1; }

# ── preflight ──────────────────────────────────────────────
log "Preflight checks..."

ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$ROUTER" "echo ok" &>/dev/null \
  || err "Cannot SSH to $ROUTER. Add your SSH key first."

# detect package manager
PKG=$(ssh "$ROUTER" "which apk 2>/dev/null && echo apk || echo opkg")
log "Package manager: $PKG"

# check if already set up
if ! $FORCE; then
  if ssh "$ROUTER" "mmcli -L 2>/dev/null | grep -q '/Modem/'" 2>/dev/null; then
    STATE=$(ssh "$ROUTER" "mmcli -m 0 2>/dev/null | grep 'state:' | awk '{print \$NF}'")
    if [[ "$STATE" == "connected" ]]; then
      warn "Modem already connected. Use --force to re-run."
      exit 0
    fi
  fi
fi

# ── step 1: install packages ───────────────────────────────
log "Step 1/5: Installing ModemManager..."

ssh "$ROUTER" "
  $PKG update
  $PKG add modemmanager luci-proto-modemmanager
"

# ── step 2: fix usb-mode.json ──────────────────────────────
log "Step 2/5: Fixing usb-mode.json (remove 413c:81d7 config:0)..."

ssh "$ROUTER" "
  if grep -q '\"413c:81d7\"' /etc/usb-mode.json; then
    sed -i '/\"413c:81d7\"/,/^\t\t},$/d' /etc/usb-mode.json
    echo '413c:81d7 removed from usb-mode.json'
  else
    echo '413c:81d7 already removed'
  fi
"

# ── step 3: switch modem to QMI mode ───────────────────────
log "Step 3/5: Switching modem to Config 1 (QMI)..."

ssh "$ROUTER" "
  CFG=\$(cat /sys/bus/usb/devices/2-1/bConfigurationValue 2>/dev/null)
  echo \"Current config: \$CFG\"

  if [ \"\$CFG\" != \"1\" ]; then
    echo 1 > /sys/bus/usb/devices/2-1/bConfigurationValue
    sleep 2
    echo \"Switched to config 1\"
  fi

  # Verify qmi_wwan bound → /dev/cdc-wdm0 exists
  if ! ls /dev/cdc-wdm0 &>/dev/null; then
    echo '2-1:1.0' > /sys/bus/usb/drivers/qmi_wwan/bind 2>/dev/null || true
    sleep 1
  fi

  ls -la /dev/cdc-wdm0 && echo 'QMI device ready' || echo 'WARNING: no cdc-wdm0'
"

# ── step 4: upload auto-APN files ──────────────────────────
log "Step 4/5: Uploading auto-APN files..."

for f in mcc-mnc-apn.txt auto-apn-init.sh 99-auto-apn-hotplug.sh; do
  if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
    err "Missing file: $SCRIPT_DIR/$f"
  fi
done

cat "$SCRIPT_DIR/mcc-mnc-apn.txt"          | ssh "$ROUTER" 'cat > /etc/mcc-mnc-apn.txt'
cat "$SCRIPT_DIR/auto-apn-init.sh"          | ssh "$ROUTER" 'cat > /etc/init.d/auto-apn'
cat "$SCRIPT_DIR/99-auto-apn-hotplug.sh"    | ssh "$ROUTER" 'cat > /etc/hotplug.d/iface/99-auto-apn'

ssh "$ROUTER" "
  chmod +x /etc/init.d/auto-apn
  chmod +x /etc/hotplug.d/iface/99-auto-apn
  /etc/init.d/auto-apn enable
"

log "  APN database: $(wc -l < "$SCRIPT_DIR/mcc-mnc-apn.txt") carriers"

# ── step 5: configure network + connect ────────────────────
log "Step 5/5: Configuring network and connecting..."

ssh "$ROUTER" "
  # Enable services
  /etc/init.d/dbus enable
  /etc/init.d/dbus start 2>/dev/null || true
  /etc/init.d/modemmanager enable
  /etc/init.d/modemmanager start 2>/dev/null || true
  sleep 2

  # Configure wwan interface
  uci set network.wwan=interface 2>/dev/null
  uci set network.wwan.proto='modemmanager'
  uci set network.wwan.device='/sys/devices/platform/soc/11200000.usb/usb2/2-1'
  uci set network.wwan.apn='internet'
  uci set network.wwan.metric='10'
  uci set network.wwan.iptype='ipv4'
  uci set network.wwan.peerdns='1'
  uci commit network

  # Restart network to trigger ModemManager connection via netifd
  /etc/init.d/network restart
  sleep 8
"

# ── verify ─────────────────────────────────────────────────
log "Verifying connection..."

STATUS=$(ssh "$ROUTER" "
  STATE=\$(mmcli -m 0 2>/dev/null | grep 'state:' | awk '{print \$NF}')
  OPERATOR=\$(mmcli -m 0 2>/dev/null | grep 'operator name:' | awk '{\$1=\$2=\"\"; print \$0}' | xargs)
  SIGNAL=\$(mmcli -m 0 2>/dev/null | grep 'signal quality:' | awk '{print \$NF}')
  TECH=\$(mmcli -m 0 2>/dev/null | grep 'access tech:' | awk '{print \$NF}')
  IP=\$(ip addr show wwan0 2>/dev/null | grep 'inet ' | awk '{print \$2}')
  echo \"\$STATE|\$OPERATOR|\$SIGNAL|\$TECH|\$IP\"
")

IFS='|' read -r STATE OPERATOR SIGNAL TECH IP <<< "$STATUS"

echo ""
echo "  ┌─────────────────────────────────────────┐"
printf  "  │  Modem:  DELL DW5821e (QMI mode)        │\n"
printf  "  │  State:  %-30s │\n" "$STATE"
printf  "  │  Net:    %-30s │\n" "$OPERATOR"
printf  "  │  Tech:   %-10s  Signal: %-12s │\n" "$TECH" "$SIGNAL"
printf  "  │  IP:     %-30s │\n" "$IP"
echo "  └─────────────────────────────────────────┘"
echo ""

if [[ "$STATE" == "connected" ]]; then
  log "Setup complete. Modem connected."
  # Test connectivity
  if ssh "$ROUTER" "ping -c 2 -I wwan0 8.8.8.8" &>/dev/null; then
    log "Internet reachable via LTE."
  else
    warn "Modem connected but internet unreachable. Check APN."
  fi
else
  warn "Modem state: $STATE. Run 'ssh $ROUTER mmcli -m 0' to debug."
  exit 1
fi
