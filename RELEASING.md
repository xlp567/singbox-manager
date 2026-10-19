# 版本发布规范 / Release procedure

每个新版本都必须完成源码同步和正式 GitHub Release。Packages 不是本项目当前的分发渠道；正式下载附件放在 Releases。

## 发布步骤

1. 更新 `SBM_VERSION`、版本说明及中英文文档，执行适用的自动化回归和分发检查。管理器发布与 sing-box 核心发布分别处理。
2. 使用 `tools/prepare_github.py` 的白名单同步本地和 GitHub 源码。禁止包含 VPS 配置、凭据、证书私钥、缓存和整机备份。
3. 运行 `python3 tools/package.py`，生成 `dist/singbox-manager-v<版本>.tar.gz` 与 `dist/SHA256SUMS`。源码包只包含已发布文件；重复构建应产生相同摘要。
4. 在已核对的提交上创建 `v<版本>` 标签；Release 标题也只填写同一个版本号（例如 `v3.5.4`），不加描述性副标题。中英文更新说明、安装 / 升级入口、适用系统、验证结果及已知限制放在正文。
5. 上传四个附件：完整源码包、`singbox-manager.sh`、`singbox-manager.sha256`、`SHA256SUMS`。校验文件应与本次附件匹配。
6. 发布后通过匿名下载核对全部附件及标签提交；确认 Release 页面可见，并把发布地址和验证结果告知用户。

### 隐私门禁

发布清单和源码包共用 `tools/privacy_guard.py`。仅保留源码、示例和公开验证摘要，原始服务器报告不随包发布；示例使用保留文档地址或 example.com。门禁检查公网地址、硬编码 SSH 端口、部署主机名、非官方 URL 主机、私钥、令牌及解码后的 Python ZIP。报告仅显示文件路径、行号、问题类别，不能回显敏感值。

本地可在不公开的 `.cache/private-identifiers.json` 中设置额外的字符串数组，用于比对私有域名、登录标识及其 Base64；该文件不得提交。门禁不能替代人工审查。发现已发布的信息时，必须检查 main、所有分支 / 标签 / 历史提交、Release 正文、附件及自动生成的 Source code 下载，另行处理旧副本。清理当前提交不会抹去历史、他人下载或外部缓存。

若涉及练手 VPS 部署，必须先核对目标和管理锁、完成可验证备份，记录升级前后的配置 / 运行文件摘要、服务进程与节点连接结果。管理器升级不重启 sing-box，不控制 3X-UI 或 Xray；未经用户授权不连接其他 VPS。

## English

Every version must synchronize local source, GitHub source and a tagged GitHub Release. Release attachments are the distribution channel; GitHub Packages is currently unnecessary.

1. Update the version and bilingual documentation, then run checks appropriate to the change. Keep manager releases separate from sing-box runtime releases.
2. Publish only the allowlisted source from `tools/prepare_github.py`. Exclude server state, credentials, private keys, caches and machine backups.
3. Run `python3 tools/package.py`. The archive must match the published source and produce the same checksum on repeated builds.
4. Create `v<version>` on the verified commit. Use only that version string as the release title (for example, `v3.5.4`), without a descriptive subtitle. Put Chinese and English notes, installation/update instructions, supported systems, validation and limitations in the body.
5. Attach the source archive, standalone manager, companion manager checksum and `SHA256SUMS`.
6. Download every attachment anonymously and verify checksums and tag identity. Report the published URL and validation result.

### Privacy gate

The source manifest and archive share `tools/privacy_guard.py`. Publish source, examples and the public validation summary; exclude raw server reports. The gate checks public addresses, literal SSH ports, deployment hostnames, unreviewed URL hosts, credentials and decoded Python ZIP bundles. Diagnostics show only path, line and category.

An unpublished `.cache/private-identifiers.json` string array can add private identifiers and Base64 comparisons. Never commit it. Automated checks require human review. Existing exposure requires inspecting all refs and history, release notes, assets and generated source downloads. Editing main cannot erase historical copies, third-party downloads or external caches.

Server deployment requires an explicitly authorized target, an idle management lock and a verified backup. Compare process identities, protected files and actual node connections before and after. Updating the manager must not restart sing-box or change 3X-UI / Xray.
