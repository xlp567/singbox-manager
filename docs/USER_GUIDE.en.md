# singbox-manager user guide

[简体中文](USER_GUIDE.zh-CN.md) · [Project home](../README.en.md)

The interactive menu is currently in Chinese. Menu numbers below match the installed program.

## 1. Install and create the first node

Use a Debian 11+ / Ubuntu 20.04+ VPS with root access, Bash 4+ and systemd. Plan the domain and listening ports. The manager does not automatically change your firewall, SSH, 3X-UI or Xray.

```bash
bash <(curl -fsSL https://github.com/xlp567/singbox-manager/releases/latest/download/install.sh)
```

Install `curl ca-certificates` first if curl is missing. The public repository needs no token. The bootstrap prepares Python 3, util-linux and an OpenSSH client when required, verifies the manager, and asks for `yes` before installation. In the menu that opens, choose **1**.

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

**Manager: 30 → 2**, or `sbm self-update github`. The latest formal Release is read anonymously first. The updater verifies its pinned-key signature, manifest and checksums, statically previews the version, then asks for consent before backing up/replacing the manager without restarting the proxy. Exit the old menu before using the new `sbm`. Use **30 → 3** for manager rollback, **30 → 1** for signed files uploaded through SSH, and **30 → 4** for private-repository credentials. Legacy branch settings migrate to the stable Release channel; main is no longer followed.

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
| 30 | Manager update/rollback | 31 | Egress security |
| 0 | Exit | | |

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

## 10. Embedded Base64 and building from source

### What is inside `emit_engine()`?

The text between `base64 -d <<'SBM_BUNDLE'` and the closing standalone `SBM_BUNDLE` line is a ZIP archive of the Python management engine, encoded as Base64. Base64 is reversible encoding, not encryption. The archive contains the Python modules under `sbm/` and a generated `__main__.py` entry point for protocol adaptation, configuration compilation, parameter validation, auditing and manager updates.

When a management operation needs this engine, `setup_tmp()` creates a private `/var/lib/singbox-manager/tmp.XXXXXX/` directory and writes the decoded output of `emit_engine()` to `engine.pyz`. The `engine()` helper runs it with `python3`. Normal exit removes the temporary directory; leftover `tmp.*` directories from an interruption are removed after the next manager acquires its lock. The official sing-box proxy runtime is installed separately at `/opt/singbox-manager/current/sing-box`.

### Source and generated files

| File / directory | Purpose |
|---|---|
| [src/manager-core.sh](../src/manager-core.sh) | Bash menu and CLI entry point |
| [src/core/](../src/core/) | Bash modules for runtime versions, transactions, service control and manager updates |
| [src/sbm/](../src/sbm/) | Readable, editable Python management engine source |
| [tools/build.py](../tools/build.py) | Merge Bash modules, create and encode the Python ZIP, generate the manager and checksum |
| [tools/build_install_command.py](../tools/build_install_command.py) | Called by the main build to generate the bootstrap and short installation command |
| [src/bootstrap/install.py](../src/bootstrap/install.py) | Editable installer template; the build embeds the verifier and generates root install.py |
| [src/sbm/core/release_trust.py](../src/sbm/core/release_trust.py) | Shared pinned public key and release verifier |

The builder writes all `.py` files under `src/sbm/` to a ZIP in a fixed order and adds `__main__.py`, which calls `sbm.entrypoint.run()`. It encodes the ZIP as Base64 inside the generated `emit_engine()` function. Bash `# @include core/…` markers are replaced with the corresponding module contents. Finally it writes the complete script and computes its SHA-256. Edit source and rebuild; do not edit the Base64 or modify only the generated script.

### Build the standalone manager

Get the complete repository and run from its root:

```bash
git clone https://github.com/xlp567/singbox-manager.git
cd singbox-manager
python3 tools/build.py
```

To inspect a published version, check out its tag first, for example `git checkout v3.6.0`, then build. The default branch may contain changes made after a release. Building uses the Python 3 standard library, requires no root access, and does not install or restart services. Outputs are:

- `singbox-manager.sh`: the combined Bash management layer and bundled Python engine.
- `singbox-manager.sha256`: the SHA-256 checksum of that script.
- `install.py`, `install.sh` and `新服务器一键安装命令.txt`: generated installation entries and short command.

With Bash, ShellCheck, Git, OpenSSH and Python 3 installed, run `bash tools/test.sh` to rebuild and run syntax checks, ShellCheck, regression tests and distribution checksum validation. To create the full source archive, run `python3 tools/package.py`; this produces the archive and `SHA256SUMS` under `dist/`, separately from building the standalone script. Repeated builds from identical source in the same build environment should produce the same script checksum.

### Read-only comparison of the bundle and source

Run the following from the repository root. It only decodes and reads the ZIP and compares file contents; it does not run bundled code or connect to a VPS. You can read the source directories above directly without decoding; this optional check verifies the generated artifact.

```bash
python3 - <<'PY'
import base64, io, pathlib, zipfile
root = pathlib.Path('.')
script = (root / 'singbox-manager.sh').read_text()
payload = script.split("    base64 -d <<'SBM_BUNDLE'\n", 1)[1].split('\nSBM_BUNDLE\n', 1)[0]
expected = {p.relative_to(root / 'src').as_posix(): p.read_bytes()
            for p in (root / 'src/sbm').rglob('*.py')}
expected['__main__.py'] = b'from sbm.entrypoint import run\nrun()\n'
data = base64.b64decode(''.join(payload.split()), validate=True)
with zipfile.ZipFile(io.BytesIO(data)) as archive:
    assert set(archive.namelist()) == set(expected), 'Bundle file list differs'
    for name, content in expected.items():
        assert archive.read(name) == content, 'Source mismatch: ' + name
print('PASS: bundled Python files match source:', len(expected))
PY
```

## 11. Stopping services and publication privacy (v3.5.5)

Menu 16 shares the transaction entry point with 15 / 17. It saves a full snapshot, then checks ActiveState=inactive and MainPID=0 five times, two seconds apart. Failure or interruption restores the previous state and records an audit event. Stop does not require valid configuration or an available runtime. Start and restart retain their compatibility and configuration checks.

Run `bash tools/test.sh` and `python3 tools/package.py` after building. The publication manifest and archive share a privacy gate. Do not publish runtime directories, node data or raw deployment reports. See the [release procedure](../RELEASING.md) and [public validation summary](../reports/PUBLIC_VALIDATION.md) for each version's actual scope.

## 12. v3.5.6 security and reliability

### Egress policy and migration

Generated configurations reject loopback, private, link-local, metadata, multicast, local-interface and node-self destinations. Domains are resolved with the system resolver before checking all results; mixed public/private answers and failed resolution are rejected. See official [rule actions](https://sing-box.sagernet.org/configuration/route/rule_action/) and [address matching](https://sing-box.sagernet.org/configuration/route/rule/).

After updating the manager, run `sbm security status`, then **31 → 1** or `sbm security apply`. Only this separately confirmed transaction changes live routes, with a backup and brief sing-box restart. Node credentials and client exports remain compatible. Only an exact historical generated configuration is recognized for migration; unknown edits still block overwriting. Stripping an applied policy triggers external-change protection.

Local addresses are captured during application; apply again after interface IP changes. This is proxy egress policy, not a host firewall, and does not change SSH, 3X-UI or Xray. NAT64, 6to4 and Teredo prefixes are rejected; networks relying on these need a separate policy design. Ordinary forms do not offer disabling protection.

An existing unfinished draft blocks security application rather than being overwritten; resume, archive or purge it through menu 22 first.

### Damaged audit log

Failed audit writes warn without blocking operations. Preserve `audit.jsonl`, then run `sbm audit repair` and confirm. The original becomes `audit.jsonl.corrupt-<time>-<id>` with mode 600; the new chain records its digest and last valid hash. Use `sbm audit --json` to verify. Do not silently truncate and claim an intact chain. This detects corruption, not privileged rewriting. From v3.6.0 appends verify only the current segment; see section 16.

### Backup storage

Runtime binaries/libraries are copied once into content-addressed `runtime-objects/`. Snapshots hard-link to that independent immutable copy, never to the live binary; cross-filesystem storage falls back to copies. Snapshots remain restorable after old runtime directories are removed. Successful transactions keep the latest **10** automatic snapshots; manual, legacy and pending-recovery backups remain. Menu 24 previews cleanup and collects unreferenced objects. Free-space checks estimate incremental storage; allow room for configurations, exports and new runtimes.

### Signed releases and initial trust

From v3.5.6, installation/update selects the latest formal Release and rejects prereleases, invalid/missing signatures, tag/manifest mismatches and automatic downgrades. There is no main/stale-cache fallback. OpenSSH Ed25519 signatures use namespace `singbox-manager-release`; the verifier pins the key in `RELEASE_SIGNING.pub`. Fingerprint:

```text
SHA256:iBBDFzAHqEHERHmSi/RbV9IEW8xBeuWcIV3ZkGMotE4
```

Before consent, only signatures, checksums, static version lines and Bash syntax are checked. Candidate `version`/`help` commands are never run, and the candidate is not sourced. SSH updates require the script, checksum, signed manifest and manifest signature; the [helper](../tools/ssh_upgrade.sh) handles all four. Explicit rollback to a local older backup may lack a release signature and lose security fixes.

The initially downloaded bootstrap still relies on GitHub HTTPS and cannot authenticate itself. On a new host, or the first migration from an unsigned old manager, independently verify the public-key fingerprint or bootstrap. A previously trusted pinned key protects subsequent updates, but a replaced initial bootstrap/key or compromised signing private key defeats that trust. The signing private key is never included in source, downloads or VPS deployment.


## 13. v3.5.7 installation compatibility and publication checks

Minimum supported systems are Debian 11+ / Ubuntu 20.04+, with Python 3.8+, OpenSSH client 8.1+, Bash 4+ and running systemd. Debian 10 / Ubuntu 18.04 are unsupported. Old Python/OS versions and tools lacking `ssh-keygen -Y` produce explicit dependency errors. These minimums describe the support boundary; they do not claim live validation on every distribution.

Both menu 30 → 1 SSH uploads and GitHub updates reject older versions before consent. The install function also checks both existing script entry points statically before writing. Equal versions remain allowed and may be a no-op. Intentional rollback uses menu 30 → 3 with a local backup and explicit confirmation; older backups may lose security fixes.

Maintainer releases require `python3 tools/prepare_github.py --require-private --output .cache/publish.json`, `python3 tools/privacy_guard.py --require-private .cache/publish.json` and `python3 tools/package.py --require-private`. A missing, empty or invalid private exact-match list fails these checks. Third-party source copies can still build and run generic checks, with a warning that private matching is unavailable. Never publish the private list. Public test evidence is summarized in [PUBLIC_VALIDATION.md](../reports/PUBLIC_VALIDATION.md).


## 14. v3.5.8 reliability fixes

- Menu 16 stop: systemd may keep a unit in `failed` (for example after an earlier crash). Once the main process has exited (MainPID=0) the service counts as stopped; a remaining main process still fails and rolls back.
- DNS lookups for node names that fail or exceed 15 seconds now report the name and A/AAAA record type. Nothing is committed and the running service is unchanged.
- `.object-*` staging directories left by a hard interruption (power loss / SIGKILL) are removed by the next post-commit cleanup or menu 24.
- Menu 30 manager updates also refresh `/root/singbox-manager.sha256`, backing it up and rolling it back with both script entry points.
- GitHub reads retry network interruptions, timeouts and 408/429/5xx up to 3 attempts. Permission, signature and format errors are not retried, and unverified files are never installed.

See [known issues and limits](KNOWN_ISSUES.md) for outstanding items.


## 15. v3.5.9 truncated-response fix

When a GitHub response ends before its declared length, the read is treated as a transient network failure and retried (up to 3 attempts) instead of returning partial data. If metadata is still incomplete or malformed, menu 30 and both bootstrap entry points report an incomplete/invalid response, change no manager script and install nothing.


## 16. v3.6.0 known-issue fixes

- **BBR (menu 27)**: before enabling, the current congestion control and qdisc are recorded in `/var/lib/singbox-manager/bbr-original.conf` and restored when disabled. Hosts enabled by older versions without a record still fall back to cubic. BBR is host-wide and affects other TCP services while enabled.
- **APT key**: when installing official sing-box, the downloaded SagerNet key must contain exactly one primary key with full fingerprint `2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C`, otherwise no APT source is written. Menu 12 checks the installed `/etc/apt/keyrings/sagernet.asc`.
- **Audit log**: at 5000 entries or 2 MiB the current segment is sealed as read-only `audit.jsonl.<time>-<id>.gz`; the next segment's first row records the sealed segment's digest and last hash. `sbm audit` reports the current and sealed segments; the newest 20 are kept.
- **Public-address check**: several HTTPS sources are tried and global interface addresses are included. NAT/floating-IP hosts can run `sbm security public-ip add <public IP>`; use `show`, `remove <IP>` and `clear` to manage the list. Only public addresses are accepted; nodes and services are unchanged.

## 17. v3.6.1 boundary fixes and recovery

- **Audit concurrency**: append, rotation, cleanup and repair share the stable `audit.jsonl.lock`; verification takes a shared lock on the same file. Never delete an active lock file or run old independent audit writers alongside this version.
- **Missing segments**: format 4 rotation headers bind the actual retention boundary into the hash chain. Only history at or before that boundary may be pruned. A missing current segment with sealed history present, or missing newest/retained intermediate segments make `sbm audit` fail instead of claiming normal retention. Ordinary appends check the current segment; run `sbm audit` for complete retained-history verification.
- **Legacy logs**: formats 1/2/3 remain readable. A missing older tail after 20 retained legacy segments is explicitly reported as unverified because older versions recorded no boundary. A subsequent successful rotation establishes a new boundary; it cannot retroactively prove why earlier files disappeared. Older managers cannot read format 4; preserve audit files before a rollback, which does not convert the audit format.
- **Audit recovery**: `sbm audit repair` isolates a corrupt current file and preserves its sealed segments under `audit.jsonl.corrupt-<time>-<id>.segments/`, preventing later live retention from destroying evidence. Repair cannot reconstruct missing records. Restore matching private backup material before verifying missing history; do not delete logs to bypass errors. Failed audit writes still warn without blocking service management.
- **BBR recovery**: delete `bbr-original.conf` only after both saved values are written successfully and read back correctly. Incomplete restoration during failed enable or disable keeps the record and returns an explicit failure. Menu 27 offers a confirmed retry; cancellation preserves the record. Do not delete pending recovery records; menu 29 locates them. Normal restoration does not reload unrelated sysctl configuration. Hosts enabled by older versions without a record still fall back to cubic.
- **Public addresses**: detection, interface addresses and operator confirmation accept public unicast only, rejecting multicast, unspecified, loopback, link-local and reserved addresses.

BBR recovery is tested using a sysctl double, not a live kernel. This version has not been deployed to a VPS. A manager update does not apply these network operations automatically.
