# WhisperBar — Bug 历史记录

按时间顺序记录开发过程中出现的问题、根本原因及解决方案。

---

## Bug 1：Swift 6 并发错误（@MainActor 隔离问题）

**现象**
编译报错，`AppDelegate` 中无法直接初始化 `TranscriptionEngine` 和 `VocabularyStore`，因为这两个类被 `@MainActor` 隔离，而 `AppDelegate` 本身不在 Main Actor 上。

**原因**
Swift 6 严格并发检查：`@MainActor` 修饰的类型只能在 Main Actor 上创建和访问，`AppDelegate` 默认不在 Main Actor，导致跨 Actor 访问错误。

**解决**
在 `AppDelegate` 类声明上添加 `@MainActor`：
```swift
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate { ... }
```

---

## Bug 2：WhisperKit `transcribe()` 返回值类型错误

**现象**
编译报错：对 `transcribe()` 的返回值使用了可选链（`?.map {...}`），但该方法返回的是 `[TranscriptionResult]`（非可选）。

**原因**
误以为 `transcribe()` 返回 `[TranscriptionResult]?`，实际上返回的是非可选数组，不需要可选链。

**解决**
将 `results?.map { ... }` 改为 `results.map { ... }`，去掉多余的 `?`。

---

## Bug 3：xcodebuild 插件加载失败

**现象**
运行 `xcodebuild` 时报 `IDESimulatorFoundation` 插件无法加载，构建中断。

**原因**
Xcode 首次在此环境运行，某些插件尚未完成初始化。

**解决**
运行一次 `xcodebuild -runFirstLaunch` 完成 Xcode 命令行工具的首次初始化，之后构建正常。

---

## Bug 4：模型下载失败（GFW 屏蔽 HuggingFace）

**现象**
运行时调用 `WhisperKit.download()` 从 HuggingFace 下载模型失败，`curl` 返回 HTTP 000（连接被拒绝）。

**原因**
HuggingFace.co 在中国大陆被防火长城屏蔽，无法直连。

**解决分两步：**
1. 尝试将下载 endpoint 改为 `https://hf-mirror.com`（HuggingFace 国内镜像）
2. 但考虑到用户分发体验，最终方案是：**将模型文件直接打包进 App Bundle**，用 `curl` 从 hf-mirror.com 下载后放入项目目录，通过 xcodegen 的 `type: folder` 作为资源包含进去，运行时用 `WhisperKit(modelFolder: url.path)` 加载本地模型

---

## Bug 5：中文语音被转写成英文

**现象**
对着 App 说普通话，转写结果输出英文，而非中文。

**根本原因（双重）**

**原因 A — 缺少 tokenizer 文件**
WhisperKit 在初始化时会查找模型目录中的 `tokenizer.json`，若找不到会尝试从网络下载（失败，因为 GFW），导致 token 解码异常，中文 token 被错误映射为英文词。

**原因 B — 量化模型多语言能力退化**
最初使用的模型 `openai_whisper-large-v3-v20240930_626MB` 是 INT4 激进量化版本，模型体积压缩到约 626MB，但多语言识别能力严重退化，说中文时会输出英文翻译而非原文转写。

**解决**
1. 针对原因 A：将 `tokenizer.json`、`tokenizer_config.json`、`vocab.json`、`merges.txt`、`special_tokens_map.json`、`added_tokens.json`、`normalizer.json` 从 `hf-mirror.com/openai/whisper-large-v3` 下载，放入模型目录
2. 针对原因 B：切换到 **`openai_whisper-large-v3_turbo`（全精度，非量化）** 模型，总大小约 3GB（AudioEncoder 1.2GB + TextDecoder 1.7GB + ContextPrefill 94MB），多语言识别能力完整保留

---

## Bug 6：转写完成后界面"卡住"

**现象**
转写完成后，转写文本永远停留在界面上，没有任何后续动作，用户不知道下一步该怎么做。

**原因**
最初设计没有考虑转写完成后的 UX 流程，文本展示后没有自动清除机制。

**解决**
设计完整的转写完成流程：
1. 转写成功 → 立即自动复制到剪贴板（`NSPasteboard`）
2. 状态显示"✓ 已复制到剪贴板"，持续 6 秒
3. 6 秒后通过 `Task { try? await Task.sleep(...) }` 自动清空文本和状态，恢复"⌥⌘R 开始录音"
4. 复制按钮图标从 `doc.on.doc` 变为 `checkmark`（绿色），给用户视觉反馈

---

## Bug 7：非激活浮动窗口中按钮第一次点击无响应

**现象**
浮动窗口（`NSPanel` 带 `.nonactivatingPanel`）中的录音按钮，首次点击无响应，需要点两次才能触发。

**原因**
`NSPanel` 配置了 `nonactivatingPanel` 样式后，SwiftUI 中的 `DragGesture`（用于检测按下/松开）在窗口未激活状态下不接受第一次鼠标事件。

**解决**
创建 `NSHostingView` 的子类 `ClickThroughHostingView`，重写两个方法：
```swift
private class ClickThroughHostingView<T: View>: NSHostingView<T> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
}
```
用此子类替代默认的 `NSHostingView` 作为 Panel 的 content view。

---

## Bug 8：全局热键 `⌥Space` 被中文输入法拦截

**现象**
最初设计使用 `⌥Space` 作为全局热键，但在中文输入法（如搜狗、系统自带拼音）激活时，`⌥Space` 被输入法优先消费，App 无法收到该事件。

**原因**
`⌥Space` 在多种中文输入法中有特殊含义（切换全半角、输入空格等），输入法在系统层面拦截了该事件。

**解决**
将热键改为 `⌥⌘R`（Option + Command + R）。加入 Command 修饰键后，输入法不会拦截，事件能正常到达 App。

---

## Bug 9：全局热键使用 CGEventTap 不可用

**现象**
将热键改为 `⌥⌘R` 并使用 CGEventTap 实现全局监听后，热键依然无响应。用户在系统"辅助功能"中已授权，但 CGEventTap 仍然无效。

**原因**
CGEventTap 需要辅助功能（Accessibility）权限才能拦截键盘事件，且在 macOS 26 Tahoe 上存在可靠性问题——即使用户授权后，CGEvent tap 有时仍无法正常工作。

**解决**
将实现方案从 CGEventTap 完全切换到 Carbon 的 `RegisterEventHotKey` + `InstallEventHandler`：
- **不需要任何 Accessibility 权限**
- 注册 `kEventHotKeyPressed` 和 `kEventHotKeyReleased` 两个事件，分别对应按下和松开
- `kVK_ANSI_R`（keyCode 15）+ `optionKey | cmdKey` 作为修饰键组合
- 删除了 AppDelegate 中原有的权限轮询逻辑和"去授权"提示 UI

**注意**：`InstallApplicationEventHandler` 在 Carbon 头文件中是函数式宏（function-like macro），Swift 无法直接调用，需替换为底层函数 `InstallEventHandler(GetApplicationEventTarget(), ...)` 实现相同效果。

---

## Bug 10：App 找不到（Library 文件夹隐藏）

**现象**
用户不知道编译后的 App 在哪里，`~/Library/Developer/` 目录在 Finder 中默认隐藏。

**原因**
macOS 默认隐藏 `~/Library` 目录，用户无法通过 Finder 直接导航到 DerivedData 目录下的 `.app` 文件。

**解决**
每次构建完成后，通过以下命令将 App 复制到桌面：
```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData/WhisperBar-*/Build/Products/Debug -name "WhisperBar.app" -maxdepth 1 | head -1)
cp -R "$APP" ~/Desktop/WhisperBar.app
```

---

## Bug 11：自动语言检测导致中英混合语音输出为英文

**现象**
全中文输入能正确输出中文；但中英文夹杂时（如 "我想用 Python 写一个 script"），结果全部输出为英文。

**根本原因（通过阅读 WhisperKit 源码确认）**

WhisperKit 在 `language == nil` + `detectLanguage == true` 模式下，会对音频前几帧做语言检测（`detectLanguage` 方法只采样最初几个 token）。当音频开头出现英文词汇时，检测器判定为 "en"，随后将整段音频锁定在英语解码模式。此外，`Constants.defaultLanguageCode = "en"`，一旦检测置信度不足也 fallback 到英文。

关键代码路径（`TranscribeTask.swift`）：
```swift
// 检测到语言后，用该语言覆盖 currentDecodingOptions
currentDecodingOptions.language = languageDecodingResult?.language
// 后续整段音频都用这个语言解码
```

**已尝试但无效的方案**
- 方案 A：`language: nil, usePrefillPrompt: true, detectLanguage: true` → 仍然失败（检测阶段就选了英文）
- 方案 B：`language: nil, usePrefillPrompt: false, detectLanguage: true` → 仍然失败（同上）

**解决方案**
显式指定 `language: "zh"` + `usePrefillPrompt: true`：

```swift
let options = DecodingOptions(
    task: .transcribe,
    language: "zh",
    usePrefillPrompt: true
)
```

**原理**：强制注入 `<|zh|>` 语言前缀 token，Whisper 多语言模型在中文模式下具备完整的中英文代码切换（code-switching）能力——中文按中文输出，夹杂的英文词按英文输出，无需自动检测。

**状态**：已修复，构建成功，新包已覆盖到 `~/Desktop/WhisperBar.app`。


