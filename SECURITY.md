# 安全政策 / Security policy

## 支持的版本

安全修复优先针对 [Releases](https://github.com/xlp567/singbox-manager/releases/latest) 中最新的稳定管理器版本。使用旧版本时，请先确认问题是否仍存在于最新稳定版；不承诺为所有历史版本单独维护安全补丁。

本政策适用于 singbox-manager 管理脚本、安装 / 升级入口和协议适配代码。第三方 sing-box 核心及其他程序由各自的上游项目维护。

## 私密报告漏洞

请使用 GitHub 的 **Report a vulnerability** 私密报告入口：

[私密提交安全报告](https://github.com/xlp567/singbox-manager/security/advisories/new)

请提供：

- 管理器版本、sing-box 核心版本和操作系统。
- 漏洞影响、必要前提及可在自有或获授权测试环境重现的最小步骤。
- 脱敏日志、示例或修复建议。

请勿在公开 Issue、讨论或提交中附上可利用的未修复漏洞细节、服务器登录资料、节点密码、令牌、证书私钥或完整备份。一般功能问题和无敏感信息的使用故障可提交普通 Issue。

维护者会通过私密报告讨论验证、修复和公开披露。请在双方协调后再公开漏洞细节。

## Supported versions

Security fixes prioritize the latest stable manager release on [Releases](https://github.com/xlp567/singbox-manager/releases/latest). If you use an older version, check whether the issue still exists in the latest stable release. Separate security backports are not promised for every historical version.

This policy covers the manager, installation/update entry points and protocol adapters. Third-party sing-box runtime and other programs are maintained by their respective upstream projects.

## Reporting a vulnerability

Use GitHub's **Report a vulnerability** private reporting channel:

[Submit a private security report](https://github.com/xlp567/singbox-manager/security/advisories/new)

Include the manager/runtime versions, operating system, impact, prerequisites, minimal reproduction steps and sanitized evidence. Reproduce only in systems you own or are authorized to test.

Do not disclose exploitable, unfixed vulnerability details or attach server credentials, node passwords, tokens, private keys or full backups in public issues, discussions or commits. General feature requests and non-sensitive usage problems may use ordinary issues.

Maintainers will discuss validation, remediation and coordinated disclosure through the private report. Coordinate disclosure before publishing vulnerability details.
