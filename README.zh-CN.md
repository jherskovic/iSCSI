# 简体中文支持

iSCSI/NVMe-TCP Initiator 是适用于 macOS 26 及以上版本的用户态 iSCSI 与 NVMe/TCP 客户端。项目说明、系统要求和安全注意事项见 [README](README.md)。

## 使用中文界面

界面随 macOS 的首选语言显示。也可在“系统设置 → 通用 → 语言与地区 → 应用程序”中，为本应用选择简体中文，退出并重新打开后生效。其他语言继续使用英文。

中文支持覆盖菜单、存储目标、设备发现、连接详情、初始设置、挂载与推出提示、卸载流程和常见存储错误。IQN、NQN、LUN、NSID 等协议标识保留原文；设备返回的原始诊断也会保留，便于排查。

文件系统扩展在“系统设置”中的名称仍为 iSCSI/NVMe/TCP Initiator，启用说明保留此名称，以便找到对应开关。协议实现、扩展注册方式、签名校验和更新机制保持原有行为。

## 维护翻译

中文词条位于 `apps/iSCSIApp/Localizable.xcstrings`，应用名称位于 `apps/iSCSIApp/zh-Hans.lproj/InfoPlist.strings`。在 Swift 代码中，传给动态字符串接口的用户提示应使用 `String(localized:)`；SwiftUI 的字符串字面量也可使用其本地化接口。

翻译应结合操作语境，例如“存储目标”“发现设备”“CHAP 密钥”。完整保留涉及推出磁盘、断开连接、写入缓存和数据丢失的含义；保持格式占位符的类型、编号和含义一致。翻译工作不应改变主机标识、磁盘格式或存储行为。

工程以 `apps/project.yml` 为源，增加资源后需使用仓库固定版本的 XcodeGen 重新生成并提交工程。构建与签名流程见 [发布文档](docs/releasing.md)。
