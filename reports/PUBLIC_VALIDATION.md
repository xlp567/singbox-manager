# 公开验证摘要 / Public validation summary

原始部署日志、真实服务器地址、SSH 端口、主机名、节点域名、凭据与备份位置不进入公开仓库或下载包。历史实机验证只保留能力与结果摘要；原始证据在维护者私有目录保存。

| 版本 / Version | 验证范围 / Validation | 结果 / Result |
|---|---|---|
| 3.5.1 | macOS / Debian 自动化回归；九协议、草稿清理、SSH 管理器更新 / regression, nine protocols, drafts, manager updates | 当时回归各 144 项通过；练手环境验证通过 / 144 tests per platform and authorized practice checks passed |
| 3.5.2 | 官方版本查询失败处理 / official release query failures | 当时回归各 158 项通过 / 158 tests per platform passed |
| 3.5.3 | 私有 GitHub 首次安装与已有安装保护 / private bootstrap and existing installation protection | 当时回归各 174 项通过 / 174 tests per platform passed |
| 3.5.4 | 公开源匿名安装、管理器升级与节点连接 / anonymous bootstrap, manager update and transfers | 当时回归各 186 项通过，练手验证通过 / 186 tests per platform and authorized practice checks passed |


本附件为 v3.5.4 文档与隐私清理后的源码快照，保留 v3.5.4 管理行为。Base64 和源码构建说明已同步；菜单 16 的功能修复在 v3.5.5 发布。没有连接 VPS。

This refreshed v3.5.4 source snapshot includes documentation and privacy cleanup while preserving v3.5.4 manager behavior. The menu 16 fix ships in v3.5.5. No VPS was contacted.

文档与隐私清理快照：本地 198/198 自动化测试通过；Bash / ShellCheck / 分发摘要通过。

Refreshed snapshot: 198/198 local tests, Bash syntax, ShellCheck and distribution checksums passed.
