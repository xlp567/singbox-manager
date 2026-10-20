# singbox-manager

**Debian / Ubuntu 上的 sing-box 多节点管理器。** 用 SSH 菜单或 CLI 管理节点、官方核心版本、备份与恢复。

简体中文 · [English](README.en.md) · [中文操作手册](docs/USER_GUIDE.zh-CN.md) · [English guide](docs/USER_GUIDE.en.md)

![Version](https://img.shields.io/badge/version-3.5.8-blue) [![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE) ![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-informational)

[正式版本与下载附件](https://github.com/xlp567/singbox-manager/releases/latest)：包含完整源码包、独立管理脚本、安装入口、SHA-256 清单及 Ed25519 签名。

[已知问题与使用限制](docs/KNOWN_ISSUES.md)

## 快速开始

最低支持 **Debian 11+ / Ubuntu 20.04+**，并要求 **Python 3.8+、OpenSSH 客户端 8.1+、Bash 4+ 和运行中的 systemd**。Debian 10、Ubuntu 18.04 不受支持；安装器会检查系统及 Python 版本，旧版 `ssh-keygen` 会明确提示不支持签名验证。OpenSSH 的 `-Y` 文件签名功能始于 [8.1](https://www.openssh.org/txt/release-8.1)，`Path.unlink(missing_ok=...)` 始于 [Python 3.8](https://docs.python.org/3/library/pathlib.html#pathlib.Path.unlink)。

在满足上述要求的新 VPS 上用 root 登录 SSH，执行：

```bash
bash <(curl -fsSL https://github.com/xlp567/singbox-manager/releases/latest/download/install.sh)
```

公开仓库，**无需 GitHub 账号或令牌**。安装器按需准备 Python 3、CA 证书、util-linux 和 OpenSSH 客户端，显示已校验的版本；输入 `yes` 安装管理器并打开菜单，选择 **1** 配置第一个节点。

普通用户先运行 `sudo -i`。若系统尚无 curl，先运行 `apt-get update && apt-get install -y curl ca-certificates`。要求 Bash 4+、运行中的 systemd 和可访问的 GitHub / SagerNet 官方下载源。节点监听端口和证书验证端口需由管理员按实际环境放行。

已有管理器使用 **菜单 30 → 2** 或 `sbm self-update github`，不需要重装。**管理脚本升级与 sing-box 核心升级分开**：菜单 30 更新管理器，菜单 10 选择官方核心。

## 能做什么

| 能力 | 使用方式 |
|---|---|
| 多节点管理 | 新增、编辑、启停、删除、重置凭据、客户端导出及二维码 |
| 官方版本管理 | 稳定版 / 测试版 / 历史版本；架构匹配、SHA-256 校验、配置检查 |
| 配置事务 | 预览与确认、完整快照、失败自动回滚、中断恢复 |
| 协议扩展 | 独立模块；扫描当前核心 Schema，按表单填写支持的新协议 |
| 运维 | 日志、诊断、连接快照、服务器概况、证书状态、审计 |
| 草稿和文件 | 草稿继续 / 归档 / 永久删除；菜单 29 查看实际路径 |
| 管理器升级 | GitHub 拉取、SSH 上传安装、历史脚本回退 |

原 27 项菜单保持编号，新增 **28 协议发现**、**29 文件目录**、**30 管理器升级**、**31 出口安全策略**。管理器安装和自升级不修改节点配置、不重启 sing-box，也不控制 3X-UI / Xray。创建节点、切换核心或修改服务配置是单独确认的操作。

## 内置协议

AnyTLS · Hysteria2 + Salamander · Trojan · VLESS TLS · VLESS Reality + Vision · VMess WebSocket TLS · TUIC v5 · Shadowsocks · Naive HTTPS。

协议模块与稳定管理核心分离，服务端和客户端配置统一生成后交给官方 sing-box 检查。核心升级后可用菜单 **28** 重新扫描协议 Schema；结构复杂、无法安全配对客户端或官方验证失败的协议仍需专用适配，不能保证任意未来协议都可自动部署。

## 常用操作

```bash
sbm                       # 中文交互菜单
sbm status                # 服务器与服务概况
sbm versions              # 查询官方核心版本
sbm validate              # 编译并检查当前配置
sbm paths                 # 运行文件、配置、草稿、备份位置
sbm self-update github    # 更新管理器
```

节点创建后，用菜单 **9** 导出客户端资料。请妥善保管导出文件、二维码、草稿和备份，它们可能含有节点凭据。

## 文档

- [中文完整操作手册](docs/USER_GUIDE.zh-CN.md) · [English user guide](docs/USER_GUIDE.en.md)
- [新服务器安装](新服务器安装.md) · [管理器升级与回退](管理脚本升级.md)
- [文件目录速查](文件目录速查.md) · [架构与扩展](架构与扩展.md)
- [自定义协议](自定义协议模块.md) · [更新记录](CHANGELOG.md) · [实际验证记录](测试与部署结果.md)
- [参与贡献](CONTRIBUTING.md) · [许可证](LICENSE)

## 内嵌 Python 引擎（Base64）

`singbox-manager.sh` 的 `emit_engine()` 函数中，`base64 -d <<'SBM_BUNDLE'` 后面的长文本，是**仓库 Python 管理引擎源码的 ZIP 压缩包经过 Base64 编码后的内容**。Base64 可以还原，不提供加密保护；可读源码位于 [src/sbm/](src/sbm/)。它负责协议适配、配置编译、验证和升级等管理工作，实际代理流量由单独安装的官方 sing-box 程序处理。

需要 Python 引擎的管理操作会先把这段内容解码到私有临时目录中的 `engine.pyz`，再交给 `python3` 执行；正常结束后清理临时文件。这样既能按模块维护源码，也能只分发一个管理脚本。

[tools/build.py](tools/build.py) 会把 [src/manager-core.sh](src/manager-core.sh) 与 `src/core/*.sh` 合并，将 `src/sbm/**/*.py` 打包并编码，自动生成 `emit_engine()`、最终脚本及配套 SHA-256 文件。修改功能时编辑 `src/`，再重新构建；不要手工修改生成文件中的 Base64。

构建命令及只读检查包内源码的方法见[操作手册第 10 节](docs/USER_GUIDE.zh-CN.md#10-base64-与源码构建)。

## 从源码构建与验证

```bash
python3 tools/build.py     # 从源码生成脚本、摘要和安装入口
bash tools/test.sh         # 重新构建，再执行语法、ShellCheck 和自动化测试
python3 tools/package.py   # 打包完整源码、文档和已发布的验证记录
```

在完整源码目录中执行以上命令。构建使用 Python 3 标准库；完整验证还需要 Bash、ShellCheck、Git 和 OpenSSH。构建生成 `singbox-manager.sh`、`singbox-manager.sha256`、`install.py`、`install.sh` 和 `新服务器一键安装命令.txt`，不会安装或启动 VPS 服务。单元测试使用临时目录和服务替身；真实协议传输与部署验证另行记录，不能用模拟测试替代公网验收。

每次发布同步本地源码、版本、文档、测试结果和 GitHub，并读回核对发布文件。VPS 配置、证书、凭据、下载缓存和整机备份不属于仓库内容。GitHub 或网络不可达时下载 / 查询会失败，程序保留当前运行版本。

## 许可证

[MIT](LICENSE)。本许可证适用于管理器及本仓库原创代码；SagerNet sing-box 和其他第三方程序遵循各自许可证。本项目不是 SagerNet 官方管理工具。

## v3.5.6 安全与可靠性修复

新配置统一阻止代理访问回环、私网、链路本地、元数据服务和本机接口地址；域名先解析再检查。已有配置升级管理器后，需另选 **31 → 1** 或执行 `sbm security apply`，备份、确认并短暂重启 sing-box 后才生效。仅更新管理器不会改变现有路由。

审计损坏改为警告，可用 `sbm audit repair` 保留原文件并续接新链；运行程序备份按摘要去重，成功事务自动保留最近 10 份自动快照，手动及旧版备份保留。安装和升级只接受最新正式 Release 的固定公钥签名，确认前只做静态检查。签名、首次安装信任边界与 SSH 上传说明见[手册第 12 节](docs/USER_GUIDE.zh-CN.md#12-v356-安全与可靠性)。

菜单 **15 / 16 / 17** 共用事务服务入口。停止服务会先备份，再持续确认服务已停止且主进程退出；失败或中断时自动恢复之前状态。配置损坏或运行文件缺失不会阻止停止。

源码和下载包共用隐私检查，原始部署日志不进入公开分发；发布检查覆盖内嵌 Python 源码。历史信息清理的范围和限制见 [发布规范](RELEASING.md)。
