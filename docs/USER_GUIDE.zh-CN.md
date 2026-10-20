# singbox-manager 操作手册

[English](USER_GUIDE.en.md) · [返回首页](../README.md)

## 1. 安装和首次创建节点

适用于 root 权限的 Debian / Ubuntu VPS、Bash 4+ 和 systemd。先确认域名解析和计划使用的端口；本工具不会自动修改防火墙、SSH、3X-UI 或 Xray。

```bash
bash <(curl -fsSL https://github.com/xlp567/singbox-manager/releases/latest/download/install.sh)
```

若缺少 curl，先安装 `curl ca-certificates`。公开仓库无需令牌；安装器会按需安装 Python 3、util-linux 和 OpenSSH 客户端。看到已验证版本后输入 `yes`，然后在自动打开的菜单选择 **1**。

向导中选择官方核心版本和协议，填写服务器地址、监听端口、认证参数及需要的证书信息。普通 TLS 协议使用证书；Reality、Shadowsocks 等按各自参数配置。已有其他程序监听的端口会被避开。检查最终预览并确认后才提交配置，验证失败会停止或回滚。

安装完成后输入 `sbm` 打开菜单。首次下载 GitHub 或官方程序失败时，先排查网络、DNS、时间和限流；不要反复初始化已有节点。

## 2. 选择协议和证书

| 协议 | 常见需要填写的信息 |
|---|---|
| AnyTLS、Trojan、VLESS TLS | 域名 / 地址、TCP 端口、密码或 UUID、TLS 证书 |
| VLESS Reality + Vision | 地址、端口、UUID、握手目标 / SNI、Reality 密钥参数 |
| Hysteria2 + Salamander | 地址、UDP 端口、密码、混淆参数、TLS 证书 |
| TUIC v5 | 地址、UDP 端口、UUID、密码、拥塞控制、TLS 证书 |
| VMess WebSocket TLS | 域名、TCP 端口、UUID、WebSocket 路径、TLS 证书 |
| Shadowsocks | 地址、端口、加密方式和密码 |
| Naive HTTPS | 域名、TCP 端口、用户名 / 密码、TLS 证书；客户端需相应 Cronet 能力 |

使用 ACME 时，域名 A / AAAA 应正确指向服务器，关闭不适用的 CDN 代理。HTTP-01 需要公网 TCP 80，TLS-ALPN-01 需要公网 TCP 443；证书续期时也需要验证端口可用。开放端口由管理员或云平台负责。菜单 **8** 修改共用证书，菜单 **12 / 26** 查看证书状态。

## 3. 节点日常管理

- **2** 查看节点；**3** 继续添加；**4** 修改名称、端口和协议参数。
- **5** 启用 / 停用单个节点；**6** 删除节点；**7** 重置凭据。
- **9** 查看 / 导出客户端配置和二维码。将匹配客户端支持的资料导入客户端，再做实际连接测试。

修改先保存在草稿，提交前会编译并由官方 sing-box 检查。成功启动不等于公网客户端一定可达：还需检查 DNS、证书、云防火墙、系统防火墙、客户端协议支持和网络出口。

## 4. 草稿、清理和文件位置

菜单 **22** 可继续草稿、查看摘要、归档，或永久删除当前草稿和历史草稿归档。永久删除需按提示输入 `DELETE`；清理草稿不会删除已经生效的线上节点。

菜单 **24** 预览并清理旧备份 / 未使用的旧核心。菜单 **29** 或 `sbm paths` 查看实际位置：

| 用途 | 默认位置 |
|---|---|
| 管理脚本 / 快捷命令 | `/root/singbox-manager.sh` / `/usr/local/bin/sbm` |
| 当前核心 | `/opt/singbox-manager/current/sing-box` |
| 配置 / 节点数据 | `/etc/sing-box/config.json` / `manager.json` |
| 草稿 | `/var/lib/singbox-manager/draft.json` |
| 完整备份 | `/var/lib/singbox-manager/backups/` |
| 管理脚本历史 | `/var/lib/singbox-manager/manager-backups/` |
| 客户端资料 | `/var/lib/singbox-manager/exports/` |
| 运行日志 | `journalctl -u sing-box -n 100 --no-pager` |

导出资料、二维码、草稿和备份可能包含密码，勿公开提交。手动修改生成的 `config.json` 会触发外部修改保护。

## 5. 更新管理器和核心

**管理器：30 → 2** 或 `sbm self-update github`。默认匿名读取最新正式 Release，验证固定公钥签名、清单和脚本摘要，静态显示版本，确认后备份并替换管理脚本，不重启代理服务。使用新的 `sbm` 前退出旧菜单。**30 → 3** 回退管理脚本；**30 → 1** 安装通过 SSH 上传的签名发布文件。私有仓库可在 **30 → 4** 配置只读令牌。旧分支设置转为稳定 Release 渠道，不再跟踪 main。

**sing-box 核心：11** 查询版本，**10** 选择 / 升级。稳定版通常适合日常使用；测试版会额外要求 `PREVIEW`。核心更新会进行兼容性和配置检查，确认后切换并重启 sing-box，现有连接可能短暂中断。失败时尝试恢复之前的快照和运行程序。

## 6. 备份、恢复和中断

菜单 **18** 创建包含配置与运行程序的完整备份；菜单 **19** 选择快照恢复。恢复也需检查和确认，可能重启 sing-box。发生异常中断后重新打开无参数 `sbm`，按恢复提示处理；不要随意删除 `pending` 等恢复标记。

发现外部配置或未完成安装时，菜单 **23** 提供“先备份再重新初始化”，只有确认需要迁移或重新配置时使用。不要把它作为网络查询失败的修复方法。

## 7. 菜单速查

| 编号 | 功能 | 编号 | 功能 |
|---|---|---|---|
| 1 | 初始化 / 添加首个节点 | 2 | 节点列表 |
| 3 | 添加节点 | 4 | 修改节点 |
| 5 | 单节点启停 | 6 | 删除节点 |
| 7 | 重置凭据 | 8 | 共用证书 |
| 9 | 客户端导出 | 10 | 核心版本选择 |
| 11 | 查询官方版本 | 12 | 综合诊断 |
| 13 | 实时日志 | 14 | 连接快照 |
| 15 / 16 / 17 | 启动 / 停止 / 重启服务 | 18 / 19 | 完整备份 / 恢复 |
| 20 | 日志等级 | 21 | 卸载，保留数据 |
| 22 | 草稿管理 | 23 | 备份后重新初始化 |
| 24 | 清理旧备份 / 核心 | 25 | 安装快捷命令 |
| 26 | 服务器概况 | 27 | BBR 开关（整机 TCP 设置） |
| 28 | 协议发现和模块管理 | 29 | 文件目录 |
| 30 | 管理器升级 / 回退 | 31 | 出口安全策略 |
| 0 | 退出 | | |

## 8. CLI 和扩展

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

CLI 和菜单共用管理核心。修改仍按交互确认执行；不要把含凭据的操作输入写到公共日志。菜单 **28** 读取当前官方核心的 Schema 生成参数表单，并非从网络猜测配置。无法生成安全客户端、缺少能力或官方检查失败时，仍需专用协议适配。

## 9. 常见问题

| 现象 | 处理 |
|---|---|
| 已有另一个管理脚本运行 | 回到原菜单输入 0 退出；不要强删锁或中断其他人的管理操作 |
| GitHub 403 / 404 / 超时 | 检查仓库地址、公开状态、网络和限流；私有源才需要只读令牌 |
| 旧版升级出现 401 | 旧版可能保存了过期令牌；可用 SSH 上传方式先升级管理器，公开源的新版本优先匿名读取 |
| 域名证书失败 | 核对 DNS、服务器时间、80 / 443 验证方式和端口是否被占用 |
| 服务运行但客户端不通 | 检查协议、凭据、证书、端口、UDP 放行和客户端支持；用实际客户端验证 |
| 检测到外部修改 | 保留现有文件和备份，核对来源，再选择受控迁移方式 |

提交 Issue 时提供版本、系统、复现步骤和脱敏错误，不要附上密码、令牌、私钥或完整客户端资料。

## 10. Base64 与源码构建

### `emit_engine()` 中的内容是什么？

`base64 -d <<'SBM_BUNDLE'` 与结尾单独一行的 `SBM_BUNDLE` 之间，是 Python 管理引擎的 ZIP 压缩包经 Base64 编码后的文本。Base64 可以解码，不是加密。压缩包中包含 `sbm/` 下的 Python 模块和生成的 `__main__.py` 入口，用于协议适配、配置编译、参数验证、审计和管理器升级等功能。

执行需要该引擎的管理操作时，`setup_tmp()` 创建 `/var/lib/singbox-manager/tmp.XXXXXX/` 私有临时目录，把 `emit_engine()` 的解码输出写成 `engine.pyz`，再由 `engine()` 调用 `python3` 运行。正常退出时删除临时目录；异常中断遗留的 `tmp.*` 会在下次取得管理锁后清理。官方 sing-box 代理程序独立位于 `/opt/singbox-manager/current/sing-box`。

### 源码与生成文件

| 文件 / 目录 | 用途 |
|---|---|
| [src/manager-core.sh](../src/manager-core.sh) | Bash 菜单与 CLI 主入口 |
| [src/core/](../src/core/) | 运行版本、事务、服务控制和管理器升级的 Bash 模块 |
| [src/sbm/](../src/sbm/) | 可直接阅读和修改的 Python 管理引擎源码 |
| [tools/build.py](../tools/build.py) | 合并 Bash 模块，打包 Python ZIP 并编码，生成分发脚本与摘要 |
| [tools/build_install_command.py](../tools/build_install_command.py) | 由主构建过程调用，生成安装入口和短命令 |
| [src/bootstrap/install.py](../src/bootstrap/install.py) | 可编辑安装器模板；构建时嵌入签名验证器并生成根目录 install.py |
| [src/sbm/core/release_trust.py](../src/sbm/core/release_trust.py) | 安装和升级共用的固定公钥及签名验证器 |

构建器把 `src/sbm/` 下的全部 `.py` 文件按固定顺序写入 ZIP，并加入调用 `sbm.entrypoint.run()` 的 `__main__.py`；再把 ZIP 编码为 Base64，放进生成的 `emit_engine()`。Bash 的 `# @include core/…` 标记会被相应模块正文替换。最后输出完整脚本并计算它的 SHA-256。请修改源码后重建，不要直接改 Base64 或只修改生成脚本。

### 从源码生成管理脚本

取得完整仓库后，在仓库根目录执行：

```bash
git clone https://github.com/xlp567/singbox-manager.git
cd singbox-manager
python3 tools/build.py
```

若要检查某个已发布版本，先切换对应标签，例如 `git checkout v3.5.7`，再构建；默认分支可能含有发布后的改动。构建需要 Python 3 标准库，不需要 root，也不会安装或重启服务。生成文件是：

- `singbox-manager.sh`：合并 Bash 管理层与 Python 引擎的独立管理脚本。
- `singbox-manager.sha256`：上述脚本的 SHA-256 摘要。
- `install.py`、`install.sh`、`新服务器一键安装命令.txt`：生成的首次安装入口与短命令。

在具备 Bash、ShellCheck 和 Python 3 的开发环境中运行 `bash tools/test.sh`，完成重建、语法检查、ShellCheck、自动化回归和分发摘要检查。需要完整源码包时运行 `python3 tools/package.py`；它生成 `dist/` 下的归档和 `SHA256SUMS`，与生成独立管理脚本是两个步骤。同一份源码在相同构建环境中重复构建，脚本摘要应一致。

### 只读核对 Base64 与源码是否一致

以下命令在仓库根目录执行，只解码、读取 ZIP 并比较文件内容，不运行包内代码，也不连接 VPS。无需手工解码即可直接阅读上表中的源码；此检查用于核对生成物。

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

## 11. 服务停止与发布隐私（v3.5.5）

菜单 16 与 15 / 17 共用事务入口。停止前保存完整快照，随后用 5 次检查（每次间隔 2 秒）确认 ActiveState=inactive、MainPID=0，失败或中断自动恢复之前状态，记录事务审计。不检查无效配置或缺失运行程序，避免无法停止问题服务；启动 / 重启仍先做配置与兼容性检查。

源码构建后执行 `bash tools/test.sh` 与 `python3 tools/package.py`，发布清单和源码包会经过同一隐私门禁，拒绝不合规内容。不要上传运行目录、节点资料或原始部署报告。隐私检查和历史副本处理见 [发布规范](../RELEASING.md)。各版本实测范围见[公开摘要](../reports/PUBLIC_VALIDATION.md)。

## 12. v3.5.6 安全与可靠性

### 出口保护与旧配置迁移

新生成的配置拒绝代理用户访问回环、私网、链路本地、云元数据、组播、本机接口地址和节点自身地址。域名先由系统解析器解析，再检查全部结果；含私网的混合结果、解析失败也拒绝。规则依据 [sing-box 官方路由动作](https://sing-box.sagernet.org/configuration/route/rule_action/) 和[地址匹配](https://sing-box.sagernet.org/configuration/route/rule/)实现。

已部署节点先升级管理器，再执行 `sbm security status` 查看是否生效；选择 **31 → 1** 或 `sbm security apply` 才会备份、确认并应用，期间 sing-box 短暂重启。节点凭据及客户端导出保持兼容。只有与旧模板完全一致的配置才允许自动迁移；手工添加的未知路由仍会阻挡覆盖。应用后去掉保护规则会触发外部修改检查。

本机接口地址在应用配置时采集；IP 变化后需再次应用以刷新。保护针对代理出口，不会设置系统防火墙或限制 SSH、3X-UI、Xray。当前策略拒绝 NAT64、6to4、Teredo 等转换前缀，相关网络可能需要另行设计；不提供关闭保护的普通表单选项。

存在未提交草稿时，安全应用会拒绝覆盖；先到菜单 22 继续、归档或清理，再应用。

### 审计损坏

审计写入失败会明确警告，不再阻断启停、快照或恢复。先保存 `audit.jsonl`，执行 `sbm audit repair` 并确认：原文件以 `audit.jsonl.corrupt-时间-标识` 保留（600），新链记录原文件摘要及最后一个有效哈希。`sbm audit --json` 可核对新链；不要手工截断后宣称链完整。该链能检测损坏，不能防止 root 重写；追加时仍需校验整条链。

### 备份空间

运行文件及配套库按内容摘要保存在 `runtime-objects/`，快照通过硬链接复用独立的不可变副本，不链接到正在运行的文件。跨文件系统时退回复制。每份快照仍可独立恢复，清理旧核心不会使快照失效。成功事务自动保留最近 **10** 份自动快照；手动、旧格式和待恢复快照不自动删除。菜单 24 可预览清理，并回收没有备份引用的运行文件对象。空间检查按本次增量估算，仍需给配置、导出和新核心留出空间。

### 签名发布与首次信任

v3.5.6 起，安装和升级默认只取最新正式 Release，拒绝预发布、缺失或错误签名、清单与标签不匹配、自动降级；没有回退 main 或旧缓存。签名工具为 OpenSSH 的 Ed25519，签名命名空间 `singbox-manager-release`，公钥固定在验证器中，与根目录 `RELEASE_SIGNING.pub` 相同。指纹：

```text
SHA256:iBBDFzAHqEHERHmSi/RbV9IEW8xBeuWcIV3ZkGMotE4
```

确认前只检查签名、摘要、静态版本行及 Bash 语法，不执行候选脚本的 `version` / `help`，不 source 候选脚本。SSH 更新需同时上传脚本、脚本摘要、签名清单和清单签名；[上传工具](../tools/ssh_upgrade.sh)会处理四个文件。旧的本机备份可确认回退，但可能没有签名并丢失安全修复。

首次短命令下载的引导器本身依赖 GitHub HTTPS；它不能证明自己的可信性。新服务器或从不验证签名的旧管理器首次迁移时，应通过独立可信渠道核对公钥指纹或引导器。已安装的固定公钥保护后续更新，但若首次引导器、公钥或维护者签名私钥已被替换，单靠同站下载无法恢复信任。签名私钥不属于源码包，不会部署到 VPS。


## 13. v3.5.7 安装兼容与发布检查

最低支持 Debian 11+ / Ubuntu 20.04+，要求 Python 3.8+、OpenSSH 客户端 8.1+、Bash 4+ 与运行中的 systemd。Debian 10 / Ubuntu 18.04 不受支持；旧 Python、旧系统及不支持 `ssh-keygen -Y` 的工具会明确提示依赖问题。系统最低版本是支持边界，并不表示已在每个发行版逐一实机测试。

菜单 30 → 1 的 SSH 上传和 GitHub 更新均拒绝较旧版本；检查发生在确认前，安装写入前还会静态核对两个已安装入口。相同版本可重新安装或直接判定无变化。需要主动回退时，只通过菜单 30 → 3 选择已有本机备份并明确确认，旧版可能丢失安全修复。

维护者发布须执行 `python3 tools/prepare_github.py --require-private --output .cache/publish.json`、`python3 tools/privacy_guard.py --require-private .cache/publish.json` 和 `python3 tools/package.py --require-private`。私有精确匹配清单缺失、为空或无效即失败；普通第三方源码副本会警告未启用私有匹配，但仍可构建、运行通用扫描。清单永不加入 GitHub 或源码包。公开测试记录统一见 [PUBLIC_VALIDATION.md](../reports/PUBLIC_VALIDATION.md)。
