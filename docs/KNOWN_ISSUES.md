# 已知问题与限制 / Known issues and limits

核对版本：v3.6.0。此清单区分未修复行为、待复现疑点与使用限制；测试通过不代表问题清零。公开记录不包含测试环境标识。

| 状态 | 未完成项及影响 |
|---|---|
| 使用限制 | 菜单 27 的 BBR 是整机 TCP 参数，开启期间影响同机其他 TCP 服务；v3.6.0 起关闭时恢复开启前记录的设置，旧版开启的主机无记录时回退为 cubic。 |
| 使用限制 | SagerNet APT 公钥指纹已固定；若官方更换密钥，安装会拒绝并提示，需从官方渠道独立核实后升级管理器。 |
| 使用限制 | 审计日志保留最近 20 个封存段（约 10 万条），更早的段会被清理；损坏只警告，隔离修复前新操作不能写入该链。 |
| 使用限制 | 公网检测源全部不可达且网卡无公网地址时，需要管理员用 `sbm security public-ip add` 确认地址；确认列表只用于节点地址核对。 |
| 工具边界 | 隐私规则不能识别任意未知账号、少见域名或内部名称；正式发布必须结合非空私有精确匹配清单与人工复核。完整历史 / Release 下载审计尚未接入自动 CI。 |

本机公网地址快照只在应用配置时刷新；地址改变后需要重新应用。私网 / 回环 / 链路本地拒绝仍有效。当前策略拒绝 NAT64、6to4、Teredo 等转换前缀，相关网络可能受影响。

首次引导器依赖 GitHub HTTPS，必须独立建立首次信任。菜单 18 是配置与运行版本备份，不是整机备份，ACME 缓存不随恢复回退。旧外部缓存的清理申请不代表已经全部删除。

v3.6.0 已修复：BBR 原设置恢复、APT 公钥指纹固定、审计日志分段轮转、公网地址多源检测与管理员确认。BBR 使用替身验证，未在真实内核上切换。v3.5.9 已修复：连接中途断开导致的静默截断不再绕过重试，元数据解析错误提示更明确。v3.5.8 已修复：failed 且无主进程的停止误报、dig 失败的原始错误、.object-* 暂存遗留、根目录旧校验文件，以及 GitHub 读取重试不统一。failed 状态停止使用替身验证，尚未在真实 systemd 主机复现。v3.5.7 处理了最低环境诊断、公开记录引用、Git 跟踪、严格隐私清单、安装器死代码及 SSH 上传降级。上表其他事项未声称已修复。

## English

Reviewed for v3.6.0. No outstanding defects from earlier reviews remain open. Usage limits: BBR is host-wide while enabled (v3.6.0 restores the recorded settings; hosts enabled by older versions fall back to cubic); a rotated SagerNet APT key is refused until verified and pinned in a manager update; only the newest 20 audit segments are retained; hosts without reachable detection sources or interface public addresses need `sbm security public-ip add`.

Privacy patterns cannot identify arbitrary unknown accounts or internal names. Maintainer publication requires a non-empty private exact-match list and human review; full history/Release collection and auditing are not automated CI. Local public-address snapshots require reapplication after address changes. Transition prefixes such as NAT64/6to4/Teredo are denied. Establish initial bootstrap trust independently. Menu 18 is a configuration/runtime backup, not a whole-machine backup; ACME cache is not rolled back. An external-cache removal request does not prove deletion.

v3.6.0 restores recorded BBR settings, pins the APT key fingerprint, rotates the audit log and adds multi-source public-address detection with operator confirmation (BBR verified with a sysctl double, not a live kernel). v3.5.9 makes truncated responses (early EOF against a declared Content-Length) retryable and reports malformed metadata clearly. v3.5.8 fixes the failed-but-exited stop false negative, raw dig errors, leftover .object-* staging directories, the stale root checksum sidecar and non-uniform GitHub retries. The failed-state stop is verified with a systemctl double, not yet on a live systemd host. v3.5.7 addressed dependency diagnostics, public evidence references, Git tracking, strict privacy prerequisites, installer dead code and local-upload downgrade checks. The remaining items above are not claimed fixed.
