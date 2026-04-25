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

## Deployment

Part of the DW5821e modem Ansible playbook:
```bash
cd ansible/playbooks
ansible-playbook -i inventory.ini setup-dw5821e-modem.yml
```

Or deploy manually:
```bash
# Copy mapping
cat mcc-mnc-apn.txt | ssh jump "ssh root@router 'cat > /etc/mcc-mnc-apn.txt'"

# Copy init script
cat auto-apn-init.sh | ssh jump "ssh root@router 'cat > /etc/init.d/auto-apn && chmod +x /etc/init.d/auto-apn && /etc/init.d/auto-apn enable'"

# Copy hotplug
cat 99-auto-apn-hotplug.sh | ssh jump "ssh root@router 'cat > /etc/hotplug.d/iface/99-auto-apn && chmod +x /etc/hotplug.d/iface/99-auto-apn'"
```

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
