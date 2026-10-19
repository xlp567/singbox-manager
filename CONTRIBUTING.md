# Contributing / 参与贡献

欢迎提交 Issue 或 Pull Request。请描述操作步骤、管理器版本、sing-box 版本、系统和经过脱敏的错误信息。不要提交令牌、私钥、节点密码、导出资料或真实配置。

Fork 仓库，在独立分支修改 `src/`，执行 `bash tools/test.sh`。分发脚本由 `tools/build.py` 生成，请把相关源码、生成文件、文档和有意义的回归测试一起提交。新协议应通过适配层接入；维护稳定管理核心、既有配置兼容和事务恢复边界。请说明验证是模拟测试、回环测试还是实际 VPS 验收。

Issues and pull requests are welcome. Include reproduction steps, manager/runtime versions, OS, and sanitized errors. Never submit tokens, private keys, node passwords, client exports, or live configurations.

Fork the repository, work on a separate branch, edit `src/`, and run `bash tools/test.sh`. `tools/build.py` generates the distribution: include the corresponding source, generated files, documentation and meaningful regression tests. Add protocols through the adapter layer and preserve configuration compatibility and transaction recovery. State whether validation used mocks, loopback traffic or an actual VPS.

Contributions are provided under the repository's [MIT license](LICENSE). Open an issue to discuss large changes before implementation.
