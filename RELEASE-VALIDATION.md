# 0.36 更新验证记录

日期：2026-09-28。发布类型：**未公证测试版，不是正式公开版**。

- 源提交：`a72b6c4`。
- appcast 提交：`a2a5f0f60cf78efcbff60594405755962ead89d8`。
- [GitHub 预发布版 v0.36](https://github.com/Tianbaidi/Notch-Balls-Prototype/releases/tag/v0.36)。
- 包：`Notch-Balls-Prototype-0.36-macOS-arm64.zip`，7,983,664 字节。
- SHA-256：`2925230646f6a8bcbf7e48a014fc0791a0e8ccdd56d58474df1d63814624ce62`。

## 已实测

- 原始安装为 0.35 / build 35，arm64，ad-hoc 签名；更新地址为仓库 main/appcast.xml。
- 原 0.35 应用已本地备份，未提交备份或任何用户数据。
- 新版本 0.36 / build 36 完成 Swift 编译；Mach-O 的实际最低系统版本为 14.0。
- Sparkle 内部组件逐层签名，打包后解压的应用通过 `codesign --verify --deep --strict`。
- Keychain 公钥与已安装 0.35、UpdateConfig.plist 公钥一致；私钥未导出。
- 签名包使用已安装 0.35 公钥独立验证通过；向包追加字节后验证失败。
- ZIP 仅包含应用，framework 符号链接保留，未发现用户数据库、钥匙串、证书文件。
- 6 项发布规则单元测试通过，包括版本不递增拒绝、旧条目保留及测试版禁止旧版本静默安装。
- stable 模式缺少 Developer ID 时提前拒绝；同一版本 prepare 再次执行拒绝覆盖原包。
- GitHub v0.36 是可匿名下载的 prerelease；v0.35 草稿保留。
- 发布脚本在匿名下载并验证附件后才写入 appcast。
- 对相同 manifest 再次执行 publish 成功：远端原附件逐一比对通过，未覆盖附件、未新增清单提交。
- 使用真实 SUFeedURL（无替代测试地址）匿名读取线上清单并下载包，版本 36、长度、签名和 SHA-256 全部匹配。
- Gatekeeper 评估测试应用返回 `rejected`；没有关闭安全设置，也没有删除隔离属性。

## 待完成的应用内验证

原版 0.35 菜单触发检查、Sparkle 下载及安装、自动重启、安装后版本和再次检查更新尚待实际操作验证。
当前界面工具没有暴露该应用的菜单栏入口；等待用户选择辅助功能脚本或手动操作。
仅下载成功和签名通过不能视作完整端到端安装通过。

## Developer ID 与公证限制

本机代码签名身份数为 0。正式流程包含 Developer ID Application、Hardened Runtime、时间戳、
notarytool、staple 以及 Gatekeeper 检查，但这一分支尚未在有证书环境下成功实测。
测试版的 Sparkle 签名只验证更新包来源和完整性，不能替代 Apple Developer ID 和公证。
macOS 14/15/26 实机运行兼容性也未验证；已验证的是编译目标和清单一致性。
