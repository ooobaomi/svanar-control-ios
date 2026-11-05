# SVANAR Control — Android / iOS

HIFIMAN SVANAR WIRELESS 的非官方本地蓝牙伴侣。没有账号、云端耳机控制或固件刷写功能。

## 下载

- [Android v1.3.0：APK、源码和 EQ 文件](https://github.com/ooobaomi/svanar-control-ios/releases/tag/android-v1.3.0)
- [iOS：查看最新 Release 中的 IPA 和源码](https://github.com/ooobaomi/svanar-control-ios/releases)
- [构建记录](https://github.com/ooobaomi/svanar-control-ios/actions)

Android APK 使用本机原有开发签名，可覆盖该签名的旧版安装。
iOS 默认交付 **unsigned / 待签名 IPA**，签名后安装；不是模拟器包，也不等同于可直接安装或已完成 iPhone 实机测试。

## 工程

- `Android/`：原生 Java Android 8+ 源码和 PowerShell 构建脚本。
- `downloads/`：已在安卓手机测试的预编译、已签名 APK，以及 14 组 EQ JSON。
- `App/`、`Scripts/`、`Tests/`、`SvanarControl.xcodeproj/`：iOS 16+ SwiftUI / CoreBluetooth 工程。

## v1.3 功能

- HiFi／降噪／通透，写入后查询确认；10 段硬件 EQ，14 组通用偏好预设，非测量校准。
- 多套 EQ 收藏，保存、覆盖、重命名、删除；Android / iOS 使用同一 JSON 文件格式。
- 显式模式绑定和可关闭的 EQ 联动：默认关闭，首次连接只读，未绑定模式不改 EQ。
- 游戏模式、左右耳电量、型号／固件／耳机编码报告和强度能力诊断。
- 触控映射读取、按设备备份与恢复逻辑；只对返回有效映射的设备开放写入。

### 真实设备边界

安卓已实测模式与 EQ 回读、游戏开关、收藏、文件往返、非法文件拒绝和 App 模式/EQ 联动。
当前 S050 的触控查询两次无响应，未执行触控写入／恢复。降噪和通透强度能力标志、档位均为 0，未开放相应滑块。
耳机 LDAC 能力声明不等于传输成功；此前手机实际仍协商 AAC。iOS 诊断只显示耳机报告，不更改系统音频编码器。
iOS 云端执行协议、跨平台 JSON、触控格式和能力解析测试并编译；iPhone 实机蓝牙、触控写入、文件选择器 UI 验证：未执行。
耳机长按触发 EQ 联动的端到端实测：未执行。前台约每 5 秒检查模式，后台断开控制，不影响系统管理的音频。

## Android 构建

安装 JDK、Android SDK `android-35` 和 `build-tools 36.0.0`，在 `Android` 内运行 `build.ps1`。
用 `-Java`、`-Sdk` 和 `-SigningStore` 指定本机绝对路径。升级已有安装须使用同一签名私钥；私钥不在仓库中。
Android 发布工作流验证预编译 APK 的 SHA-256 和容器并发布 Release，不宣称云端重新编译出的包与本机签名包相同。

## iOS 构建

macOS + Xcode：`bash Scripts/build_unsigned.sh`；或运行 Actions 的 **Build iOS IPA**。
构建先运行纯 Swift 协议与数据模型测试，再对真实 `iphoneos / arm64` 编译、检查并打包 IPA，成功后上传 Release 和 Actions Artifacts。

可选签名：在 GitHub Actions Secrets 设置 `IOS_CERT_P12_BASE64`、`IOS_CERT_PASSWORD`、`IOS_PROFILE_BASE64`，手动运行时选 `sign=true`，Bundle ID 要与描述文件匹配。
签名证书及描述文件仅使用 runner 临时目录，不上传到源码或构建产物。

## EQ 文件

格式 `svanar-eq`，version 1，固定 10 个频段，整数增益每段 ±10 dB，最多 64 套、64 KiB。
导入先完整校验，再合并；同 ID 的不同内容生成新 ID，导入后关闭联动，不立即写耳机。
首次安装 iOS v1.3 自动准备 14 组收藏；安卓 v1.3 可导入附带 JSON。
