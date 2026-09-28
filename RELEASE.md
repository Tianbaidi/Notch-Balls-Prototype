# 自动更新发布

发布在本机执行；Sparkle Ed25519 私钥只由 Sparkle 工具从登录钥匙串账户
`Notch-Balls-Prototype` 读取。不导出私钥，不把证书、令牌、用户偏好或应用数据库上传。
GitHub Actions 目前不负责签名，避免为构建方便把私钥搬到云端。

## 已安装 0.35 的约束

0.35 使用 Sparkle 2.10.0，固定读取 `main/appcast.xml`，公钥见 `UpdateConfig.plist`。
它没有 beta 通道代理，所以测试条目也必须进入默认清单才能被它发现。
GitHub 的 prerelease 标签不会影响 Sparkle；草稿附件不能匿名下载。
本流程把未公证构建标成 **GitHub prerelease、非 Latest**，清单标题和说明都写明测试性质，
并用 `minimumAutoupdateVersion` 要求旧版本先确认安装。默认清单对所有现有安装可见，
这不是只对本机生效的私密测试通道。

## 本地准备（不发布）

需要 macOS、包含 macOS 27 SDK 的 Xcode（源码使用可用性保护后的新 API）、Python 3.9+、gh。
构建目标固定为 Apple silicon / macOS 14.0+；旧系统运行兼容性仍需实际设备验证。
先提交审核过的源代码，工作树必须干净。版本号为数字，build 为严格递增的正整数。
根目录 Info.plist 保留 0.35/35 基线，发布版本由参数注入；不要直接编辑应用包内 plist。

```sh
python3 -m unittest discover -s tests -v
python3 scripts/release.py prepare --version 0.36 --build 36 --mode testing --notes releases/0.36.md
```

输出到被忽略的 `dist/v0.36/`：ZIP、SHA256SUMS、manifest.json、候选 appcast、发布说明。
构建只装入源码声明的应用资源，使用干净的临时目录；Sparkle 组件逐层签名。
ZIP 用 ditto 保留 framework 符号链接；签名之后不再改变 ZIP。
签名会用应用的公钥独立验证，再解包检查 bundle ID、版本、更新地址、代码签名。
相同输出目录存在时拒绝重新构建，防止同一版本对应不同字节；中断后使用 publish 重试。
“可重复执行”指固定流程和可恢复发布，不承诺不同 SDK/时间下字节完全可复现。

## 发布和重试

先将 prepare 使用的源提交推送到 main，然后：

```sh
git push origin main
python3 scripts/release.py publish dist/v0.36/manifest.json
python3 scripts/release.py verify-live --build 36
git pull --ff-only origin main
```

顺序：校验本地产物 → 验证源提交已在远程 main → 建立草稿 → 上传 ZIP/校验和 →
发布预发布版 → **匿名下载并验证实际附件** → 以旧 appcast blob SHA 为条件更新 main 清单。
先有可用附件再有清单，网络失败不会把无效下载链接写进清单。
重复 publish 会比对现有附件，绝不 `--clobber`；同名版本不允许换包。
远端清单并发变化会停止；不要强推或盲目覆盖，先同步、复核并重新准备新版本。
GitHub raw CDN 可能仍返回旧清单；等待缓存更新后重跑 verify-live，测试应用用真实地址。
0.35 的已有草稿不参与本流程，不自动公开或删除。

## 将来的正式版本

```sh
export CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARYTOOL_PROFILE='your-local-keychain-profile'
python3 scripts/release.py prepare --version 0.38 --build 38 --mode stable --notes releases/0.38.md
```

stable 必须使用 Developer ID Application 签名（含 Hardened Runtime 和时间戳），
提交 notarytool、staple、验证公证票据及 Gatekeeper，最后才打 ZIP 并做 Sparkle 签名。
publish 再次解包验证；任一步失败都不得发布正式版本。本机无证书时此分支会提前拒绝。
凭据用 `notarytool store-credentials` 存入本机钥匙串；不要写到脚本或提交到 Git。
取得证书后需重新实测完整流程，本次测试不能替代这一验证。

## 端到端测试和恢复

1. 备份 `/Applications/Notch Balls Prototype.app` 到本地忽略目录 `.local-backups/0.35/`。
2. 从原版 0.35 菜单点击“检查更新”，核对新版本及“未公证测试版”说明。
3. 由 Sparkle 下载、验证、安装并重新启动；禁止手动复制新 app 冒充更新成功。
4. 核对 `/Applications` 的 CFBundleVersion、签名和运行进程路径，再检查更新应显示已是最新。
5. 若失败，记录 Sparkle 错误；退出应用后从备份恢复。不要关闭 Gatekeeper 或删除隔离属性来冒充通过。

若发布的包有问题，先提交清单移除该条目，保留发布产物用于追溯；已安装的版本不会自动降级，
修复版应使用更高 build。恢复本机 0.35 时要先停止对应进程，再用 ditto 复制备份，避免混合旧新文件。
用户偏好、提醒事项、便笺和专注数据库不属于发布包，不需要清空或上传。

参考：[Sparkle 发布文档](https://sparkle-project.org/documentation/publishing/)、
[组件签名要求](https://sparkle-project.org/documentation/sandboxing/)。
