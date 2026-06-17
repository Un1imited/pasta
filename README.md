# Pasta

一个本机可用的 macOS 剪贴板历史管理器（Paste / iPaste 同类）。纯本地、无网络、无多端同步。

原生 AppKit 菜单栏应用，只用 Swift + 命令行工具构建，不需要完整 Xcode。界面是**贴屏幕底部的全宽卡片栏**（按 `⇧⌘V` 唤出），深色磨砂、横向卡片。

> macOS 13+ · Apple Silicon / Intel

## 功能

- 后台监听系统剪贴板，自动记录**文本 / 图片 / 文件**历史
- 全局快捷键唤出**底部卡片栏**（默认 `⇧⌘V`，可在偏好里自定义）
- **卡片跟随复制来源深浅**：从终端/编辑器复制 → 深色卡，从浏览器/聊天复制 → 白色卡
- 卡片显示**来源 App 图标 + 名称**、相对时间、内容、字符数
- **图片缩略图**预览
- `剪贴板 / 置顶` 标签切换；模糊搜索
- 键盘全导航：`←→` 选卡片、`↑↓` 在搜索框/标签/卡片之间切换、`⏎` 粘贴
- 选中后自动**切回原 App 并粘贴**；鼠标 hover 高光、点击/双击粘贴
- **纯文本粘贴模式（去格式）**：全局开关，或临时按 `⌥⏎`
- **历史过期清理**：永不 / 1 天 / 7 天 / 30 天（置顶项不过期）
- 内容**去重**、置顶（`⌘P`）、删除（`⌘⌫`）、本地持久化
- 菜单栏图标 + 偏好设置 + 开机自启
- 跳过密码管理器标记的敏感内容（ConcealedType）

## 安装

### 方式一 · 从源码构建（推荐，零 Gatekeeper 摩擦）

需要 macOS 命令行工具（`xcode-select --install`）。本地构建出来的 App 不会被 Gatekeeper 拦。

```bash
git clone https://github.com/<你的用户名>/pasta.git
cd pasta
./build.sh        # 编译并打包成 Pasta.app
open Pasta.app    # 运行，菜单栏出现剪贴板图标（无 Dock 图标）
```

把 `Pasta.app` 拖到 `/Applications` 即可常驻。

### 方式二 · 下载预编译版

从 [Releases](https://github.com/<你的用户名>/pasta/releases) 下载 `Pasta-x.y.z.zip`，解压拖到 `/Applications`。

> 预编译版是 **Apple Silicon（arm64）**。Intel Mac 请走「方式一 · 从源码构建」。

⚠️ 本项目**未做 Apple 公证**，下载的版本首次打开会被 Gatekeeper 拦「来自身份不明的开发者」。两种放行方式：

- **右键点 `Pasta.app` → 打开**，在弹窗里再点「打开」（只需一次）
- 或终端执行：`xattr -dr com.apple.quarantine /Applications/Pasta.app`

## 首次使用：授予「辅助功能」权限

模拟 `⌘V` 粘贴需要辅助功能权限。首次启动会弹窗引导，或手动开启：

**系统设置 → 隐私与安全性 → 辅助功能** → 勾选 **Pasta**

未授权时：历史记录、搜索、复制都正常，只是「自动粘贴回原 App」不生效（内容已在剪贴板，可自行 `⌘V`）。授权后**重启 App** 生效。

## 快捷键

| 操作 | 按键 |
|------|------|
| 唤出 / 收起卡片栏 | `⇧⌘V` |
| 卡片间选择 | `←` `→` |
| 搜索框 / 标签 / 卡片之间切换焦点 | `↑` `↓` |
| 切换 剪贴板 / 置顶 标签 | `⌘1` / `⌘2`，或焦点在标签时 `←→` |
| 粘贴选中项 | `⏎`（或双击卡片） |
| 临时纯文本粘贴 | `⌥⏎` |
| 置顶 / 取消置顶 | `⌘P` |
| 删除选中项 | `⌘⌫` |
| 关闭 | `esc` |
| 搜索 | 直接输入 |

## 偏好设置

菜单栏图标 → **偏好设置…**（`⌘,`）：自定义唤起快捷键、纯文本粘贴开关、历史保留时长。

## 数据位置

```
~/Library/Application Support/Pasta/history.json
```

删除该文件即清空全部历史。菜单栏「清空历史」清掉非置顶项。

## 开发

```bash
swift run            # 直接跑（开发用）
swift build -c release
./build.sh           # 打包 Pasta.app（自签名/ad-hoc，自动带图标）
./release.sh         # 打通用二进制 + 压成 dist/Pasta-<版本>.zip（发布用）
```

源码结构见 `Sources/Pasta/`。图标源在 `_design/icon-final.html`。

## 关于分发

未加入 Apple Developer Program（无 $99 账号），所以**不做公证、也不上 Homebrew**（Homebrew 5.0 起未公证的 cask 已被弃用）。分发方式就是上面的「源码构建」+「Release zip + 右键打开」。

## 已知限制

- 仅本机、无云同步（按设计）。
- 历史上限：非置顶最多 200 条，置顶不限。
- 过期清理在运行时每小时执行一次，设置变更时立即执行。

## License

MIT，见 [LICENSE](LICENSE)。
