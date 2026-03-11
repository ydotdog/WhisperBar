# WhisperBar — 设计目标与需求文档

## 一、项目概述

WhisperBar 是一款 macOS 本地语音转文字工具，核心理念是：
- **完全本地运行**，不依赖任何网络/云端 API，保护隐私
- **模型随 App 打包**，用户下载 DMG 即可直接使用，无需额外配置
- 采用 Apple 生态最优的 Whisper 推理框架 **WhisperKit**（Argmax 出品），充分利用 Apple Silicon 的 Core ML 加速

---

## 二、功能需求

### 2.1 录音触发方式（双模式）

| 按键行为 | 结果 |
|---------|------|
| 按住 ≥ 0.8 秒后松开 | **Push-to-Talk 模式**：松手即停止录音并转写 |
| 短按（< 0.8 秒）松开 | **Toggle 模式**：继续录音，再次按键才停止 |

- 阈值：`holdThreshold = 0.8` 秒
- 触发方式：全局快捷键 `⌥⌘R`，以及浮动窗口上的录音按钮

### 2.2 全局快捷键

- 组合键：`⌥⌘R`（Option + Command + R）
- 要求在任意 App 前台时均可触发，无需切换焦点
- 实现方案：Carbon `RegisterEventHotKey`（不需要辅助功能权限）
- 最终选择 `⌥⌘R` 的原因：`⌥Space` 会被中文输入法拦截

### 2.3 浮动窗口（Voice Bar）

- 样式：毛玻璃背景（`ultraThinMaterial`）+ 圆角，类似系统风格
- 位置：屏幕底部居中，位于 Dock 正上方（`y = visible.minY + 12`）
- 层级：`.floating`，始终浮于其他窗口之上，不抢夺焦点（`nonactivatingPanel`）
- 跨桌面：`.canJoinAllSpaces`，在所有 Space 均可见
- 尺寸：宽 500pt，高度随内容自动伸缩

### 2.4 窗口内容区

| 区域 | 说明 |
|------|------|
| 录音按钮 | 圆形，颜色随状态变化：灰（加载中）/ 蓝（就绪）/ 红（录音中）/ 橙（错误） |
| 状态文字 / 波形 | 录音时显示实时音频波形动画（30 根柱子）；其他时候显示状态文字 |
| 词汇书按钮 | 右侧图标按钮，打开自定义词汇窗口 |
| 转写结果 | 转写完成后在按钮行下方展示，支持文本选择 |
| 复制按钮 | 转写结果右侧，显示复制/已复制图标 |

### 2.5 转写完成后的自动行为

1. **自动复制**：转写结果立即写入系统剪贴板
2. **状态提示**：显示"✓ 已复制到剪贴板"，持续 6 秒
3. **自动清除**：6 秒后转写结果和状态自动清空，恢复初始状态
4. 若未检测到语音，3 秒后恢复初始状态

### 2.6 语言识别

- 多语言自动检测（中文、英文、中英混合等）
- 使用 `DecodingOptions(task: .transcribe)`（转写，不翻译）
- 模型选用 **openai/whisper-large-v3-turbo**（全精度，非量化版本）

### 2.7 自定义词汇（Vocabulary）

- 用户可添加"错误词 → 正确词"替换规则，用于校正专有名词/人名/术语
- 数据持久化到 `~/Library/Application Support/WhisperBar/vocabulary.json`
- 转写完成后对文本进行后处理替换
- 通过独立窗口（`NSWindow`）管理词汇

### 2.8 App 形态

- `LSUIElement = true`：无 Dock 图标，纯状态栏 App
- Menu Bar Extra：`mic.fill` 图标，点击展示简单菜单
- 不依赖沙盒（无 Sandbox 限制）

---

## 三、技术选型

| 项目 | 选择 |
|------|------|
| 语音识别框架 | WhisperKit（argmaxinc/WhisperKit，via Swift Package Manager） |
| Whisper 模型 | openai_whisper-large-v3_turbo（Full Precision，Core ML 格式） |
| 模型分发 | 随 App Bundle 一起打包，用户无需单独下载 |
| 全局热键 | Carbon `RegisterEventHotKey` + `InstallEventHandler` |
| 录音 | `AVAudioRecorder`，16kHz 单声道 PCM WAV，录至临时文件 |
| UI 框架 | SwiftUI + AppKit（NSPanel 浮动窗口） |
| 项目管理 | xcodegen（`project.yml` 驱动），Swift 5.9，macOS 14.0+ |
| 模型镜像 | hf-mirror.com（HuggingFace 国内镜像，用于下载模型文件） |

---

## 四、非功能性需求

- **隐私**：所有音频处理完全本地，不联网
- **性能**：Apple Silicon 上通过 Core ML Neural Engine 加速推理
- **分发**：目标是打包成独立 DMG，用户开箱即用
- **权限**：仅需麦克风权限（`NSMicrophoneUsageDescription`），热键不需要辅助功能权限
