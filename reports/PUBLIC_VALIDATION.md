# 公开验证摘要 / Public validation summary

原始日志、真实地址、SSH 端口、主机名、节点域名、登录资料及备份位置仅保存在私有目录；以下只发布能力与结果。

| 版本 / Version | 验证范围 / Validation | 结果 / Result |
|---|---|---|
| 3.5.1 | macOS / Debian；九协议、草稿、管理器升级 | 当时各 144 项通过，授权练手验收通过 |
| 3.5.2 | 官方版本查询失败处理 | 当时各 158 项通过 |
| 3.5.3 | 私有源首次安装与已有安装保护 | 当时各 174 项通过 |
| 3.5.4 | 匿名安装、管理器升级、节点连接 | 当时各 186 项通过，练手验收通过 |
| 3.5.5 | 事务停止服务、发布隐私 | 当时本地 208 项通过，未部署 |
| 3.5.6 | 四项安全 / 可靠性修复与实际部署 | macOS / Debian 各 246 项通过；下述实际验证通过 |
| 3.5.7 | 安装兼容、隐私前置条件与本地更新降级检查 | macOS 267 项通过；本次未部署 VPS |
| 3.5.8 | 停止状态、DNS 失败提示、暂存清理、根校验文件、统一重试 | macOS 281 项通过；本次未部署 VPS |
| 3.5.9 | 截断响应检测与重试、元数据解析错误提示 | macOS 289 项通过；本次未部署 VPS |
| 3.6.0 | BBR 原设置恢复、APT 指纹固定、审计分段轮转、多源公网地址 | macOS 311 项通过；本次未部署 VPS |

## v3.6.0 — 2026-10-20

- 本机自动化 **311/311**、Bash 语法、ShellCheck 与管理脚本摘要校验通过。新增：BBR 开启 / 关闭 / 取消 / 被拒绝 / 旧版无记录 / 记录无效六种路径（sysctl 替身）；APT 公钥指纹一致、不一致、多主密钥、gpg 失败，以及指纹不符时不写入 APT 文件；审计分段轮转、封存段篡改检测、首行链接校验、按链保留与清理崩溃遗留段、旧日志兼容、4 进程并发写入；公网检测源回退、仅 HTTPS、拒绝私网 / 错误协议族、网卡公网地址、管理员确认地址及 CLI 参数校验。
- 过程中发现并修复：同一秒内封存的段名不保证排序，按名称清理可能误删最新段；改为沿哈希链保留最新段。
- APT 指纹于 2026-10-20 核对：sing-box.app 与 deb.sagernet.org 返回相同公钥，主密钥指纹与多个独立公开部署项目记载一致。BBR 使用 sysctl 替身验证，未在真实内核上切换；本次不连接或部署 VPS。

Local regression passed **311/311** tests covering BBR record/restore paths (sysctl double), APT fingerprint acceptance and rejection before any APT file is written, audit rotation (sealed-segment tampering, link checks, chain-based retention, crash orphans, legacy logs, four concurrent writers), and multi-source public-address detection with interface and operator-confirmed addresses. A same-second segment-ordering pruning bug was found and fixed during testing. The APT fingerprint was cross-checked on 2026-10-20. BBR was not toggled on a real kernel; not deployed to a VPS.

## v3.5.9 — 2026-10-20

- 本机自动化 **289/289**、Bash 语法、ShellCheck 与管理脚本摘要校验通过。新增：真实 `http.client` 响应在 Content-Length 未满时提前结束会被识别为不完整读取；元数据和附件截断后重试成功；持续截断 3 次后给出干净错误；格式无效的 JSON 不重试并给出明确提示；两个安装入口同样处理。
- 该问题在 v3.5.8 发布读回时发现：维护者本机旧版系统 Python（LibreSSL）连接 GitHub API 时偶发中途断开。v3.5.8 遇到时会安全失败（不安装），但不会重试。本次不连接或部署 VPS。

Local regression passed **289/289** tests, including early EOF on a real `http.client` response with a declared Content-Length, retried truncated metadata/assets, a clean error after three truncated attempts, and non-retried malformed JSON in all readers. Found during v3.5.8 readback, where intermittent mid-response disconnects failed safely but were not retried. Not deployed to a VPS.

## v3.5.8 — 2026-10-20

- 本机自动化 **281/281**、Bash 语法、ShellCheck 与管理脚本摘要校验通过。新增：failed 且无主进程的停止接受、仍有主进程拒绝；dig 失败 / 超时提示；.object-* 暂存清理且保留已完成对象；根目录校验文件更新、写入失败回滚、旧格式备份恢复；共享重试的可重试 / 不可重试分类及次数上限。
- failed 状态停止使用 systemctl 替身验证，尚未在真实 systemd 主机复现；本次不连接或部署 VPS，不修改节点、sing-box Runtime、3X-UI 或 Xray。

Local regression passed **281/281** tests, covering failed-but-exited stops, DNS failure reporting, `.object-*` cleanup, root checksum refresh/rollback and the shared retry classification. The failed-state stop is verified with a systemctl double, not yet on a live systemd host. Not deployed to a VPS.

## v3.5.7 — 2026-10-20

- CodeQL 告警 #1 指向临时测试文件中的合成地址；该数据流由固定数值生成，不读取真实配置、凭据或环境。明确测试命名并保留检测与不回显断言，不关闭扫描规则；远程复扫结果单独核对。

- 本机自动化 **267/267**、Bash 语法、ShellCheck 与管理脚本摘要校验通过；新增系统 / Python / OpenSSH 能力诊断、签名有效但版本较旧的本地上传拦截、双入口版本核对、确认前拒绝、严格隐私清单缺失 / 空值 / 各工具入口及 Git 跟踪检查。
- 发行版最低支持边界为 Debian 11+ / Ubuntu 20.04+，Python 3.8+ 与 OpenSSH 客户端 8.1+。旧版本使用隔离替身和边界测试验证，Python 源码按 3.8 语法解析；不声称已在这些最低版本系统逐一实机安装。
- 本次不连接或部署 VPS，不修改节点、sing-box Runtime、3X-UI 或 Xray。v3.5.6 的实机验收记录是历史结果，不能当作本次新版部署验收。
- 正式发布执行 --require-private，检查当前白名单和解码引擎；发布后匿名读回附件、签名、标签、默认分支及两种自动源码下载，并独立检查公开历史与 Release 材料。
- [已知问题与限制](../docs/KNOWN_ISSUES.md)列出仍未修复的 BBR、APT 指纹、审计性能、公网发现、根目录旧校验文件、强制中断临时对象、网络重试，以及 failed 状态停止疑点和隐私检查边界。

Local regression passed **267/267** tests and covers installer dependency diagnostics, signed local-upload downgrade rejection, both installed entry points, pre-consent rejection, strict missing/empty private-list handling across publication tools and Git tracking. OS/Python/OpenSSH minimums are covered by isolated boundary tests and Python 3.8 syntax parsing, not live installation on every minimum-version distribution. This patch is not deployed to a VPS; v3.5.6 live evidence below remains historical. Publication uses the strict private-list gate and requires anonymous asset/source verification plus history/Release privacy auditing. See the [known issues](../docs/KNOWN_ISSUES.md) for outstanding items.

## v3.5.6 — 2026-10-20

- macOS 与 Debian 自动化各 **246/246**；Bash 语法、ShellCheck、脚本摘要通过。
- 官方 sing-box **1.14.3**：本机九协议实际传输通过；练手 Debian 上九协议实际传输连续 **3 轮**通过，出口安全 **27 项 × 3 轮**通过。回环、私网、元数据、IPv6、映射地址、域名私网 / 混合结果 / 解析失败均被拒绝，正常请求通过。
- 上述隔离连接测试使用拒绝规则之后的测试专用目标映射，将合成公网目标指向回环测试源站；生产配置不含这些覆盖字段，不向真实元数据服务发请求。
- JSON 自定义 SOCKS 与官方 Schema 自动生成的 Snell 实际传输通过；管理脚本未被模块创建修改。
- 独立 systemd 测试实例 **10 个阶段**通过：3 轮启停重启、旧模板迁移、运行失败回滚、强制终止、恢复、审计截断后继续操作、隔离修复续链、备份自动保留与去重。最近 10 份自动快照复用同一运行文件 inode。
- 练手机先完成完整备份并另存本地，随后管理器从旧版更新到 **3.5.6**；单独应用出口保护。管理器更新阶段配置、运行程序与 sing-box PID 未变；策略迁移阶段 sing-box 按事务短暂重启。
- 两个既有节点在变更前 / 后，各连续 **3 次**外部客户端 HTTPS 访问通过；迁移后两种节点均拒绝通过代理访问回环测试页面和 localhost。测试源站仅收到直接对照请求。
- 节点及凭据摘要、运行程序摘要未变；3X-UI / Xray 的原进程与受保护文件摘要未变。无待恢复标记。
- 发布使用同一白名单、固定公钥签名和可复现构建；当前文件、解码引擎、历史 refs、旧 Release 正文 / 附件 / 自动源码包均执行隐私检查。本版发布后的匿名下载与 GitHub 拉取回执见 Release 正文。

测试仅覆盖上述环境和场景，不代表任意未来协议、内核、网络或所有版本都已验证。新主机的首次引导仍需独立建立信任。低优先级跟进：BBR 原参数恢复、APT 公钥指纹固定、长审计链性能及公网地址发现依赖；本版未声称解决这些独立问题。已申请的旧外部缓存清理仍由托管方处理，当前源码检查不等于缓存已消失。

## English

v3.5.6 passed **246/246** automated checks on both macOS and Debian, plus Bash syntax, ShellCheck and distribution checksums. Official sing-box 1.14.3 completed nine-protocol local transfers; the authorized Debian practice host passed **3 rounds** of nine-protocol transfers and **27 egress cases per round**. Test-only mappings after the deny rules keep synthetic public destinations local; production configuration contains no such overrides. No real metadata service is contacted.

JSON-only SOCKS and Schema-generated Snell transfers passed. A disposable systemd unit passed **10 stages**, covering three stop/start/restart cycles, migration, failed-runtime rollback, forced termination/recovery, corrupt-audit operation/repair and deduplicated retention of ten automatic snapshots. Existing production service names were not used for fault injection.

The practice host was fully backed up and the archive copied locally before updating to v3.5.6. Manager installation preserved configuration, runtime and the existing sing-box process. A separate transaction applied egress protection and briefly restarted sing-box. Both existing nodes passed three external HTTPS requests before and after, and rejected controlled loopback/localhost targets afterward. Node credentials, runtime bytes, original 3X-UI/Xray processes and protected file hashes remained unchanged; no pending recovery marker remained.

Only sanitized summaries are published. Source/archives share an allowlist, pinned-key signatures and reproducible builds; privacy review includes decoded engines, reachable history/refs and old releases/assets/generated archives. See the Release body for post-publication anonymous-download and GitHub-pull receipts.

These results cover the named environments and cases, not every future runtime or network. Establish initial bootstrap trust independently. Separate low-priority follow-ups remain: BBR parameter restoration, APT key fingerprint pinning, long-chain audit performance and public-address discovery dependencies. Previously requested external-cache removal remains with the hosting provider; clean current source does not prove cached copies are gone.
