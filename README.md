# singbox-manager v3.5.2

Debian / Ubuntu 的中文 sing-box 多节点管理器。保留原有 27 项管理功能与九种协议，增加官方协议自动表单、草稿永久清理、文件目录速查，以及管理脚本的本地上传 / GitHub 升级和回退。

- SSH 菜单和 CLI 共用管理核心，协议模块独立，统一编译后交由 SagerNet 官方程序检查。
- 官方 Runtime 下载与 SHA-256 校验、完整快照、事务自动回滚和中断恢复。
- 核心升级后可扫描 `sing-box schema` 发现新协议，通过参数表单创建节点，无需填写 JSON。复杂新拓扑仍需要专用适配。
- 自升级只更新 `/root/singbox-manager.sh` 与 `/usr/local/bin/sbm`，不改变节点配置、不重启代理服务。
- 官方版本查询使用小分页及稳定版独立接口，处理 HTTP 504、超时和限流；失败时保留当前服务，并明确标记查询状态，不把旧缓存当作最新结果。

## 使用

将本仓库同一提交的 `singbox-manager.sh` 与 `singbox-manager.sha256` 上传到服务器 `/root`：

```bash
cd /root
sha256sum -c singbox-manager.sha256
bash singbox-manager.sh
```

安装快捷命令后执行 `sbm`。菜单 28 自动发现协议，22 管理 / 永久删除草稿，29 查看目录，30 升级管理脚本。菜单 10 负责 sing-box 核心版本升级。

私有 GitHub 仓库拉取需要只读访问令牌；通过菜单 30 → 4 配置，仅授权本仓库 `Contents: read`。令牌保存在服务器私有文件，不要提交到仓库或填写在命令行参数中。

详见 [使用说明](使用说明.md)、[文件目录](文件目录速查.md)、[升级操作](管理脚本升级.md)、[架构](架构与扩展.md)、[测试记录](测试与部署结果.md)。

## 开发验证

```bash
bash tools/test.sh
```

需要 Python 3、Bash、ShellCheck。测试在临时目录运行，systemd 用隔离替身；真实协议传输由单独测试工具验证。服务器配置、凭据、证书、运行程序下载缓存及整机备份不属于 GitHub 发布内容。
