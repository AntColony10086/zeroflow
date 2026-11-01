# AGENTS.md

This file provides guidance to latent (an AI coding agent) when working with code in this repository.

macOS 截图菜单栏工具(截图 + 画线/矩形/圆框/文字气泡/马赛克标注 + 撤销重做 + Dock 单击最小化 + Dock 悬停预览 + 内置 ⌘⇥ 窗口缩略图切换器 + 访达右键菜单 + 中/英/日国际化)。SwiftUI + AppKit,无第三方依赖,零测试/零 lint 目标。前置:macOS 14+、Xcode 16+。踩坑记录见 `PITFALLS_DEV.md`(dev-test skill 维护)。

## 常用命令

### 构建(xcodebuild 通过 = 唯一验证方式,无测试/lint)

```bash
# 本地 Debug(必须带 -allowProvisioningUpdates:FinderSync 扩展的 App Group 需自动生成 provisioning)
xcodebuild -project Zeroflow.xcodeproj -scheme Zeroflow -configuration Debug -derivedDataPath build -allowProvisioningUpdates build
open build/Build/Products/Debug/Zeroflow.app

# CI 等价命令(ad-hoc;仅限编译检查——ad-hoc 包的 FinderSync 扩展无 App Group 写权限,
# 「访达右键打开终端」会静默失败,见 PITFALLS_DEV.md DEV-018;正式分发用 Team 签名,
# CI 已从 secrets 导入 Apple Development 证书,本地用上面的 Debug 命令)
xcodebuild -project Zeroflow.xcodeproj -scheme Zeroflow -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

- dist/ 已 gitignore,是发布副本:`rm -rf dist/Zeroflow.app && cp -R -L <app> dist/ && pkill -f Zeroflow.app && open dist/Zeroflow.app`。
- 构建相关坑(provisioning、产物路径漂移、只读 derivedDataPath)见 `PITFALLS_DEV.md`。

### CI / 发布

- `.github/workflows/build.yml`:push/PR 到 main = Release 编译检查 + app zip artifact;推 `v*` tag = Release 构建 + create-dmg(背景 `dmg_bg.png`)+ 自动发 GitHub Release。
- 发布 = `./create_release_tag.sh [vX.Y.Z]`:切 main、计算下一 patch tag 并推送,tag 触发 CI 出 DMG 发 Release。

### FinderSync 扩展登记

`scripts/install-findersync.sh [Debug|Release]`(支持 `--reload-only` 仅重载)。pkd/LS 相关坑见 `PITFALLS_DEV.md`;诊断用扩展 os_log:`log show --predicate 'subsystem == "com.zeroflow.app.finderSync"'`。

### 调试环境变量(进程环境)

| 变量 | 作用 |
|---|---|
| `ZEROFLOW_AUTO_CAPTURE=1` | 启动 1.5s 后自动触发一次截图流程 |
| `ZEROFLOW_EDITOR_DEBUG=1` | 启动 1.5s 后直接打开编辑页(合成网格图,绕过截图) |
| `ZEROFLOW_AUTO_FOCUS=<wid>` | 启动 2s 后用 WindowActivator 聚焦指定窗口 |
| `ZEROFLOW_DOCK_PROBE=1` | 启动 1s 后 dump Dock 的 AX 布局到日志 |
| `ZEROFLOW_SWITCHER_DEBUG=1` | 启动 1s 后 dump 窗口列表 + ⌘⇥ tap 安装状态,并输出事件级日志 |
| `ZEROFLOW_DOCKPREVIEW_DEBUG=1` | 打印 Dock 悬停预览的命中/展示/隐藏决策日志 |
| `ZEROFLOW_NOTCH_DEBUG=1` | 打印灵动岛刘海探测/弹出/收起决策日志 |
| `ZEROFLOW_NOTCH_FAKE=1` | 在主屏合成伪刘海(宽 180/高 24),便于无刘海机器调试面板 |
| `ZEROFLOW_FAKE_PERMISSION=1` | 跳过真实权限检测(视为已授权) |

## 项目架构

SwiftUI 视图 + AppKit/CG/AX(含私有 API dlsym 桥)服务层 + UserDefaults/App Group 设置。依赖方向:`ZeroflowApp` → `MenuBarController` / Views → Services → 系统框架;`SettingsStore` 全局单例,Views 与 Services 经 Combine 通知订阅设置变化。

### 五条模块链

- **截图链**:`GlobalHotkeyManager`(Carbon 热键,受 `screenshotEnabled` 总开关控制)→ `CaptureCoordinator`(权限→遮罩→捕获→编辑页,`isActive` 防重入)→ `ScreenCapture`(ScreenCaptureKit,按 displayID 缓存 `SCContentFilter`)→ `CaptureOverlayView`(选区遮罩)→ `EditorView`(编辑页)。
- **窗口管理族**(切换器与 Dock 预览共用):`WindowList`(CGWindowList 枚举 + 幽灵过滤 + 窗口级 MRU + 无窗口 app 占位)→ `PhantomWindowDetector`(幽灵判定,对齐 AltTab)/ `WindowActivityTracker`(AX 焦点维护 MRU)/ `WindowThumbnailer`(SkyLight 抓缩略图,能截最小化/离屏)/ `WindowActivator`(跨 Space 前台激活)/ `WindowOps`(卡片操作);消费方 `CommandTabSwitcher`(⌘⇥ 面板)与 `DockHoverPreviewController` + `DockPreviewPanel`。`CGSWindowServer` 是上述私有 API 的 dlsym 桥,启动需预热。
- **Dock**:`DockClickMinimizer`(单击最小化),开关变化经通知启停 CGEventTap。
- **灵动岛**:`NotchHotspotController`(listen-only CGEventTap + idle→pending→visible 状态机;由公开 API 推导刘海热区:`safeAreaInsets.top` + `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` 间隙)→ `NotchPanel`(非激活 NSPanel,固定深色 HUD,形状 = 「放大版刘海」:顶边满宽贴屏幕顶盖住真刘海、顶部两角为矩形角位补月牙黑的凹形肩弧(黑色沿凹弧收细到内缩的竖直侧墙,外侧背景在角上呈圆角:右上╭/左上╮,与真刘海肩部同形)、底部两角外凸圆角,半径随面板宽相对刘海宽等比放大(`NotchShapeContainerView` CAShapeLayer 遮罩,每帧 layout 重建路径);弹出/收起 = 迷你刘海(比真刘海小一圈藏在硬件后)与展开尺寸间两段连续弹簧互变(段1 横向拉到 80% 终宽/收起镜像=纵向收到刘海高,临界阻尼无回弹,引导分量位移进度 85% 时以当前值速度无缝续接段2 剩余方向,全程无停顿仅终点一次过冲(宽/高各达 ~105% 再回弹到 100%),动画结束才 orderOut;NotchSpringAnimator 主线程定时器积分,弹簧分量为锚点 centerX/topY + width/height(origin 每帧由锚点反推,锚点临界阻尼零回弹,尺寸过冲时左右/上下对称外扩、窗口整体不平移),分量差异化 response 0.32–0.52,全程不透明无透明度渐变,打断单段重定向无缝续接,在途 handoff/completion 作废);尺寸 = 设置展开宽/高(`notchMaxWidth` 200–1200/`notchMaxHeight` 100–1000,固定不随内容变化,水平居中刘海/钳制进屏幕),内容显示在刘海下方槽位,超出时等比缩小或滚动(日历日程列表装不下在剩余空间滚动,日程加载/切换后重测 refit 重建 contentView,面板尺寸不变);背景=纯黑(遮罩容器底色);结构红线见 DEV-022/023/024)→ `NotchCalendarViewModel` → `CalendarService`(EventKit,macOS 14 全量授权;后台线程查询)。单模块显示,顶部条内刘海两侧药丸切换(≥2 模块才显示,选中的高亮;会话内记住选择、重启回默认日历;无启用模块时面板仍弹出显示「添加显示内容」引导):日历 / 系统资源(`SystemResourceMonitor`:CPU host_processor_info、内存 host_statistics64、网络 NET_RT_IFLIST2、磁盘 IOBlockStorageDriver、GPU IOAccelerator,全免 root;维护近 30 点采样历史供磁盘/网络 sparkline,CPU/内存/GPU 为用量进度条(灰轨道=100%);仅显示该模块时激活,弹出后 0.4s 快速补采使速率项首值即显)/ 正在播放(`NowPlayingMonitor`:MRNowPlayingRequest 类属性轮询,类不可用降级 osascript;控制走 MRMediaRemoteSendCommand)。悬停 ≥ 延时(设置项)或单击热区弹出,点击面板外/Esc/移出热区∪面板(同延时延迟收起)/切 Space/睡眠/屏幕变化收起;无刘海或未授权则静默不生效。
- **FinderSync 桥**:主 app(非沙盒)与扩展(沙盒)经 App Group 的共享文件通信——设置 plist `finder-sync-settings.plist`、命令请求 `finder-command-*.plist` + 分布式通知,自定义命令由主 app `FinderCommandRunner` 代执行;`FinderSyncReloader` 自愈陈旧扩展实例。**不要用 `UserDefaults(suiteName:)` 读 App Group**——原因及全部沙盒/登记坑见 `PITFALLS_DEV.md`。
- **基础**:`AccessibilityPermission` / `ScreenRecordingPermission`(权限检测)、`ZSLog`(日志,stderr + `/tmp/zeroflow.log`)、`L10n`(国际化:UI 文案一律 `L10n.tr("中文")` 作 key,新增文案需同步 `Resources/Translations.json`)。

### 编辑页不变量(`EditorView` + `EditDocument`)

- 所有元素存**图像坐标**;与视图坐标互换必须走 `toView`/`toImage`(及 Rect 版本),不得直接用视图坐标。
- `CanvasElement` 4 case:stroke / bubble / shape / mosaic;仅 bubble / shape 可选中、移动、缩放、删除。
- 任何修改前先 `snapshotBeforeChange()`(撤销/重做栈上限 50);**BubbleElement / ShapeElement 的 id 不可换**,重设状态须 `init(id:)` 沿用原 id,否则选中/拖动簿记全失效。
- 马赛克:画布绘制、临时笔划、导出共用 `MosaicOverlayCache`(按半径缓存像素化叠加图),改绘制时保持三处一致。
- `exportedImage()` 用 AppKit 按原图尺寸重绘、不依赖视图层级,改绘制逻辑必须同步它。

### 设置与工程

- 全部 UserDefaults key 与默认值集中在 `SettingsStore.Keys` 枚举;`screenshotEnabled` 关 = 热键不注册 + 菜单置灰 + 捕获忽略。
- **新增 .swift 文件自动纳入编译**(工程用 `PBXFileSystemSynchronizedRootGroup`),不要手改 pbxproj 加文件;新增 target 才需手改 pbxproj(当前仅 FinderSyncExtension 一个扩展 target,已配好)。

## 目录索引

### `Zeroflow/`(主 app target,非沙盒)

| 文件 | 职责 |
|---|---|
| `ZeroflowApp.swift` | `@main` 入口:手动建 `NSApplication`,装配服务与 `MenuBarController` |

### `Zeroflow/MenuBar/`

| 文件 | 职责 |
|---|---|
| `MenuBarController.swift` | 菜单栏图标与菜单(立即截图/最近截图/设置/退出);debug 环境变量在此触发 |

### `Zeroflow/Models/`

| 文件 | 职责 |
|---|---|
| `EditDocument.swift` | 画布文档模型:`CanvasElement` 4 类元素、图像坐标、撤销/重做栈 |
| `L10n.swift` | 语言枚举(跟随系统/zh-Hans/en/ja)+ `L10n.tr` 查 `Translations.json`,缺 key 回退中文原文 |
| `SettingsStore.swift` | 全部设置项:`Keys` 常量与默认值、`@Published` 属性、App Group plist 桥接 FinderSync |
| `ShortcutKey.swift` | 快捷键值类型与三组默认键(截图 ⌘⇧S;切换器 ⌘⇥ / ⌥`) |

### `Zeroflow/Services/`

| 文件 | 职责 |
|---|---|
| `AccessibilityPermission.swift` | 辅助功能权限检测与引导跳系统设置 |
| `AXWindow.swift` | AX 窗口元素查找:`_AXUIElementGetWindow` 精确匹配(禁 bounds 模糊兜底)、remote-token 暴力枚举 |
| `CalendarService.swift` | EventKit 门面:授权状态/请求(macOS 14 全量)、区间日程查询(未授权返回 [],后台线程调用) |
| `CaptureCoordinator.swift` | 截图流程协调:权限→遮罩→捕获→编辑页,`isActive` 防重入 |
| `CGSWindowServer.swift` | SkyLight/CGS 私有 API dlsym 桥:SLS 批量枚举、Space 拓扑、跨 Space 激活 |
| `CommandTabSwitcher.swift` | ⌘⇥ 切换器:CGEventTap 拦截 + 会话键盘(⇥/⇧⇥/方向键)+ 悬停卡片操作 |
| `DockClickMinimizer.swift` | Dock 单击最小化:CGEventTap + Dock AX 命中 |
| `DockHoverPreviewController.swift` | Dock 悬停预览:listen-only CGEventTap + idle→pending→visible 状态机(generation 作废) |
| `FinderCommandRunner.swift` | 代执行扩展转交的自定义命令:请求文件 + 分布式通知 IPC,启动消化积压(>30s 丢弃) |
| `FinderSyncReloader.swift` | 陈旧扩展自愈:pluginkit ignore→use election 循环重载(Sequoia/Tahoe bug) |
| `GlobalHotkeyManager.swift` | Carbon 全局热键注册/注销,受 `screenshotEnabled` 总开关控制 |
| `NotchHotspotController.swift` | 灵动岛:listen-only CGEventTap 悬停/单击刘海热区弹出面板,状态机 + 收起重弹抑制 + 全局隐藏触发(切 Space/睡眠/屏幕变化) |
| `SystemResourceMonitor.swift` | 灵动岛系统资源采样:CPU/内存/网络/磁盘/GPU,仅面板可见期间 2s 轮询(弹出后 0.4s 快速补采首个速率值),各源免 root(IOKit 注册表 + mach + sysctl) |
| `NowPlayingMonitor.swift` | 灵动岛正在播放:MRNowPlayingRequest 类属性轮询(降级 osascript JXA 子进程),MRMediaRemoteSendCommand 播放控制 |
| `PhantomWindowDetector.swift` | 幽灵窗口判定(对齐 AltTab cgsVerdict + AX subrole 兜底) |
| `ScreenCapture.swift` | ScreenCaptureKit 截屏,按 displayID 缓存 `SCContentFilter` |
| `WindowActivator.swift` | 跨 app 窗口激活:还原最小化 → SLP 置前 → makeKey → AX main/raise(探针验证) |
| `WindowActivityTracker.swift` | 窗口级 MRU:AX 焦点通知 + app 激活/Space 切换补记 |
| `WindowList.swift` | CGWindowList 枚举 + 幽灵过滤 + MRU 排序 + 无窗口 app 占位卡;`SwitcherWindow` 模型 |
| `WindowOps.swift` | 卡片窗口操作(退出/关闭/最小化/全屏);本 app 窗口必须走主线程 NSWindow(AX 后台线程会崩) |
| `WindowThumbnailer.swift` | SkyLight `CGSHWCaptureWindowList` 抓缩略图(含最小化/离屏),缓存 + 节流 + 降级 |
| `ZSLog.swift` | 统一日志(stderr + `/tmp/zeroflow.log`) |

### `Zeroflow/Views/`

| 文件 | 职责 |
|---|---|
| `AccessibilityPermissionRow.swift` | 辅助功能权限状态与引导行(Dock / 切换 两标签页共用) |
| `CaptureOverlayView.swift` | 全屏选区遮罩(SwiftUI 包 NSView) |
| `DockPreviewPanel.swift` | Dock 悬停预览面板(非激活 NSPanel)+ `DockPreviewViewModel` |
| `EditorView.swift` | 截图编辑页(单一 ~1400 行文件):6 种工具 + 画布交互 + 键盘 + 导出 |
| `NotchPanelView.swift` | 灵动岛面板:单模块显示(月视图日历/系统资源列表/正在播放含播放控制)+ 顶部条刘海两侧模块切换药丸,`NotchPanel` 非激活 NSPanel(尺寸=设置展开宽/高固定,刘海形遮罩容器+纯黑底,两段连续(无停顿)弹簧弹出/收起) + `NotchCalendarViewModel` |
| `SaveDirectoryRow.swift` | 保存目录行:路径显示 / 选择 / 打开 |
| `SettingsView.swift` | 设置窗口:7 个标签页(截图/通用/切换/Dock/Dock 预览/灵动岛/右键菜单) |
| `ShortcutRecorderView.swift` | 快捷键录制控件(截图页用,录制期间挂起全局热键) |
| `WindowCardView.swift` | 窗口缩略图卡片(切换器瓦片与 Dock 预览共用 UI) |
| `WindowSwitcherPanel.swift` | ⌘⇥ 切换器面板(瓦片网格 + 选中)+ `WindowSwitcherViewModel` |

### `Zeroflow/Resources/`

| 文件 | 职责 |
|---|---|
| `Translations.json` | 三语文案表(中文 key → zh-Hans/en/ja) |

### `FinderSyncExtension/`(沙盒扩展 target,App Group `8NHN73Q43T.com.zeroflow.app`)

| 文件 | 职责 |
|---|---|
| `FinderSync.swift` | Finder 右键菜单(新建文件/自定义命令);读共享 plist 取设置;`CustomCommandRunner` 写请求文件 + 广播通知,主 app 未运行时拉起它 |

### 仓库根目录与脚本

| 文件 | 职责 |
|---|---|
| `create_release_tag.sh` | 发布脚本:切 main → 计算下一 patch tag → 推送触发 CI |
| `scripts/install-findersync.sh` | FinderSync 扩展一键登记/启用(处理 pkd 僵死与 LS 残留) |
| `.github/workflows/build.yml` | Build & Release CI(编译检查 / tag 发 DMG) |

非源码:`Zeroflow.entitlements`、`FinderSyncExtension/{Info.plist, entitlements}`(App Group 与沙盒授权)、`Resources/Assets.xcassets`。
