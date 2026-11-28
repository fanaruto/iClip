# iClip

> 超轻量双端原生剪贴板与灵感工作台：同时提供 **macOS 原生液态玻璃版（Swift）** 与 **Windows 10/11 原生云母亚克力版（Rust Win32）**，零重型运行时依赖、秒级唤醒、完全离线运行。

按下 **`⌥V`**（macOS）或 **`Alt+V`**（Windows），系统级毛玻璃面板在你的**鼠标光标旁**直觉滑落；选中即可直贴回上一个应用，随时按 **`⌘E`（macOS）/ `Ctrl+E`（Windows）** 一键切换**极简纯净模式**。

<p align="center">
  <img src="assets/demo.gif" alt="iClip 实机运行演示：鼠标旁唤醒、原生液态玻璃/云母材质、图片悬停放大与双击键入" width="760" />
</p>

## 快速安装

- **macOS 一键免安全弹窗直装**（自动装入应用程序并启动）：
  ```zsh
  curl -fsSL https://app.webfooo.com/iClip/install.sh | zsh
  ```
- **Windows 10/11 一键免拦截直装**（自动解除隔离标记并生成快捷方式）：
  ```powershell
  irm https://app.webfooo.com/iClip/install.ps1 | iex
  ```
- **手动下载安装包**：前往 [官网高速下载页](https://app.webfooo.com/iClip) 或本仓库 [Releases 最新版本](https://github.com/fanaruto/iClip/releases/latest) 获取 `.dmg` / `.zip` 安装包。

## 自动更新与隐私

- **自动更新**：macOS 与 Windows 客户端均内置一键 OTA 自动更新，自动校验安装包 SHA-256 哈希与完整性，无需卸载重装，历史记录完整保留。
- **隐私守护**：剪贴内容与待办数据全程保存在本机，无账号体系、无云端上传、无统计埋点；联网仅用于检查与下载新版本安装包。

## 仓库说明与问题反馈

- 本仓库为 **iClip 官方版本发布、自动更新分发与问题反馈仓库**（源码自 v3.5 起迁入私有仓库持续迭代，本仓库持续同步发布双端正式安装包）。
- 使用中遇到问题或有功能建议，欢迎在 [Issues](https://github.com/fanaruto/iClip/issues) 提交反馈。
