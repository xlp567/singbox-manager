# singbox-manager

**A multi-node sing-box manager for Debian and Ubuntu.** Manage nodes, official runtime versions, backups and recovery through an SSH menu or CLI.

[简体中文](README.md) · English · [English user guide](docs/USER_GUIDE.en.md) · [中文操作手册](docs/USER_GUIDE.zh-CN.md)

![Version](https://img.shields.io/badge/version-3.5.8-blue) [![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE) ![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-informational)

[Official project releases and downloads](https://github.com/xlp567/singbox-manager/releases/latest) include source, the standalone manager, installation entries, SHA-256 manifest and Ed25519 signature.

[Known issues and limits](docs/KNOWN_ISSUES.md)

## Quick start

Minimum supported systems: **Debian 11+ / Ubuntu 20.04+**, with **Python 3.8+, OpenSSH client 8.1+, Bash 4+ and running systemd**. Debian 10 and Ubuntu 18.04 are unsupported. The installer checks OS/Python versions and reports unsupported signature tools explicitly. File signatures were introduced in [OpenSSH 8.1](https://www.openssh.org/txt/release-8.1); `Path.unlink(missing_ok=...)` requires [Python 3.8](https://docs.python.org/3/library/pathlib.html#pathlib.Path.unlink).

Log in as root to a new VPS meeting these requirements and run:

```bash
bash <(curl -fsSL https://github.com/xlp567/singbox-manager/releases/latest/download/install.sh)
```

The public repository requires **no GitHub account or token**. The installer prepares Python 3, CA certificates, util-linux and an OpenSSH client when needed, verifies the release, and asks for `yes` before installing the manager. It opens `sbm`; choose **1** to configure your first node. The interactive menu is currently in Chinese; this guide explains the numbered actions in English.

For a non-root account, run `sudo -i` first. If curl is missing, install it with `apt-get update && apt-get install -y curl ca-certificates`. Bash 4+, a running systemd, and access to GitHub and official SagerNet downloads are required. Configure your firewall and certificate-validation ports for your own environment.

Already installed? Use **menu 30 → 2** or `sbm self-update github`. **Manager updates and runtime updates are separate:** menu 30 updates the manager, while menu 10 selects the official sing-box runtime.

## Features

| Capability | What it provides |
|---|---|
| Multiple nodes | Add, edit, enable, disable, remove, rotate credentials, export clients and QR codes |
| Official runtime versions | Stable, prerelease and historical selection, architecture matching, SHA-256 verification |
| Configuration transactions | Confirmation, complete snapshots, validation, rollback on failure and interruption recovery |
| Extensible protocols | Independent adapters and forms discovered from the running runtime's JSON Schema |
| Operations | Logs, diagnostics, connection snapshots, certificate status and audit records |
| Drafts and paths | Resume, archive or permanently purge drafts; inspect actual paths in menu 29 |
| Manager delivery | Public GitHub updates, SSH uploads, and manager rollback |

The original 27 menu numbers remain unchanged. Additional entries are **28 protocol discovery**, **29 file locations**, **30 manager updates**, and **31 egress security**. Installing or updating the manager does not change node configurations, restart sing-box, or control 3X-UI / Xray. Node changes and runtime changes are separate confirmed operations.

## Built-in protocols

AnyTLS · Hysteria2 + Salamander · Trojan · VLESS TLS · VLESS Reality + Vision · VMess WebSocket TLS · TUIC v5 · Shadowsocks · Naive HTTPS.

A stable management core and independent protocol modules share a configuration compiler. Official sing-box validates the result. After updating the runtime, menu **28** can scan its Schema for additional protocols. Complex topologies, unsupported client mappings or failed validation still require an adapter; automatic support for every future protocol is not guaranteed.

## Common commands

```bash
sbm                       # Interactive menu, currently in Chinese
sbm status                # Host and service overview
sbm versions              # Query official runtime releases
sbm validate              # Compile and check the current configuration
sbm paths                 # Locate runtime, configuration, drafts and backups
sbm self-update github    # Update the manager
```

Use menu **9** to export client information. Exports, QR codes, drafts and backups may contain credentials; keep them private.

## Documentation

- [English user guide](docs/USER_GUIDE.en.md) · [中文完整操作手册](docs/USER_GUIDE.zh-CN.md)
- [Changelog](CHANGELOG.md) · [Validation records](测试与部署结果.md)
- [Architecture](架构与扩展.md) · [Custom protocols](自定义协议模块.md) · [File locations](文件目录速查.md)
- [Contributing](CONTRIBUTING.md) · [License](LICENSE)

## Embedded Python engine (Base64)

The long text following `base64 -d <<'SBM_BUNDLE'` inside `emit_engine()` in `singbox-manager.sh` is **a ZIP archive of the repository's Python management engine, encoded as Base64**. Base64 is reversible encoding and provides no encryption. Readable source is available in [src/sbm/](src/sbm/). This engine handles protocol adaptation, configuration compilation, validation and manager updates; the separately installed official sing-box runtime handles proxy traffic.

Management operations that need the engine decode it into `engine.pyz` in a private temporary directory, execute it with `python3`, and remove the temporary files on normal exit. This allows modular source maintenance while distributing a single manager script.

[tools/build.py](tools/build.py) combines [src/manager-core.sh](src/manager-core.sh) with `src/core/*.sh`, packs and encodes `src/sbm/**/*.py`, and generates `emit_engine()`, the final script and its SHA-256 file. Edit `src/` and rebuild when changing functionality; do not edit the generated Base64 manually.

See [section 10 of the user guide](docs/USER_GUIDE.en.md#10-embedded-base64-and-building-from-source) for build steps and a read-only check of the bundled source.

## Build from source and validate

```bash
python3 tools/build.py     # Generate the manager, checksum and installation entries
bash tools/test.sh         # Rebuild, then run syntax checks, ShellCheck and tests
python3 tools/package.py   # Package source, documentation and published test evidence
```

Run these commands from a complete source checkout. Building uses the Python 3 standard library; full validation also requires Bash, ShellCheck, Git and OpenSSH. Build outputs are `singbox-manager.sh`, `singbox-manager.sha256`, `install.py`, `install.sh` and `新服务器一键安装命令.txt`; building does not install or start VPS services. Unit tests use temporary directories and service substitutes; actual protocol transfers and deployment checks are recorded separately.

Publish source, version, documentation and test evidence together; read back the GitHub files to verify consistency. VPS configurations, credentials, certificates, runtime caches and machine backups do not belong in the repository. Downloads and queries can fail during GitHub or network outages; the running version is preserved.

## License

[MIT](LICENSE) for this manager and original repository code. SagerNet sing-box and other third-party programs retain their own licenses. This is an independent project, not an official SagerNet management tool.

## v3.5.6 security and reliability

New configurations block proxy access to loopback, private/link-local/metadata destinations and the host's interface addresses, including DNS-resolved destinations. After updating an existing manager, separately choose **31 → 1** or run `sbm security apply`. It backs up, asks for confirmation and briefly restarts sing-box. Updating the manager alone preserves existing routes.

Corrupt audit records warn without blocking operations; `sbm audit repair` preserves the original and links a new chain. Runtime backups are deduplicated; successful transactions retain the latest 10 automatic snapshots, while manual and legacy backups remain. Installation and updates use the latest formal Release, a pinned Ed25519 public key and static checks before consent. See [guide section 12](docs/USER_GUIDE.en.md#12-v356-security-and-reliability) for signature and first-install trust boundaries.

Menu actions **15 / 16 / 17** share transactional service control. Stop takes a backup, verifies inactive state and process exit over an observation window, and restores the previous state on failure or interruption. Invalid configuration or a missing runtime does not block stopping.

Source and release packages share a privacy gate, including decoded Python source. Raw deployment logs are excluded. See the [release procedure](RELEASING.md) for historical cleanup scope and limitations.
