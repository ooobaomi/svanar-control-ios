# SVANAR Control · iOS

原生 SwiftUI + CoreBluetooth 耳机伴侣，面向 iOS 16.0+，无第三方运行时依赖。

## 交付状态

- 已完成原生 iOS 工程、协议实现、界面、协议测试与 GitHub Actions 工作流。
- 模式 / EQ 命令来自已在同一副耳机上验证的 Windows 协议，不是靠界面假切换。
- 本地环境是 Windows，本目录本身不是已编译 IPA。只有 GitHub macOS 工作流成功运行后才有 `SvanarControl-unsigned.ipa`。
- 待签名 IPA 需要签名后安装；可选签名工作流可使用你在 GitHub Secrets 中配置的开发 / Ad Hoc 证书和包含手机 UDID 的描述文件。签名资料不要放进源码、聊天或工作流日志。
- iPhone 实机蓝牙连接和 UI 尚待安装后验证；Windows 协议验证不等于 iOS 实机验证。

## 功能

1. 扫描 SVANAR 专用厂商广播，通过产品编号识别候选设备；由你手动选择，避免控制附近同名耳机。
2. HiFi / 降噪 / 通透模式切换，写入后重新查询，最多重试一次。
3. 耳机内置 10 段 EQ：31、62、125、250、500、1k、2k、4k、8k、16k Hz，每段 -10 至 +10 dB。
4. 平直、低频增强、人声清晰、柔和高频预设草稿；本机保存 / 载入；显式应用后 10 段逐项回读验证。
5. 左右耳电量读取；未知值显示横线，未验证的第三字节不显示为充电盒电量。
6. iOS 原生系统音量滑块、音频路由选择器及 App 蓝牙权限设置入口。

### 与 Windows 版的区别

- iOS 不暴露 Windows 播放端点 API，音量和音频路由使用系统原生控件，不提供跨应用端点强制切换或恢复 Windows 输出的功能。
- 只请求蓝牙权限，不请求定位、麦克风或账号，不将后台模式伪装成持续连接保证。
- 进入后台停止扫描和轮询；返回前台时尝试刷新已有连接。断开后需手动重新扫描。
- 扫描不按服务 UUID 过滤：已验证固件的广播没有携带服务列表。
- 首次安装前，请先在电脑 SVANAR Control 中点击“断开控制”，再连接 iPhone，避免 BLE 被电脑占用。耳机音频配对仍在 iOS 蓝牙设置中进行。

## 用 GitHub Actions 得到 IPA（Windows 用户）

### 上传工程

1. 建议创建一个私有 GitHub 仓库，例如 `svanar-control-ios`。本工程不是 HIFIMAN 官方软件。
2. 将**当前目录内全部内容**上传到仓库根目录，而不是上传外层目录。根目录应该直接有 `App`、`Scripts`、`Tests` 和 `.github`。
3. `.github/workflows/build-ios.yml` 是隐藏目录内文件，也必须上传。Windows 资源管理器隐藏项设置不影响 Git 上传。
4. 仓库打开 **Actions → Build iOS IPA → Run workflow**。
5. 默认 Bundle ID 是 `io.local.svanarcontrol`；保持 `sign = false` 即可在不提供证书的情况下编译待签名 IPA。
6. 工作流完成后，打开此次运行，下载 Artifacts 中的 `SvanarControl-iOS-运行编号`。解压后获得 `SvanarControl-unsigned.ipa`、SHA-256 校验文件和构建状态文本。

若本机已安装 GitHub CLI（https://cli.github.com/）和 Git，也可在工程根目录用 PowerShell 上传到你新建的**空仓库**并触发构建：

```powershell
.\Scripts\publish_github.ps1 -Repository '你的账号/svanar-control-ios'
```

脚本使用 GitHub 的网页登录流程，不需要把令牌粘贴到聊天。为保护现有项目，它会拒绝覆盖非空远程仓库或复用已有本地 Git 历史。

仅手动运行构建，未设置推送时自动构建。GitHub 托管 macOS runner 的可用额度与费用以你的账户为准，本工作流超时 30 分钟，产物保留 7 天。

### 可选：直接导出已签名 IPA

在仓库 **Settings → Secrets and variables → Actions** 中添加：

| Secret | 内容 |
|---|---|
| `IOS_CERT_P12_BASE64` | 自有有效代码签名证书及私钥的 P12，以 Base64 编码 |
| `IOS_CERT_PASSWORD` | P12 密码，若 P12 为空密码可留空 |
| `IOS_PROFILE_BASE64` | 包含目标 iPhone UDID、未过期的开发或 Ad Hoc 描述文件，以 Base64 编码 |

然后将工作流的 Bundle ID 改为与你的描述文件匹配的值，勾选 `sign` 后运行。
签名文件只临时写入 runner 临时目录；临时 keychain 和描述文件在退出时清理，不上传到 Artifacts。
签名成功后，Artifacts 额外包含 `SvanarControl-signed.ipa`。
本流程不代办 Apple 证书、不提供企业证书、不上传 App Store / TestFlight。

PowerShell 生成 Base64 文件供你复制到 GitHub Secrets（不要提交这些生成文件）：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path .\certificate.p12))) | Set-Clipboard
# 将剪贴板粘贴到 IOS_CERT_P12_BASE64
[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path .\profile.mobileprovision))) | Set-Clipboard
# 将剪贴板粘贴到 IOS_PROFILE_BASE64
```

### 安装与使用

待签名 IPA 可交给你使用的个人签名安装工具签名；已签名 IPA 仅适用于描述文件允许的设备。开发安装按系统提示开启开发者模式并信任开发者。
不要将“已生成待签名 IPA”理解为“可直接在任意 iPhone 安装”。

1. 在 iPhone 蓝牙设置连接 SVANAR 音频。
2. 打开 App，允许蓝牙权限，点击扫描并选择标识尾号与耳机相符的候选设备。
3. 双耳佩戴后，点击模式按钮；状态显示回读一致才算控制确认，再通过耳机语音提示确认实际听感。
4. 均衡器中拖动滑块仅修改草稿，点击“应用到耳机”才发送。恢复时选择“平直”并应用。

## Mac 本地构建

```bash
bash Scripts/build_unsigned.sh
# 结果：artifacts/SvanarControl-unsigned.ipa
```

也可直接打开 `SvanarControl.xcodeproj`，选择开发团队和 iPhone 后运行。
工程由 Python 标准库脚本生成，不依赖 Homebrew、CocoaPods、SPM、XcodeGen 或第三方服务。

## 验证与协议

```bash
python3 Scripts/generate_project.py
swiftc App/HeadphoneProtocol.swift Tests/main.swift -o protocol-tests
./protocol-tests
```

帧格式：`FE command 00 length_be16 payload crc16_ccitt_false_be16`。
服务：`FF77`；写入：`FF88`（with response）；通知：`FF99`。
命令 `06` 对应模式，`08` 对应 EQ，`03` 对应电量；查询为空载荷。
EQ 写入载荷：`65 0A` 加 10 个有符号 int8 dB 值。
检测到响应超时会主动断开，避免此无序列号协议的迟到响应串入下一条交易。
未实现 OTA、恢复出厂、编码器强制切换，不访问这些控制路径。

参考：
- Apple CoreBluetooth：https://developer.apple.com/documentation/corebluetooth
- iOS 系统音量控件：https://developer.apple.com/documentation/mediaplayer/mpvolumeview
- 注册设备分发：https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices
- GitHub macOS runner：https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job

## 文件说明

- `App/`：SwiftUI、CoreBluetooth、协议及图标。
- `Tests/main.swift`：真实 Swift 协议回归测试，在 macOS 工作流中执行。
- `Scripts/build_unsigned.sh`：编译 iPhoneOS arm64 二进制并打包；二进制检查失败则不产出 IPA。
- `Scripts/build_signed.sh`：使用仓库 Secrets 可选签名导出。
- `Scripts/generate_project.py`：幂等生成 Xcode 项目和共享 Scheme。
- `.github/workflows/build-ios.yml`：macOS 云构建入口。

图标资源已包含。如需重新绘制，运行 `python3 -m pip install pillow` 后执行 `python3 Scripts/generate_icon.py`。
