# zeroflow

一款免费、无弹窗的 macOS 原生的效率小工具，安装包小、低内存占用（截图和缩略图需要一定内存），启动迅速。

## 功能

- 全局快捷键 `⌘+⇧+S` 任意时刻截图，支持自定义快捷键
- `⌘+tab`切换窗口显示缩略图
- 单击 Dock 图标最小化窗口（可在设置中开启）
- Dock图标悬停可预览窗口
- 访达中支持右键菜单自定义
- 灵动岛

## TODO list
- [ ] 灵动岛显示宠物？如果太耗内存就不做
- [ ] cmd+shift+c弹出的粘贴板位置改回基于当前鼠标
- [ ] 日历信息中显示重复
- [ ] 添加快捷键option：临时显示dock栏，方便打开app

## 下载安装

从 [Releases](https://github.com/hellolio/zeroflow/releases) 下载最新的 `Zeroflow-x.x.x.dmg`，打开后将 Zeroflow 拖入「应用程序」。

> 应用目前未做开发者签名/公证，首次打开时 Gatekeeper 可能提示「已损坏，无法打开」或「无法验证开发者」。任选其一解决：
>
> - 终端执行 `xattr -cr /Applications/Zeroflow.app` 后再打开；
> - 或前往 系统设置 → 隐私与安全性 → 找到 Zeroflow 的拦截提示 → 点「仍要打开」。


## 构建

前置条件：macOS 14.0+、Xcode 16+。

```bash
cd zeroflow
xcodebuild -project Zeroflow.xcodeproj -scheme Zeroflow \
  -configuration Release -derivedDataPath build build

open build/Build/Products/Debug/Zeroflow.app
```

> 新建源文件放入 `Zeroflow/` 目录即自动纳入编译，无需改 pbxproj。

CI（`.github/workflows/build.yml`）：推送/PR 到 main 触发编译检查并上传 app zip artifact；打 `v*` tag 会用 Release 配置构建、打包 DMG 并自动发布到 GitHub Releases。

## 技术栈

| 项 | 选型 |
|---|---|
| 语言 | Swift 5 |
| UI | SwiftUI + AppKit |
| 屏幕捕获 | ScreenCaptureKit（macOS 14+） |
| 全局热键 | Carbon `RegisterEventHotKey` |
| 依赖 | 无（单工程） |
| 最小系统 | macOS 14.0（Sonoma）+ |

## 目录结构

```
zeroflow/
├── Zeroflow.xcodeproj/          # Xcode 工程
├── Zeroflow/                    # 源码
│   ├── ZeroflowApp.swift        # 程序入口
│   ├── MenuBar/                 # 菜单栏控制器
│   ├── Models/                  # 设置、快捷键、编辑文档模型
│   ├── Views/                   # 设置页、选区遮罩、编辑页
│   └── Services/                # 热键、截屏、编辑器协调、日志
├── 需求文档.md                  # 详细需求
└── dist/                        # 构建产物副本
```


## License

[MIT](LICENSE)
