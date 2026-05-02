# OpenWrt Auto-APN

Automatic APN detection for OpenWrt LTE modems — works with any SIM, any carrier, globally.

When you insert a SIM (or reboot), the router automatically detects the carrier from the tower's MCC-MNC broadcast and sets the correct APN. No manual configuration needed.

## How It Works

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Tower       │────▶│  ModemManager│────▶│  Init/Hotplug│
│  broadcasts  │     │  reads MCC-  │     │  looks up    │
│  MCC-MNC     │     │  MNC code    │     │  APN via awk │
└──────────────┘     └──────────────┘     └──────┬───────┘
                                                 │
                                    ┌────────────▼───────┐
                                    │  UCI network.wwan   │
                                    │  APN set correctly  │
                                    └────────────────────┘
```

Two layers of redundancy:
1. **Init script** (`/etc/init.d/auto-apn`, START=15) — runs at boot before network starts
2. **Hotplug script** (`/etc/hotplug.d/iface/99-auto-apn`) — fires on wwan interface events (SIM hot-swap)

## Files

| File | Purpose |
|------|---------|
| `mcc-mnc-apn.txt` | 714 carriers, 12109 bytes flat file (MCCMNC→APN) |
| `auto-apn-init.sh` | OpenWrt init script — sets APN at boot |
| `99-auto-apn-hotplug.sh` | Hotplug script — handles SIM hot-swap |
| `setup-dw5821e-modem.sh` | One-shot setup script for Dell DW5821e modem |

## Deployment

### One-shot script (recommended)

```bash
./setup-dw5821e-modem.sh                          # default: root@192.168.1.1
./setup-dw5821e-modem.sh root@192.168.8.1         # custom IP
./setup-dw5821e-modem.sh root@192.168.8.1 --force # re-run
```

### Or deploy manually

```bash
# Copy mapping
cat mcc-mnc-apn.txt | ssh root@router 'cat > /etc/mcc-mnc-apn.txt'

# Copy init script
cat auto-apn-init.sh | ssh root@router 'cat > /etc/init.d/auto-apn && chmod +x /etc/init.d/auto-apn && /etc/init.d/auto-apn enable'

# Copy hotplug
cat 99-auto-apn-hotplug.sh | ssh root@router 'cat > /etc/hotplug.d/iface/99-auto-apn && chmod +x /etc/hotplug.d/iface/99-auto-apn'
```

### Custom interface name

If your modem interface is named something other than `wwan` (e.g. `secondwan`), edit both scripts and change the `IFACE` or `network.wwan` references:

```bash
# In auto-apn-init.sh, change:
CURRENT=$(uci get network.wwan.apn 2>/dev/null)
# to:
CURRENT=$(uci get network.secondwan.apn 2>/dev/null)

# Same for 99-auto-apn-hotplug.sh
```

## Prerequisites: DW5821e Modem Fix

For Dell DW5821e / Foxconn T77W968 (413c:81d7) modems, the default `usb-mode.json` has an entry that forces **Config 0** (unconfigured state), causing driver cycling and ModemManager detection failures.

**Symptoms in dmesg:**
```
usb 2-1: usbfs: interface 1 claimed by usbfs while 'usbmode' sets config #0
qmi_wwan 2-1:1.0 wwan0: register → unregister (200ms cycle)
```

**Fix — remove the entry:**
```bash
# Remove 413c:81d7 from usb-mode.json
sed -i '/"413c:81d7"/,/^[[:space:]]*},$/d' /etc/usb-mode.json

# Verify removed
grep -c '413c:81d7' /etc/usb-mode.json  # should return 0

# Validate JSON
python3 -c "import json; json.load(open('/etc/usb-mode.json')); print('valid')"

# Reboot — modem will start clean in Config 1 (QMI)
```

The `setup-dw5821e-modem.sh` script does this automatically.

## AmneziaWG Note: kmod vs Userspace

If you use AmneziaWG with obfuscation params (Jc, Jmin, Jmax, S1-S4, H1-H4, I1), note that:

- **`kmod-amneziawg`** is a vanilla WireGuard kernel module — it does NOT support obfuscation params
- **`amneziawg-go`** (userspace, ~3MB Go binary) IS required for obfuscation

**Fix — disable kernel module:**
```bash
# Rename .ko so modprobe can't find it
mv /lib/modules/$(uname -r)/amneziawg.ko /lib/modules/$(uname -r)/amneziawg.ko.disabled
rmmod amneziawg 2>/dev/null

# ifup the interface — proto handler detects missing kmod and falls back to amneziawg-go
ifdown awg0; ifup awg0
```

The proto handler (`/lib/netifd/proto/amneziawg.sh`) auto-detects: tries `modprobe amneziawg` first, falls back to `amneziawg-go` if the module isn't found. All obfuscation params are written to the temp config file and applied via `awg setconf`.

## Requirements

- OpenWrt with ModemManager (any modem supported by MM)
- Busybox `awk` (included in base OpenWrt)
- Zero additional dependencies

## How APN Lookup Works

```bash
# ModemManager reads MCC-MNC from tower broadcast
OPID=$(mmcli -m 0 | grep "operator id" | awk '{print $NF}')
# → "51011" (Indonesia / XL Axiata)

# awk does early-exit lookup from flat file
APN=$(awk -v mcc="$OPID" '$1==mcc {print $2; exit}' /etc/mcc-mnc-apn.txt)
# → "internet"

# Write to UCI
uci set network.wwan.apn="$APN"
uci commit network
```

## MCC-MNC Mapping

714 carriers from 200+ countries. Mapping file is a simple two-column format:

```
20201 internet
20205 web.session
44010 jpsim
00101 skt
51010 internet
```

Unknown carriers fall back to `internet`.
