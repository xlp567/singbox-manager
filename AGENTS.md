# Repository maintenance instructions

- 每次发布新版本，必须同步本地源码、GitHub 默认分支与正式 GitHub Release；仅提交源码不算完成发布。
- 安装 / 升级只跟踪正式稳定 Release；发布需使用固定公钥对应私钥签署 SHA256SUMS，并上传签名和安装入口。私钥不得进入仓库、下载包、日志或 VPS；确认前不得执行候选脚本。
- Release 的标签和标题都只使用 `v<版本号>`（例如 `v3.5.4`），标题不添加宣传语或双语副标题；中英文更新说明放在正文，并附完整源码包、独立 `singbox-manager.sh`、配套 `singbox-manager.sha256` 和 `SHA256SUMS`。
- 发布前执行与变更相关的检查；发布后匿名读回附件并核对版本、标签提交、文件清单和 SHA-256。具体步骤见 `RELEASING.md`。
- GitHub 发布与服务器部署分别记录。服务器操作仅限用户明确授权的练手 VPS；不得修改其他生产 VPS，不得影响 3X-UI / Xray。
- 管理脚本升级与 sing-box Runtime 升级分开；管理器自升级不得重启代理服务或修改节点配置。
- 不得上传服务器配置、节点凭据、令牌、私钥、缓存或整机备份。源码包与 GitHub 源码使用同一份发布白名单。
- 真实 VPS 地址、SSH 端口、主机名、节点域名、登录信息及原始部署日志也属于私有信息；示例仅使用保留文档地址与 example.com。发布前运行 `tools/prepare_github.py` 的隐私门禁，包含解码后的内嵌引擎检查；不能仅依赖 GitHub Secret scanning。
- 原始实机验收记录只在私有工作目录保留；公开材料使用 `reports/PUBLIC_VALIDATION.md`。发现公开泄露时必须同时核对历史提交、标签、Release 正文及附件，不能仅修改 main 后宣称已清除历史。

For every version, synchronize local source, GitHub source and a tagged GitHub Release with bilingual notes, downloadable artifacts and checksums. Follow `RELEASING.md`; preserve the service boundaries above.
