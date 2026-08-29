# 未签名 iOS IPA 交付说明

## 产物定位

本项目输出的是供“全能签”一类工具重新签名的 **未签名 Release IPA**，不要求在编译时提供 Apple Developer 账号、证书或描述文件。

未签名 IPA 不能直接安装。安装前，签名工具仍需持有可用于目标设备的证书与描述文件。

## 包内能力

完整 IPA 包含：

- Flutter 主应用 `Runner.app`
- `ClaudeChatWidget.appex` WidgetKit 小组件
- 日历与提醒事项（EventKit）
- 系统通知
- 麦克风与系统语音识别
- 相机、相册和文件选择
- Keychain 安全存储
- App Group `group.com.susuclaude.app`

主应用 Bundle ID 为 `com.susuclaude.app`，小组件 Bundle ID 为 `com.susuclaude.app.widget`。

## 在 macOS 构建

要求：完整 Xcode、Xcode Command Line Tools、Flutter 3.44.4。

```bash
cd /path/to/ClaudeChat-new
chmod +x build-ios-unsigned.sh
./build-ios-unsigned.sh
```

脚本会先执行依赖解析、`flutter analyze` 和全部测试，再用 `--no-codesign` 编译 Release 应用；如果主应用、小组件、Bundle ID 或 ARM64 可执行文件不完整，脚本会拒绝输出 IPA。

成功产物：

- `ClaudeChat-ios-unsigned.ipa`
- `build/ios/ipa/unsigned-ipa-manifest.txt`

## 使用全能签

1. 导入 `ClaudeChat-ios-unsigned.ipa`。
2. 选择可用于当前设备的证书和描述文件。
3. 确保工具会递归签名主应用、Flutter Framework、所有内嵌 Framework 以及 `ClaudeChatWidget.appex`。
4. 保持小组件 Bundle ID 是主应用 Bundle ID 的子标识，并让主应用与小组件使用同一个 App Group entitlement。
5. 完成签名后安装；首次启动时按需授予通知、日历、提醒事项、麦克风、语音识别、相机和相册权限。

如果签名证书或描述文件不支持 App Group / App Extension，iOS 可能拒绝安装完整包，或者小组件无法读取主应用数据。这是签名能力限制，不是 IPA 编译错误。为保留完整功能，本项目不会默认移除小组件。

## GitHub Actions 构建

仓库已包含 `.github/workflows/build-unsigned-ipa.yml`。在私有 GitHub 仓库的 Actions 页面手动运行 `Build unsigned iOS IPA` 后，可从运行记录下载 `ClaudeChat-ios-unsigned` artifact。该流程不会上传证书，也不会对 IPA 签名。
