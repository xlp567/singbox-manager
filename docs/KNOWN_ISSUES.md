# 已知问题与限制 / Known issues and limits

核对版本：v3.5.7。此清单区分未修复行为、待复现疑点与使用限制；测试通过不代表问题清零。公开记录不包含测试环境标识。

| 状态 | 未完成项及影响 |
|---|---|
| 未修复 | BBR 关闭时写 cubic，未保存、恢复原拥塞算法与 qdisc。菜单 27 修改整机 TCP 参数，可能影响同机其他 TCP 服务的性能。 |
| 未修复 | SagerNet APT 公钥通过官方 HTTPS 获取，但未固定指纹。管理器 Release 签名不替代 APT 密钥的来源校验。 |
| 未优化 | 每次审计追加校验整条链，未做正常轮转；长期高频操作可能变慢、增加磁盘占用。损坏只警告，隔离修复前新操作不能写入该链。 |
| 未修复 | 公网检测依赖 ipify；不可达、多公网 IP 或 NAT 可能阻挡配置提交，现有服务不会因此自动停止。 |
| 未修复 | 管理器自升级不更新根目录的旧 singbox-manager.sha256；手工校验可能误报。升级暂存区仍执行签名及摘要验证。 |
| 清理遗漏；中断时点待专项复现 | 首次创建运行对象时，断电 / SIGKILL 可能留下 .object-* 目录；现有运行对象垃圾回收跳过这些名称。 |
| 未统一 | GitHub 自升级请求和附件读取尚未统一自动重试；瞬时错误会结束本次升级，校验失败不会安装。 |
| 待实机复现 | 停止已经 failed 的服务只接受 inactive / MainPID=0；若停止后仍为 failed 且无进程，可能误报失败并进入恢复流程。 |
| 工具边界 | 隐私规则不能识别任意未知账号、少见域名或内部名称；正式发布必须结合非空私有精确匹配清单与人工复核。完整历史 / Release 下载审计尚未接入自动 CI。 |

本机公网地址快照只在应用配置时刷新；地址改变后需要重新应用。私网 / 回环 / 链路本地拒绝仍有效。当前策略拒绝 NAT64、6to4、Teredo 等转换前缀，相关网络可能受影响。

首次引导器依赖 GitHub HTTPS，必须独立建立首次信任。菜单 18 是配置与运行版本备份，不是整机备份，ACME 缓存不随恢复回退。旧外部缓存的清理申请不代表已经全部删除。

v3.5.7 本次处理最低环境诊断、公开记录引用、Git 跟踪回归、严格隐私清单前置条件、安装器死代码及 SSH 上传降级；上述其他事项未声称已修复。旧安装器的错误提示已改为区分公开仓库网络错误与私有仓库权限。

## English

Reviewed for v3.5.7. Outstanding behaviors: BBR does not restore the original host-wide TCP settings; the APT key fingerprint is not pinned; audit appends still verify the entire growing chain without normal rotation; public-address checks depend on ipify; manager updates do not refresh the old root-level checksum sidecar; hard interruption during initial runtime-object copying can leave .object-* directories that GC skips; update/asset requests lack uniform retry handling. A failed-state stop false negative remains unverified on a live host.

Privacy patterns cannot identify arbitrary unknown accounts or internal names. Maintainer publication requires a non-empty private exact-match list and human review; full history/Release collection and auditing are not automated CI. Local public-address snapshots require reapplication after address changes. Transition prefixes such as NAT64/6to4/Teredo are denied. Establish initial bootstrap trust independently. Menu 18 is a configuration/runtime backup, not a whole-machine backup; ACME cache is not rolled back. An external-cache removal request does not prove deletion.

This patch addresses dependency diagnostics, public evidence references, Git tracking coverage, strict privacy prerequisites, installer dead code and local-upload downgrade checks. It does not claim to fix the separate outstanding items above.
