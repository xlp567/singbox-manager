# 已知问题与限制 / Known issues and limits

核对版本：v3.6.1。此清单区分未修复行为、待复现疑点与使用限制；测试通过不代表问题清零。公开记录不包含测试环境标识。

| 状态 | 未完成项及影响 |
|---|---|
| 使用限制 | 菜单 27 的 BBR 是整机 TCP 参数，开启期间影响同机其他 TCP 服务；v3.6.0 起关闭时恢复开启前记录的设置，旧版开启的主机无记录时回退为 cubic。 |
| 使用限制 | SagerNet APT 公钥指纹已固定；若官方更换密钥，安装会拒绝并提示，需从官方渠道独立核实后升级管理器。 |
| 使用限制 | 审计日志保留最近 20 个封存段（约 10 万条），更早的段会被清理；损坏只警告，隔离修复前新操作不能写入该链。 |
| 兼容边界 | 旧版已经清理的审计尾段没有保留边界证据，仍会提示无法核实；不能事后证明为何缺失。新版格式 4 的轮转日志不能由旧管理器读取，回退不会转换审计格式。 |
| 恢复边界 | 缺失审计记录不能靠 repair 重建；需恢复相符的私有备份。修复隔离的封存段不自动清理，保留证据也会占用磁盘。 |
| 使用限制 | BBR 原设置无法恢复时会保留记录并返回失败；菜单 27 可重试，但不能保证内核接受原参数，需人工排查。 |
| 使用限制 | 公网检测源全部不可达且网卡无公网地址时，需要管理员用 `sbm security public-ip add` 确认地址；确认列表只用于节点地址核对。 |
| 工具边界 | 隐私规则不能识别任意未知账号、少见域名或内部名称；正式发布必须结合非空私有精确匹配清单与人工复核。完整历史 / Release 下载审计尚未接入自动 CI。 |

本机公网地址快照只在应用配置时刷新；地址改变后需要重新应用。私网 / 回环 / 链路本地拒绝仍有效。当前策略拒绝 NAT64、6to4、Teredo 等转换前缀，相关网络可能受影响。

首次引导器依赖 GitHub HTTPS，必须独立建立首次信任。菜单 18 是配置与运行版本备份，不是整机备份，ACME 缓存不随恢复回退。旧外部缓存的清理申请不代表已经全部删除。

v3.6.1 本地已修复本轮四项边界：审计轮转并发误删、缺段误报正常清理、BBR 恢复失败丢记录并报成功，以及公网检测接受组播。审计追加只校验当前段；完整保留历史需运行 `sbm audit`。独立锁要求所有并发写入者使用新版，不能保证与绕过该锁的旧版独立引擎混写。处理方法见[手册第 17 节](USER_GUIDE.zh-CN.md#17-v361-边界修复与故障处理)。BBR 仍只用替身验证；本版未连接或部署 VPS；签名及发布验收另见 Release 正文。

v3.6.0 已修复：BBR 原设置恢复、APT 公钥指纹固定、审计日志分段轮转、公网地址多源检测与管理员确认。BBR 使用替身验证，未在真实内核上切换。v3.5.9 已修复：连接中途断开导致的静默截断不再绕过重试，元数据解析错误提示更明确。v3.5.8 已修复：failed 且无主进程的停止误报、dig 失败的原始错误、.object-* 暂存遗留、根目录旧校验文件，以及 GitHub 读取重试不统一。failed 状态停止使用替身验证，尚未在真实 systemd 主机复现。v3.5.7 处理了最低环境诊断、公开记录引用、Git 跟踪、严格隐私清单、安装器死代码及 SSH 上传降级。上表其他事项未声称已修复。

## English

Reviewed for v3.6.1. The four boundary defects found in v3.6.0 are fixed: audit rotation races, missing retained segments reported as pruning, lost BBR recovery records/false success, and acceptance of multicast addresses. Usage limits: BBR is host-wide while enabled (v3.6.0 restores recorded settings; hosts enabled by older versions fall back to cubic); a rotated SagerNet APT key is refused until verified and pinned in a manager update; only the newest 20 audit segments are retained; hosts without reachable detection sources or interface public addresses need `sbm security public-ip add`.

Legacy audit gaps cannot be retrospectively proven as retention; they are explicitly reported as unverified. Older managers cannot parse format 4 rotation headers, and rollback does not convert the logs. All concurrent writers must honor the stable lock; mixed old independent backends are not protected. Appends check only the current segment; `sbm audit` checks retained history. Missing records require matching backup material; repair cannot recreate them. Repair evidence is retained outside automatic cleanup and uses disk space. BBR recovery keeps the saved record on failure but cannot force a kernel to accept settings; menu 27 offers retries. See [guide section 17](USER_GUIDE.en.md#17-v361-boundary-fixes-and-recovery). BBR uses a sysctl double; this patch has not been connected/deployed to a VPS. Signing and publication verification are recorded in the Release notes.

Privacy patterns cannot identify arbitrary unknown accounts or internal names. Maintainer publication requires a non-empty private exact-match list and human review; full history/Release collection and auditing are not automated CI. Local public-address snapshots require reapplication after address changes. Transition prefixes such as NAT64/6to4/Teredo are denied. Establish initial bootstrap trust independently. Menu 18 is a configuration/runtime backup, not a whole-machine backup; ACME cache is not rolled back. An external-cache removal request does not prove deletion.

v3.6.0 restores recorded BBR settings, pins the APT key fingerprint, rotates the audit log and adds multi-source public-address detection with operator confirmation (BBR verified with a sysctl double, not a live kernel). v3.5.9 makes truncated responses (early EOF against a declared Content-Length) retryable and reports malformed metadata clearly. v3.5.8 fixes the failed-but-exited stop false negative, raw dig errors, leftover .object-* staging directories, the stale root checksum sidecar and non-uniform GitHub retries. The failed-state stop is verified with a systemctl double, not yet on a live systemd host. v3.5.7 addressed dependency diagnostics, public evidence references, Git tracking, strict privacy prerequisites, installer dead code and local-upload downgrade checks. The remaining items above are not claimed fixed.
