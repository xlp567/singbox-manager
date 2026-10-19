# Repository maintenance instructions

- 每次发布新版本，必须同步本地源码、GitHub 默认分支与正式 GitHub Release；仅提交源码不算完成发布。
- Release 使用 `v<版本号>` 标签，附中英文更新说明、完整源码包、独立 `singbox-manager.sh`、配套 `singbox-manager.sha256` 和 `SHA256SUMS`。
- 发布前执行与变更相关的检查；发布后匿名读回附件并核对版本、标签提交、文件清单和 SHA-256。具体步骤见 `RELEASING.md`。
- GitHub 发布与服务器部署分别记录。服务器操作仅限用户明确授权的练手 VPS；不得修改其他生产 VPS，不得影响 3X-UI / Xray。
- 管理脚本升级与 sing-box Runtime 升级分开；管理器自升级不得重启代理服务或修改节点配置。
- 不得上传服务器配置、节点凭据、令牌、私钥、缓存或整机备份。源码包与 GitHub 源码使用同一份发布白名单。

For every version, synchronize local source, GitHub source and a tagged GitHub Release with bilingual notes, downloadable artifacts and checksums. Follow `RELEASING.md`; preserve the service boundaries above.
