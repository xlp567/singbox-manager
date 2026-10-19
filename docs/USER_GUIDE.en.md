# singbox-manager user guide

[简体中文](USER_GUIDE.zh-CN.md) · [Project home](../README.en.md)

The interactive menu is currently in Chinese. Menu numbers below match the installed program.

## 1. Install and create the first node

Use a Debian / Ubuntu VPS with root access, Bash 4+ and systemd. Plan the domain and listening ports. The manager does not automatically change your firewall, SSH, 3X-UI or Xray.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xlp567/singbox-manager/main/install.sh)
```

Install `curl ca-certificates` first if curl is missing. The public repository needs no token. The bootstrap prepares Python 3 and util-linux when required, verifies the manager, and asks for `yes` before installation. In the menu that opens, choose **1**.

Select an official runtime version and protocol, then provide the server address, port, authentication and certificate information requested by the wizard. TLS protocols need certificates; Reality and Shadowsocks have their own parameters. Ports occupied by other programs are avoided. Review the final preview and confirm before applying. Invalid configurations are rejected or rolled back.

Run `sbm` for later use. If a download fails, check connectivity, DNS, system time and API limits; do not reinitialize existing nodes to fix a network query failure.

## 2. Protocols and certificates

| Protocol | Typical inputs |
|---|---|
| AnyTLS, Trojan, VLESS TLS | Domain/address, TCP port, password or UUID, TLS certificate |
| VLESS Reality + Vision | Address, port, UUID, handshake target/SNI, Reality key parameters |
| Hysteria2 + Salamander | Address, UDP port, password, obfuscation, TLS certificate |
| TUIC v5 | Address, UDP port, UUID, password, congestion control, TLS certificate |
| VMess WebSocket TLS | Domain, TCP port, UUID, WebSocket path, TLS certificate |
| Shadowsocks | Address, port, cipher and password |
| Naive HTTPS | Domain, TCP port, username/password, TLS; matching Cronet client capabilities |

For ACME, point the domain's A/AAAA records to the server and disable incompatible CDN proxying. HTTP-01 needs public TCP 80; TLS-ALPN-01 needs public TCP 443, including during renewals. Configure the cloud and host firewalls yourself. Use **8** for shared certificates and **12 / 26** for status.

## 3. Daily node management

Use **2** to list nodes, **3** to add, **4** to edit, **5** to enable/disable, **6** to remove, and **7** to rotate credentials. Use **9** to export client configurations and QR codes, then import a compatible format into your client and perform an actual connection test.

Edits are staged as drafts. Official sing-box checks the compiled configuration before applying it. A running service does not prove public connectivity: verify DNS, certificates, cloud/host firewalls, protocol support and the network path.

## 4. Drafts, cleanup and paths

Menu **22** resumes, summarizes or archives drafts, or permanently deletes the current draft and archived drafts. Permanent deletion requires `DELETE`. Purging a draft does not delete the active nodes.

Menu **24** previews old backup/runtime cleanup. Menu **29** or `sbm paths` shows actual locations:

| Purpose | Default location |
|---|---|
| Manager / shortcut | `/root/singbox-manager.sh` / `/usr/local/bin/sbm` |
| Active runtime | `/opt/singbox-manager/current/sing-box` |
| Configuration / node data | `/etc/sing-box/config.json` / `manager.json` |
| Draft | `/var/lib/singbox-manager/draft.json` |
| Complete snapshots | `/var/lib/singbox-manager/backups/` |
| Manager history | `/var/lib/singbox-manager/manager-backups/` |
| Client exports | `/var/lib/singbox-manager/exports/` |
| Logs | `journalctl -u sing-box -n 100 --no-pager` |

Exports, QR codes, drafts and backups may contain credentials. Keep them private. Editing generated `config.json` by hand triggers external-change protection.

## 5. Update the manager or runtime

**Manager: 30 → 2**, or `sbm self-update github`. Public repositories are read anonymously first. The updater downloads the script and checksum from one pinned commit, verifies them, asks for confirmation, and backs up/replaces the manager without restarting the proxy. Exit the old menu before using the new `sbm`. Use **30 → 3** for manager rollback, **30 → 1** for a script/checksum uploaded through SSH, and **30 → 4** for optional private-repository credentials.

**sing-box runtime: 11** checks official versions; **10** selects or upgrades. Stable is the usual choice; prereleases require `PREVIEW`. After compatibility/configuration checks and confirmation, runtime changes restart sing-box and may interrupt connections briefly. Failed changes attempt to restore the prior snapshot/runtime.

## 6. Backups and interrupted changes

Use **18** for a complete configuration/runtime snapshot and **19** to select one for restoration. Restoration also requires validation and confirmation and may restart sing-box. After an interrupted transaction, open `sbm` without arguments and follow its recovery message. Do not delete recovery markers such as `pending` manually.

Menu **23** backs up before reinitializing an incomplete installation or external configuration. Use it only when migration/reconfiguration is intended; it is not a remedy for a failed version query.

## 7. Menu reference

| Number | Action | Number | Action |
|---|---|---|---|
| 1 | Initialize / first node | 2 | List nodes |
| 3 | Add node | 4 | Edit node |
| 5 | Enable / disable node | 6 | Remove node |
| 7 | Rotate credentials | 8 | Shared certificates |
| 9 | Client exports | 10 | Select runtime version |
| 11 | Query official releases | 12 | Diagnostics |
| 13 | Live logs | 14 | Connection snapshot |
| 15 / 16 / 17 | Start / stop / restart | 18 / 19 | Backup / restore |
| 20 | Log level | 21 | Uninstall, retain data |
| 22 | Draft management | 23 | Back up and reinitialize |
| 24 | Clean old backups/runtimes | 25 | Install shortcut |
| 26 | Host overview | 27 | BBR switch, host-wide TCP settings |
| 28 | Protocol discovery/modules | 29 | File locations |
| 30 | Manager update/rollback | 0 | Exit |

## 8. CLI and protocol extensions

```bash
sbm help
sbm status
sbm versions
sbm list
sbm validate
sbm backup
sbm paths --json
sbm protocols
sbm protocol discover
sbm protocol create
sbm compat
sbm audit
```

CLI and menus share the same management core and confirmations. Do not log credential-bearing input. Menu **28** reads the running official runtime's Schema and generates forms; it does not guess configurations from web pages. Protocols that lack safe client mapping or runtime capabilities, or fail official validation, still need a dedicated adapter.

## 9. Troubleshooting

| Symptom | Action |
|---|---|
| Another manager is running | Return to its menu and choose 0; do not remove the lock or interrupt another operator |
| GitHub 403/404/timeouts | Check repository URL, visibility, connectivity and limits; only private sources require credentials |
| An older updater returns 401 | An old token may have expired; use SSH upload to update the manager; new public updates prefer anonymous access |
| Certificate issuance fails | Check DNS, time, challenge method and TCP 80/443 availability |
| Service runs, client fails | Check protocol, credentials, TLS, ports, UDP rules and client support; perform an actual client test |
| External change detected | Preserve files and backups, inspect the change, then use a controlled migration path |

When opening an issue, include versions, OS, reproduction steps and sanitized errors. Do not attach tokens, passwords, private keys or complete client profiles.
