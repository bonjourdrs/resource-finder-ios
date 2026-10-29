# iPhone 安装说明

本仓库 GitHub 构建的是 **Unsigned（未签名）IPA**。它是真机 arm64 应用，但不能直接点开安装。出现“无法验证其完整性”时，先确认是否已经完成有效签名；不能用“信任开发者”代替签名。

## Windows 个人测试安装

1. 从 https://sideloadly.io/ 下载官方 Sideloadly。按其页面要求准备 Apple 设备连接组件。
2. 用 USB 连接并解锁 iPhone，在 iPhone 上确认信任这台电脑。
3. 把本项目 IPA 拖入 Sideloadly，选中 iPhone，用自己的 Apple 账号在本地工具里完成签名与安装。
4. 按系统提示启用 iPhone“设置 → 隐私与安全性 → 开发者模式”。重启后确认。
5. 如出现开发者信任提示，在“设置 → 通用 → VPN 与设备管理”中确认自己的开发者身份，再打开 App。

免费个人签名有效期为 7 天，需要定期刷新。此 App 要求 iOS 17 或更高版本。Apple 账号、密码和验证码只在本地签名流程中输入，不放进代码或聊天。

如果已经重签仍报完整性错误，需要查看签名工具日志，核对证书是否有效、描述文件是否包含该设备、Bundle ID/权限是否匹配。证书撤销、描述文件失效和设备不匹配需要重新生成有效签名。

## 局域网投屏权限

个人免费签名不保证包含 SSDP 组播权限。DLNA 自动搜索还需要 Apple 批准的组播能力及相符的签名描述文件。可先使用手动添加电视设备描述地址，或在兼容电视上使用 AirPlay。详见 resource_finder_ios/Signing/README.md。

## 自有开发者证书的签名构建

如已有自己的开发者证书和设备描述文件，可进一步配置签名构建。当前工作流没有配置 p12、描述文件或 Apple Team，未生成 TestFlight / App Store 分发包。

参考：
- Apple 免费个人团队限制：https://developer.apple.com/help/account/basics/about-your-developer-account
- Apple 安装失败诊断：https://developer.apple.com/library/archive/technotes/tn2319/
- Sideloadly 使用与刷新：https://sideloadly.io/faq
