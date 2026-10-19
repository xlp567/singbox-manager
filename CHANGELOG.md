# Changelog / 更新记录

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
