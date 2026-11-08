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
| `ZEROFLOW_DOCKPEEK_DEBUG=1` | 打印 Dock 快捷键弹出(自动隐藏时)的热键状态机/指针瞬移决策日志 |
| `ZEROFLOW_NOTCH_DEBUG=1` | 打印灵动岛刘海探测/弹出/收起决策日志 |
| `ZEROFLOW_NOTCH_FAKE=1` | 在主屏合成伪刘海(宽 180/高 24),便于无刘海机器调试面板 |
| `ZEROFLOW_NOTCH_SHOW=1` | 启动 1.5s 后直接弹出灵动岛面板(绕过悬停;此模式指针移出不会自动收起,便于反复看动画) |
| `ZEROFLOW_NOTCH_TRACE=1` | 逐帧把灵动岛形状分量(topW/h)与帧间隔打进日志,数值核对节奏/过冲/主线程卡顿 |
| `ZEROFLOW_FAKE_PERMISSION=1` | 跳过真实权限检测(视为已授权) |
| `ZEROFLOW_CLIPBOARD_DEBUG=1` | 启动 1.5s 后忽略开关直接弹出剪贴板面板(用于验证定位/展开/键盘链路);`=preview` 额外自动展开首条预览 |

## 项目架构

SwiftUI 视图 + AppKit/CG/AX(含私有 API dlsym 桥)服务层 + UserDefaults/App Group 设置。依赖方向:`ZeroflowApp` → `MenuBarController` / Views → Services → 系统框架;`SettingsStore` 全局单例,Views 与 Services 经 Combine 通知订阅设置变化。

### 五条模块链

- **截图链**:`GlobalHotkeyManager`(Carbon 热键,受 `screenshotEnabled` 总开关控制)→ `CaptureCoordinator`(权限→遮罩→捕获→编辑页,`isActive` 防重入)→ `ScreenCapture`(ScreenCaptureKit,按 displayID 缓存 `SCContentFilter`)→ `CaptureOverlayView`(选区遮罩)→ `EditorView`(编辑页)。
- **窗口管理族**(切换器与 Dock 预览共用):`WindowList`(CGWindowList 枚举 + 幽灵过滤 + 窗口级 MRU + 无窗口 app 占位)→ `PhantomWindowDetector`(幽灵判定,对齐 AltTab)/ `WindowActivityTracker`(AX 焦点维护 MRU)/ `WindowThumbnailer`(SkyLight 抓缩略图,能截最小化/离屏)/ `WindowActivator`(跨 Space 前台激活)/ `WindowOps`(卡片操作);消费方 `CommandTabSwitcher`(⌘⇥ 面板)与 `DockHoverPreviewController` + `DockPreviewPanel`。`CGSWindowServer` 是上述私有 API 的 dlsym 桥,启动需预热。
- **Dock**:`DockClickMinimizer`(单击最小化),开关变化经通知启停 CGEventTap;`DockPeekManager`(自动隐藏时的快捷键弹出:listen-only CGEventTap 识别裸修饰键热键——按下→松开期间无任何其他按键/鼠标按下才触发,合成 mouseMoved 把指针先内侧 8pt 再贴边瞬移、驻留 `dockPeekHoldMs` 后移回原位,收起时机完全交给 macOS;合成移动带 source userData 魔数,Dock 预览控制器据此放行),开启前提 = 系统 autohide 开启(设置页据此置灰)。
- **灵动岛**:`NotchHotspotController`(listen-only CGEventTap + idle→pending→visible 状态机;由公开 API 推导刘海热区:`safeAreaInsets.top` + `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` 间隙)→ `NotchPanel`(非激活 NSPanel,固定深色 HUD,形状 = 「放大版刘海」:顶边满宽贴屏幕顶盖住真刘海、顶部两角为矩形角位补月牙黑的凹形肩弧(黑色沿凹弧收细到内缩的竖直侧墙,外侧背景在角上呈圆角:右上╭/左上╮,与真刘海肩部同形)、底部两角外凸圆角,半径随面板宽相对刘海宽等比放大(`NotchShapeContainerView` CAShapeLayer 遮罩,路径由「形状状态」驱动、不是按窗口 bounds:顶栏/细颈/底部鼓包三条外包络宽 + 顶栏高,窗口 frame 只是包围盒 = max(三宽);三宽相等时贝塞尔拐点退化为直线 = 原来的刘海形,当前动画三宽恒相等,见 DEV-039);展开 = 单段弹簧(iOS 灵动岛式「液体铺开」):从藏在刘海硬件后的迷你刘海起手,宽高同时起跳、宽度领先、高度慢半拍(面板先横向铺满、底缘跟着坠到底),锚点临界阻尼零回弹、尺寸分量各只过冲一次(宽 ≈+3%、高 ≈+1% 行程)后回落,≈0.45s 落定,全程没有中途换道/回缩(多段编排的顿挫,见 DEV-040);收起 = 单段临界阻尼弹簧(三宽+高同时缩回迷你刘海),动画结束才 orderOut;内容 hosting 的透明度由宽度位移进度驱动(60% 进度即完全不透明 ≈0.1s),起手就能看到内容随形状长出来,黑底形状全程不透明(DEV-022);NotchSpringAnimator 主线程定时器积分六个分量(锚点 centerX/topY + 三宽 + 高,origin 每帧由锚点反推,尺寸过冲时左右/上下对称外扩、窗口整体不平移,DEV-027),打断单段重定向无缝续接、在途 completion 作废,调参集中在 expandTuning/collapseTuning);尺寸 = 内容自适应(卡片 = 模块自然尺寸:日历列宽 300、卡片 ≈ 320×229–252(间距已收紧,宽于高),资源 300(卡片 ≈ 320×226,与日历卡同宽)、音乐 224;面板 = 卡片 + 可见外边距(四面 16)+ 顶部刘海条,另补遮罩侧墙内缩(≈15,半径随面板宽等比放大)保证卡片与可见黑边有留白;切换箭头放在顶部条内(左上角两个 24pt 圆钮,不占卡片左右留白;面板宽另有下限=刘海宽+左侧箭头区,窄卡片(正在播放 ≈355 宽)据此加宽,保证箭头不被刘海挡住),水平居中刘海/钳制进屏幕);卡片高超出屏幕上限时日历日程列表滚动/资源切紧凑密度/仍超才整卡等比缩小(scale);切换模块与日程加载 refit 后重建 contentView 并走弹簧变形,目标 frame 同步给控制器作命中区域;背景=纯黑(遮罩容器底色);结构红线见 DEV-022/023/024)→ `NotchCalendarViewModel` → `CalendarService`(EventKit,macOS 14 全量授权;后台线程查询)。单模块显示,顶部条左上角箭头循环切换 / 面板内双指左右滑动切换(`NSEvent` local monitor 收 scrollWheel,锁横轴累积超阈值切一张,一次手势只切一张;箭头常显,启用模块不足 2 个时置灰不可点;会话内记住选择、重启回默认日历;无启用模块时面板仍弹出显示「添加显示内容」引导):日历 / 系统资源(`SystemResourceMonitor`:CPU host_processor_info、内存 host_statistics64、网络 NET_RT_IFLIST2、磁盘 IOBlockStorageDriver、GPU IOAccelerator,全免 root;维护近 30 点采样历史供磁盘/网络 sparkline;资源卡分上下两块——上半块 CPU/内存 环形仪表(环心=百分比,双环各占半宽),GPU 小环浮在两环之间的空白正中(环 34 vs 主项 56,不占格、主次分明;只开一个主项时退回并排);下半块 磁盘/网络 上下两行(标题+两向读数一行、趋势线通栏拉满,比左右分栏长一倍);仅显示该模块时激活,弹出后 0.4s 快速补采使速率项首值即显)/ 正在播放(`NowPlayingMonitor`:MRNowPlayingRequest 类属性轮询,类不可用降级 osascript;控制走 MRMediaRemoteSendCommand)。触发方式(设置项 `notchTriggerMode`,默认单击):悬停模式下悬停 ≥ 延时或单击热区弹出,移出热区∪面板同延时延迟收起;单击模式下只由单击热区弹出、鼠标移出不收起,单击热区∪面板以外或 Esc 收起。另切 Space/睡眠/屏幕变化收起;无刘海或未授权则静默不生效。
- **剪贴板链**:`ClipboardMonitor`(0.35s 轮询 `NSPasteboard.changeCount`,排除 Concealed/Transient/AutoGenerated 与密码管理器;图片优先,`NSBitmapImageRep` 取像素尺寸)→ `ClipboardHistoryStore`(SHA256 去重置顶、文本/图片体积门槛、JSON + 图片文件持久化、超上限裁剪)→ `ClipboardPanelController`(全局热键 → **在鼠标位置附近**弹非激活面板 → 搜索/↑↓/↵ → 写剪贴板并合成 ⌘V,需辅助功能权限,未授权退化为仅复制);视图 `ClipboardPanelView`(单行列 + 停留 `clipboardPreviewDelayMs` 后向空闲一侧扩宽显示完整预览)。背景 = macOS 26+ `NSGlassEffectView` 液态玻璃(低于 26 回退 `NSVisualEffectView` 磨砂),外观/降低透明度/Liquid Glass 强度全部交给系统,不加任何自绘底或描边。
- **FinderSync 桥**:主 app(非沙盒)与扩展(沙盒)经 App Group 的共享文件通信——设置 plist `finder-sync-settings.plist`、命令请求 `finder-command-*.plist` + 分布式通知,自定义命令由主 app `FinderCommandRunner` 代执行;`FinderSyncReloader` 自愈陈旧扩展实例。**不要用 `UserDefaults(suiteName:)` 读 App Group**——原因及全部沙盒/登记坑见 `PITFALLS_DEV.md`。
- **基础**:`AccessibilityPermission` / `ScreenRecordingPermission`(权限检测)、`ZSLog`(日志,stderr + `/tmp/zeroflow.log`)、`L10n`(国际化:UI 文案一律 `L10n.tr("中文")` 作 key,新增文案需同步 `Resources/Translations.json`)。

### 编辑页不变量(`EditorView` + `EditDocument`)

- 所有元素存**图像坐标**;与视图坐标互换必须走 `toView`/`toImage`(及 Rect 版本),不得直接用视图坐标。
- `CanvasElement` 4 case:stroke / bubble / shape / mosaic;仅 bubble / shape 可选中、移动、缩放、删除。
- 任何修改前先 `snapshotBeforeChange()`(撤销/重做栈上限 50);**BubbleElement / ShapeElement 的 id 不可换**,重设状态须 `init(id:)` 沿用原 id,否则选中/拖动簿记全失效。
- 马赛克:画布绘制、临时笔划、导出共用 `MosaicOverlayCache`(按半径缓存像素化叠加图),改绘制时保持三处一致。
- `exportedImage()` 用 AppKit 按原图尺寸重绘、不依赖视图层级,改绘制逻辑必须同步它。

### 设置与工程

- 全部 UserDefaults key 与默认值集中在 `SettingsStore.Keys` 枚举;`screenshotEnabled` 关 = 热键不注册 + 菜单置灰 + 捕获忽略;`clipboardEnabled` 关 = 停止监听 + 剪贴板热键不注册 + 面板收起(默认关)。
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
| `ShortcutKey.swift` | 快捷键值类型与默认键(截图 ⌘⇧S;切换器 ⌘⇥ / ⌥`;剪贴板 ⌘⇧C) |
| `ClipboardItem.swift` | 剪贴板条目模型(文本/图片、像素尺寸、来源 app、SHA256、单行摘要) |
| `ClipboardHistoryStore.swift` | 剪贴板历史持久化:去重置顶、上限裁剪、图片文件 + `NSCache` 缩略图缓存 |

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
| `DockPeekManager.swift` | Dock 快捷键弹出(自动隐藏时):listen-only CGEventTap 识别裸修饰键热键,合成 mouseMoved 把指针贴 Dock 边缘驻留后移回原位(收起交给 macOS);合成移动带 userData 魔数,上游与 DockClickMinimizer 同骨架 |
| `FinderCommandRunner.swift` | 代执行扩展转交的自定义命令:请求文件 + 分布式通知 IPC,启动消化积压(>30s 丢弃) |
| `FinderSyncReloader.swift` | 陈旧扩展自愈:pluginkit ignore→use election 循环重载(Sequoia/Tahoe bug) |
| `GlobalHotkeyManager.swift` | Carbon 全局热键注册/注销(截图 + 剪贴板两路,事件按 HotKeyID 分发),分别受 `screenshotEnabled` / `clipboardEnabled` 控制 |
| `ClipboardMonitor.swift` | 剪贴板轮询监听:跳过机密/瞬态类型与密码管理器,图片优先,抑制自身写入 |
| `ClipboardPanelController.swift` | 剪贴板面板控制器:热键 toggle、鼠标处定位、键盘拦截、停留展开预览、复制并合成 ⌘V |
| `NotchHotspotController.swift` | 灵动岛:listen-only CGEventTap 悬停/单击刘海热区弹出面板(触发方式可选悬停/单击),状态机 + 收起重弹抑制 + 全局隐藏触发(切 Space/睡眠/屏幕变化) |
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
| `NotchPanelView.swift` | 灵动岛面板:单模块显示(月视图日历/系统资源列表/正在播放含播放控制)+ 顶部条左上角箭头/双指左右滑动循环切换模块,`NotchPanel` 非激活 NSPanel(尺寸随内容自适应,刘海形遮罩容器+纯黑底,单段弹簧液体弹出(宽领先/高滞后+一次小幅过冲,内容随几何淡入)/临界阻尼收起) + `NotchCalendarViewModel` |
| `SaveDirectoryRow.swift` | 保存目录行:路径显示 / 选择 / 打开 |
| `SettingsView.swift` | 设置窗口:8 个标签页(截图/通用/切换/Dock/Dock 预览/剪贴板/灵动岛/右键菜单) |
| `ClipboardPanelView.swift` | 剪贴板面板视图(搜索 + 单行列表 + 页脚 + 展开预览列)+ `ClipboardViewModel` |
| `ShortcutRecorderView.swift` | 快捷键录制控件(截图页用,录制期间挂起全局热键) |
| `DockPeekHotkeyRecorderView.swift` | 修饰键热键录制控件(Dock 弹出页用,仅录 ⌘/⇧/⌃/⌥ 组合,录制期间挂起 DockPeekManager 识别) |
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
