# WhisperBar

macOS 本地语音转文字工具，完全离线运行，保护隐私。

## 特性

- **完全本地运行**：不依赖任何云端 API，所有处理在设备上完成
- **WhisperKit 驱动**：使用 Argmax 出品的 WhisperKit 框架，充分利用 Apple Silicon Core ML 加速
- **模型内置**：使用 openai/whisper-large-v3-turbo 模型，下载即用
- **多语言支持**：自动检测中文、英文及中英混合
- **双触发模式**：
  - 按住 `⌥⌘R` ≥ 0.8 秒松开 → Push-to-Talk 模式
  - 短按 `⌥⌘R` → Toggle 模式，再按停止
- **浮动窗口**：毛玻璃风格的 Voice Bar，常驻屏幕底部，跨桌面可见
- **实时波形**：录音时显示 30 根柱状实时音频波形
- **自动复制**：转写结果自动写入系统剪贴板
- **VAD 支持**：Silero VAD + Energy VAD 双引擎语音活动检测

## 系统要求

- macOS（Apple Silicon）
- Xcode 15+

## 构建

使用 Xcode 打开 `code/WhisperBar.xcodeproj` 并构建运行。
