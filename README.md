# singbox-manager

**Debian / Ubuntu 上的 sing-box 多节点管理器。** 用 SSH 菜单或 CLI 管理节点、官方核心版本、备份与恢复。

简体中文 · [English](README.en.md) · [中文操作手册](docs/USER_GUIDE.zh-CN.md) · [English guide](docs/USER_GUIDE.en.md)

![Version](https://img.shields.io/badge/version-3.5.4-blue) [![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE) ![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-informational)

## 快速开始

在新的 **Debian / Ubuntu VPS** 上用 root 登录 SSH，执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xlp567/singbox-manager/main/install.sh)
```

公开仓库，**无需 GitHub 账号或令牌**。安装器按需准备 Python 3、CA 证书和 util-linux，显示已校验的版本；输入 `yes` 安装管理器并打开菜单，选择 **1** 配置第一个节点。

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

原 27 项菜单保持编号，新增 **28 协议发现**、**29 文件目录**、**30 管理器升级**。管理器安装和自升级不修改节点配置、不重启 sing-box，也不控制 3X-UI / Xray。创建节点、切换核心或修改服务配置是单独确认的操作。

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

## 开发与验证

```bash
bash tools/test.sh
python3 tools/package.py
```

开发验证需要 Python 3、Bash、ShellCheck。单元测试使用临时目录和服务替身；真实协议传输与部署验证另行记录，不能用模拟测试替代公网验收。源码在 `src/`，`tools/build.py` 生成可独立部署的 `singbox-manager.sh`、摘要和安装入口。

每次发布同步本地源码、版本、文档、测试结果和 GitHub，并读回核对发布文件。VPS 配置、证书、凭据、下载缓存和整机备份不属于仓库内容。GitHub 或网络不可达时下载 / 查询会失败，程序保留当前运行版本。

## 许可证

[MIT](LICENSE)。本许可证适用于管理器及本仓库原创代码；SagerNet sing-box 和其他第三方程序遵循各自许可证。本项目不是 SagerNet 官方管理工具。
