# 从源码构建听笺

[返回产品介绍](../README.md)

## 源码结构

| 路径 | 用途 |
| --- | --- |
| `macos/FunASR.swift` | SwiftUI 主窗口、模型库、转写任务和编辑器 |
| `macos/SpeakerHeaders.swift` | 识别并替换稿件中的说话人标签 |
| `macos/desktop_worker.py` | 接收界面任务，下载模型并回报转写进度 |
| `macos/transcribe.py` | 音频转换、FunASR 推理和 TXT 格式化 |
| `macos/models.json` | 模型 ID、语言分类、推荐标记和下载配置 |
| `macos/AppIcon.swift` | 生成应用图标 |
| `macos/build.sh`、`bundle_runtime.py`、`package.sh` | 编译应用、组装内置运行时和生成 PKG |
| `transcribe.py` | 原有命令行脚本 |

## 从源码构建

构建机需要 Apple Silicon、macOS 26、支持 macOS 26 SDK 的 Xcode 或命令行工具，以及 Homebrew 的 `python@3.11` 和 `ffmpeg`。下面的锁定依赖来自当前开发机的构建环境。若已有符合版本的 `.venv`，可直接复用。

```bash
# 在仓库根目录执行
/opt/homebrew/opt/python@3.11/bin/python3.11 -m venv .venv
.venv/bin/python -m pip install -r macos/requirements-macos-arm64.txt

# 先编译应用，再组装 Python 和 FFmpeg，最后重新构建并签名
./macos/build.sh
.venv/bin/python macos/bundle_runtime.py macos/build/听笺.app "$PWD/.venv"
./macos/build.sh
./macos/package.sh "$PWD/macos/build/听笺-安装包.pkg"
```

运行时组装脚本使用 Homebrew Python 的 Framework 布局。构建脚本会在随包的 FunASR 上应用语音片段进度补丁。第一次打开应用后，可在模型库下载模型，无需在构建时提交模型权重。
