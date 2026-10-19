# Changelog / 更新记录

## 3.5.6 — 2026-10-20

- 所有协议统一加入出口保护，拒绝本机、私网、链路本地和元数据访问；域名解析后再次检查，失败时拒绝。新增菜单 31 / security CLI，以及精确识别旧模板的事务迁移。
- 审计写入失败只警告；新增 audit repair，隔离原损坏文件并将摘要及最后有效哈希续接到新链。
- 运行文件快照按摘要去重、硬链接复用；跨文件系统回退复制；自动保留最近 10 份自动快照，手动 / 旧版 / 待恢复备份保留，旧核心清理不影响恢复。
- 安装 / 自升级改为最新正式 Release、固定 Ed25519 公钥签名及版本绑定清单；确认前静态校验，不执行候选脚本。源码包同步安装入口、公钥、签名和中英文说明。
- 隐私检查增加常见裸域名识别，以及可达 Git 历史、Release 正文和下载包的只读检查工具；原始测试环境信息仅保存在私有目录。

- Apply shared egress protection across protocols, resolving domains before rejecting private/local/metadata destinations. Add menu 31 / security CLI and exact legacy-template migration through normal transactions.
- Audit-write failures warn; audit repair preserves the corrupt original and links its digest and last valid hash into a new chain.
- Deduplicate runtime backup objects with portable snapshot hard links and cross-filesystem copy fallback. Retain 10 automatic snapshots; preserve manual/legacy/pending backups and restore after runtime pruning.
- Install/update only from the latest formal Release, with pinned Ed25519 signatures, tag-bound manifests and static checks before consent. Include signed bootstrap assets and bilingual documentation.
- Extend privacy review to common bare domains and provide a read-only history/release audit tool. Keep all raw environment identifiers and evidence private.

## 3.5.5 — 2026-10-20

- 菜单 16 接入与 15 / 17 相同的服务事务入口：快照、停止状态与主进程检查、失败 / 中断回滚、审计。
- 停止服务不依赖可用配置或运行程序；启动 / 重启继续执行兼容性、配置与运行健康检查。
- 清理源码中残留的部署标识，验收脚本改用私有目标标记与显式进程基线；原始实机报告从发布清单移除。
- 源码发布和打包增加隐私门禁，扫描地址、SSH 端口、凭据和解码后的 Python 引擎；补充中英文说明和回归测试。

- Menu 16 now shares transactional service control with 15 / 17, including snapshots, stopped-state / PID checks, audit and rollback after failure or interruption.
- Stopping works even with invalid configuration or a missing runtime. Start and restart retain validation and running-health checks.
- Remove deployment identifiers from source, parameterize acceptance guards and exclude raw live-server reports from publication.
- Add shared source/package privacy checks, decoded-engine scanning, bilingual documentation and regression coverage.

## 3.5.4 — 2026-10-20

- 公开发布准备：MIT 许可证、中英文介绍与完整操作手册。
- 新增 `install.sh`，公开仓库支持短命令安装，无需 GitHub 令牌。
- 管理器升级优先匿名读取公开仓库；旧版遗留令牌不再阻挡公开读取，私有仓库仍可回退只读凭据。
- 保留 27 项原有菜单、九种协议、v2.4 配置兼容、校验、备份与恢复。

- Public distribution: MIT license, Chinese/English READMEs and user guides.
- Short `install.sh` bootstrap without GitHub credentials for the public repository.
- Public-first manager updates, with read-only credential fallback for private repositories.
- Existing menu numbers, nine protocols, legacy configuration compatibility and recovery remain supported.

## 3.5.3 — 2026-10-20

首次 GitHub 安装入口、固定提交下载、隐藏令牌、既有管理器保护；随后补充单行私有安装入口。

Initial GitHub bootstrap with pinned downloads, hidden credentials, existing-manager protection and a private one-line entry.

## 3.5.2 — 2026-10-19

官方版本查询小分页、稳定版备用接口、有限重试；查询失败不再把旧记录显示为最新。

Smaller official release queries, an independent stable endpoint, bounded retries, and honest cached-status reporting.

## 3.5.1 / 3.5 / 3.0

历史功能与验证记录见 [测试与部署结果](测试与部署结果.md)。

See the [historical validation records](测试与部署结果.md) for earlier versions.
