# 版本发布规范 / Release procedure

每个版本必须同步本地源码、GitHub 默认分支、版本标签和正式 Release。Packages 不属于当前分发渠道。正式安装和升级读取最新稳定 Release，不读取 main。

## 发布步骤

1. 更新版本、中英文文档、公开验证摘要。执行适用的回归、真实连接与隐私检查；原始证据只在私有目录。
2. `python3 tools/build.py` 生成管理器、摘要、install.py、install.sh 和短命令。安装器模板在 src/bootstrap/install.py；固定公钥验证器在 src/sbm/core/release_trust.py，构建时内嵌进安装入口。
3. `python3 tools/prepare_github.py --require-private --output .cache/publish.json` 生成白名单；`python3 tools/privacy_guard.py --require-private .cache/publish.json` 复核。源码包与 GitHub 必须使用同一清单。
4. `python3 tools/package.py --require-private` 生成完整源码包及 dist/release-v<版本>/。重复构建须产生相同脚本与归档摘要。
5. 用维护者私有 Ed25519 密钥签名：
   `python3 tools/sign_release.py --key /private/path/release_ed25519 --directory dist/release-v<版本>`
   工具核对公钥与固定值相同，并验证签名及所有附件。私钥权限 600，永不进入仓库、附件、VPS、日志。首次公钥建立或更换必须独立确认信任；在仓库中替换公钥不能自行证明可信。
6. 在核对的提交创建标签 `v<版本>`。Release 标签和标题仅版本号。双语正文写变更、验证、升级入口和限制。先准备全部附件和签名，再发布，不留不完整的正式版本。
7. 上传八个附件：完整源码 .tar.gz、singbox-manager.sh、singbox-manager.sha256、install.py、install.sh、RELEASE_SIGNING.pub、SHA256SUMS、SHA256SUMS.sig。签名覆盖清单，清单覆盖六个载荷并绑定版本标签。公钥附件仅供核对，验证以已有固定公钥为准。
8. 匿名下载全部附件、自动 Source code 下载并验证签名、摘要、文件清单、标签与源码字节一致。核对 releases/latest 和默认分支。可先发布标签及 Release，再同步 main，避免旧版 main 升级器提前安装未发布变更。

## 隐私门禁

`tools/privacy_guard.py` 检查公网地址、硬编码 SSH 端口、部署主机名、非官方 URL / 常见裸域名、凭据和解码后的 Python ZIP。诊断仅显示路径、行号和类别，不回显敏感值。少见后缀、内部主机和任意账号不可能靠正则完全识别，必须结合私有标识列表与人工检查。

在不公开的 `.cache/private-identifiers.json` 保存真实环境标识用于精确匹配。只能发布 reports/PUBLIC_VALIDATION.md。禁止原始部署报告、真实地址、SSH 端口、用户名、节点域名、密码、令牌、证书私钥、缓存、整机备份。

正式发布必须使用 `--require-private`：清单缺失、为空或无效即失败。第三方源码副本不带该私有文件；普通构建 / 通用扫描仍可运行，但会警告精确匹配未启用，不代表完成维护者发布检查。不要为了通过检查在新副本创建空清单。`tools/audit_publication.py` 同样支持 `--require-private`，历史及 Release 检查也必须开启。

发布必须检查可达 Git 历史与所有 refs、Release 正文、附件及自动生成源码下载。清理 main 不等于清除旧提交、第三方下载或外部缓存；发现历史暴露需另行申请缓存清理，不能宣称自动消失。

## 服务器边界

部署前核对明确授权目标、管理锁与待恢复标记，保存完整备份并验证摘要。管理器自升级不改节点、不重启 sing-box，不控制 3X-UI / Xray。配置策略迁移单独走事务；故障注入优先用隔离实例。记录前后配置摘要、进程和实际连接，只公布脱敏结果。

## English

Synchronize local source, GitHub main, version tag and a formal Release for every version. Install/update defaults to the latest stable Release, never unpublished main.

Build with tools/build.py, run relevant regression and connection tests, prepare the allowlisted source using tools/prepare_github.py --require-private, then package with tools/package.py --require-private. Require reproducible manager/archive checksums. The installer template is src/bootstrap/install.py; the shared pinned-key verifier is embedded during the build.

Sign the staged SHA256SUMS using tools/sign_release.py with an explicitly supplied private Ed25519 key. The tool requires the matching pinned public key and verifies the results. Keep the private key mode 600 and outside source, downloads, logs and VPS deployment. Establish or rotate trust independently.

Use only v<version> for the tag/title, with bilingual notes in the body. Publish eight assets: full source archive, manager, manager checksum, install.py, install.sh, public key, SHA256SUMS and SHA256SUMS.sig. The signed manifest binds the version and six payloads. Verify against the already trusted key, not an untrusted newly downloaded replacement.

Read back every asset anonymously; verify signatures, hashes, generated source downloads, exact tag contents and main consistency. Prepare/upload a complete draft before publishing; publishing the tag/Release before advancing main avoids early installation by legacy branch-based updaters.

Privacy checks cover allowlisted source and decoded bundles, public addresses, SSH ports, hostnames, URLs, common bare domains and credentials. Diagnostics never echo values. Combine these checks with the unpublished private identifier list and review of uncommon/internal names. Inspect all reachable history/refs, release notes, assets and generated downloads. Editing main cannot erase prior downloads or external caches.

Back up and validate only the explicitly authorized practice server before deployment. Separate manager updates from runtime/configuration transactions. Preserve 3X-UI/Xray and publish only sanitized validation summaries; retain raw evidence privately.


Maintainer publication, standalone privacy checks and history/Release auditing must use `--require-private`. A missing, empty or invalid unpublished identifier list is a failure. Ordinary third-party copies without this list warn and can run generic scans; that is not equivalent to the maintainer release gate. Never publish the list or create an empty list merely to pass the gate.
