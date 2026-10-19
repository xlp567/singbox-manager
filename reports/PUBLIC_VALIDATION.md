# 公开验证摘要 / Public validation summary

原始部署日志、真实服务器地址、SSH 端口、主机名、节点域名、凭据与备份位置不进入公开仓库或下载包。历史实机验证只保留能力与结果摘要；原始证据在维护者私有目录保存。

| 版本 / Version | 验证范围 / Validation | 结果 / Result |
|---|---|---|
| 3.5.1 | macOS / Debian 自动化回归；九协议、草稿清理、SSH 管理器更新 / regression, nine protocols, drafts, manager updates | 当时回归各 144 项通过；练手环境验证通过 / 144 tests per platform and authorized practice checks passed |
| 3.5.2 | 官方版本查询失败处理 / official release query failures | 当时回归各 158 项通过 / 158 tests per platform passed |
| 3.5.3 | 私有 GitHub 首次安装与已有安装保护 / private bootstrap and existing installation protection | 当时回归各 174 项通过 / 174 tests per platform passed |
| 3.5.4 | 公开源匿名安装、管理器升级与节点连接 / anonymous bootstrap, manager update and transfers | 当时回归各 186 项通过，练手验证通过 / 186 tests per platform and authorized practice checks passed |

历史实机结果不代表后续版本已部署。v3.5.5 本次仅本地隔离验证，没有连接 VPS，没有重启服务或修改节点配置。

Raw deployment logs and private infrastructure identifiers are excluded from public source and downloads. Historical live checks do not imply that later versions have been deployed. This v3.5.5 change is being verified locally with isolated service doubles; no VPS is contacted.

v3.5.5：macOS 完整验证 208/208 通过；Bash 语法、ShellCheck、分发摘要通过。包含新增 10 项服务入口 / 事务回归和 12 项发布隐私回归。

v3.5.5: 208/208 local macOS tests passed, plus Bash syntax, ShellCheck and distribution checksums. Added 10 service-entry/transaction cases and 12 publication-privacy cases.
