# PITFALLS_DEV.md

开发踩坑记录(dev-test skill 维护,新增条目按 `DEV-XXX` 递增编号,勿改已有编号)。

## DEV-001: 本地 xcodebuild 不带 `-allowProvisioningUpdates` 直接 BUILD FAILED
- **Pitfall:** 构建时报 `No profiles ... were found`,BUILD FAILED。
- **Cause:** FinderSync 扩展 target 带 App Group(`8NHN73Q43T.com.zeroflow.app`)与沙盒授权,需要 Xcode 自动生成/更新含该 App Group 的 provisioning profile。
- **Prevention:** 本地构建一律带 `-allowProvisioningUpdates`;无团队证书的环境用 CI 等价命令(`CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=`)。

## DEV-002: `-derivedDataPath` 指向无写权限目录直接 BUILD FAILED
- **Pitfall:** 给 `-derivedDataPath` 的目录为只读(如 0644)时,构建直接失败。
- **Cause:** xcodebuild 需要在 derived data 目录写中间产物,无写权限即失败。
- **Prevention:** 换一个可写路径。

## DEV-003: xcodebuild 产物路径不可靠,直接 `cp -R` 得到坏符号链接
- **Pitfall:** Debug 产物可能落在 `build/Build/Intermediates.noindex/ArchiveIntermediates/.../Applications/Zeroflow.app`,用 `cp -R` 复制它得到的是坏符号链接。
- **Cause:** 产物落点不总是确定的。
- **Prevention:** 用 `find <derived>/Build -name "Zeroflow.app"` 定位;复制用 `cp -R -L` 解引用;复制前先 `rm -rf` 目标。

## DEV-004: 新增 target 需手改 pbxproj,改错直接 BUILD FAILED
- **Pitfall:** 以为 `.swift` 文件和 target 一样自动纳入工程,新增 target 时漏配;或手改 pbxproj 出错后构建失败。
- **Cause:** 源文件走 `PBXFileSystemSynchronizedRootGroup` 自动纳入(不要手改 pbxproj 加文件),但 target 本身、Embed App Extensions 阶段、target dependency、FinderSync.framework 链接(App 用于 `FIFinderSyncController.isExtensionEnabled`)都是手工维护的。
- **Prevention:** 新增 `.swift` 文件放对应目录即可;新增/调整 target 才动 pbxproj,改完立即构建验证。当前仅 `FinderSyncExtension/` 一个扩展 target,已配好。

## DEV-005: FinderSync 扩展未沙盒化会被 pkd 静默拒绝
- **Pitfall:** `pluginkit -m` 永远不出现该扩展,`pluginkit -a` 返回 0 却无任何日志,右键菜单不出现。
- **Cause:** pkd(pluginkit)静默拒绝非沙盒的 FinderSync 扩展(`com.apple.security.app-sandbox` 缺失)。
- **Prevention:** 扩展 target 必须保持沙盒授权;排查扩展不可见时先核对 entitlements。

## DEV-006: pkd 进程僵死,新扩展登记不上
- **Pitfall:** 新扩展 `pluginkit -a` 返回 0 但 `pluginkit -m` 查不到,反复登记无效。
- **Cause:** pkd 内存会僵住,僵死的旧实例不响应新插件注册。
- **Prevention:** 登记后查不到就 `killall pkd` 再查;`scripts/install-findersync.sh` 已内置处理。

## DEV-007: LaunchServices 残留旧路径插件记录导致 pkd 拒绝扩展
- **Pitfall:** pkd 解析到无效路径(如 build 目录里的旧 app/appex)而拒绝扩展。
- **Cause:** LS 记录了旧路径的插件(重复构建产物留下的登记),优先于新路径被解析。
- **Prevention:** 先 `lsregister -u` 所有旧路径的 app 及其 appex,再只注册 /Applications;`install-findersync.sh` 已内置处理。

## DEV-008: macOS Sequoia/Tahoe 覆盖安装后 Finder 右键菜单消失(陈旧扩展实例)
- **Pitfall:** app 重建/覆盖安装后,扩展显示已启用(`FIFinderSyncController.isExtensionEnabled` 为 true、设置页绿色),但 Finder 右键菜单不出现;手动关闭再开启一次即恢复。
- **Cause:** pkd 与 Finder 仍持有旧扩展实例;已程序化复现(`pluginkit -e ignore` → `-e use` 的 election 循环)。
- **Prevention:** 主 app 启动自愈走 `Zeroflow/Services/FinderSyncReloader.swift`,设置页有「刷新右键菜单扩展」按钮;安装用 `scripts/install-findersync.sh`(支持 `--reload-only` 仅重载)。

## DEV-009: Finder 右键菜单位置无法调整
- **Pitfall:** 尝试把扩展的右键菜单项放到菜单顶部/中间,无法实现。
- **Cause:** 菜单项被 Finder 硬编码在菜单底部,无 API 可调整位置。
- **Prevention:** 放弃调序,接受固定位置。

## DEV-010: 不要用 `UserDefaults(suiteName:)` 读 App Group
- **Pitfall:** 沙盒扩展里读不到主 app 写入的设置,cfprefsd 报 `Container: (null)`。
- **Cause:** cfprefsd 在沙盒扩展进程里无法解析 App Group suite。
- **Prevention:** 主 app(非沙盒但带 `com.apple.security.application-groups`)与扩展双方直接读写 group container 里的 `finder-sync-settings.plist` 文件(见 `Models/SettingsStore.swift` 与 `FinderSyncExtension/FinderSync.swift`)。

## DEV-011: 沙盒里 `homeDirectoryForCurrentUser` 返回容器目录,扩展不监控任何路径
- **Pitfall:** 直接把 `FileManager.default.homeDirectoryForCurrentUser` 当 `directoryURLs` 会让 Finder 完全不监控用户路径,`menu(for:)` 永不触发。
- **Cause:** 沙盒进程里该 API 返回 `~/Library/Containers/<bundle>/Data`,不是真实家目录。
- **Prevention:** 用 `URL(fileURLWithPath: "/Users/\(NSUserName())")` 拼真实家目录。

## DEV-012: `NSMenuItem.representedObject` 跨 XPC 不保留
- **Pitfall:** 点击菜单动作回调里 `sender` 拿不到自定义 `representedObject`,报 `createFile: invalid sender`。
- **Cause:** FinderSync 菜单项动作跨 XPC 传递,representedObject 不会被保留。
- **Prevention:** 在动作里用 `FIFinderSyncController.default().targetedURL()` / `selectedItemURLs()` 重新推导目标(`targetDirectory()`),不要依赖 sender。

## DEV-013: FinderSync 右键目标目录无写权限
- **Pitfall:** 右键目录里新建文件失败,日志 `deny file-write-create`。
- **Cause:** `files.user-selected.read-write` 权限不覆盖 FinderSync 右键目标。
- **Prevention:** 加 `com.apple.security.temporary-exception.files.home-relative-path.read-write`(值 `["/"]`,覆盖整个家目录;不入 App Store 可接受)。

## DEV-014: 扩展里不能直接执行子进程命令(继承沙盒),需转交主 app 代执行
- **Pitfall:** 扩展里 `Process` 拉起终端/pty 类命令(如 `wezterm start`)EPERM 秒退。
- **Cause:** 子进程继承扩展的沙盒约束。
- **Prevention:** 自定义命令不在扩展执行:扩展把请求写进 group container 的 `finder-command-*.plist` 并广播分布式通知(沙盒发通知不能带 userInfo),由非沙盒主 app `Zeroflow/Services/FinderCommandRunner.swift` 代执行(启动时消化积压请求,超过 30s 的丢弃;扩展侧主 app 未运行时会拉起它)。

## DEV-015: 新 SDK(27.0)下 EventKit/CG/NSScreen 的 API 形态变化
- **Pitfall:** 灵动岛功能首编四处报错:`store.events(from:to:calendars:)` 不存在、`EKCalendar.color` 按 CGColor 用报类型错、`NSScreen.auxiliaryTopLeft/RightArea` 按 non-optional 用报可选错、`CGEvent.keyCode` 属性不存在。
- **Cause:** EventKit 便捷查询只剩谓词版 `events(matching:)`;macOS 上 `EKCalendar.color` 一直是 NSColor(iOS 才是 CGColor);辅助区矩形在新 SDK 声明为可选;CGEvent 键码要走 `getIntegerValueField(.keyboardEventKeycode)`。
- **Prevention:** 遇到系统框架 API 编译错先查本机 SDK 头文件(`/Applications/Xcode.app/.../System/Library/Frameworks/<F>.framework/Headers/*.h`)再改实现,不要凭记忆按 iOS 或旧文档签名写。

## DEV-016: `animator().setFrameOrigin(_:)` 对 NSWindow 无效
- **Pitfall:** 灵动岛面板从刘海后方 12pt 滑入,用 `animator().setFrameOrigin(final)` 做动画,面板最终停在起始位置(比目标高 12pt),像是"贴不到刘海下缘"。
- **Cause:** NSWindow 经 animator 代理可动画的属性只有 frame/alphaValue/bounds 等,`setFrameOrigin:` 不在其中,调用静默无效。
- **Prevention:** 窗口位移动画用 `animator().setFrame(_:display:)`(先 setFrame 到起始位置);或只动画 alphaValue/内容视图 transform。

## DEV-017: 窗口背景液态玻璃/磨砂的边界(macOS 26+)
- **Pitfall:** `CGWindowListCreateImage` 在 macOS 15 已 obsoleted(SDK 15+ 直接编译错误),系统磨砂(NSVisualEffectView)公开 API 不暴露模糊半径;`NSGlassEffectView` 的 `alphaValue` 会连 contentView 内容一起变透明,不能当「背景不透明度」用。
- **Cause:** 液态玻璃透明度只能经 `tintColor` 的 alpha(染色深浅)控制;内容必须嵌 `contentView` 才保证在玻璃内(任意兄弟子视图 z 序无保证)。
- **Prevention:** macOS 26+ 面板背景用 `NSGlassEffectView`(cornerRadius 对齐屏幕圆角,macOS 上无公开 API 查屏幕圆角,取 16);旧系统回退 `NSVisualEffectView(.hudWindow)`。若真需要面板背后区域的模糊快照,须 SCScreenshotManager + `SCContentFilter(display:excludingWindows: [自身 SCWindow])` 整屏捕获后裁剪再 `CIGaussianBlur`(输入先 `clampedToExtent()` 防边缘晕边);SCShareableContent 枚举耗时数百毫秒,需缓存。

## DEV-018: ad-hoc 签名的扩展对 App Group 容器只读,写请求文件 EPERM,「打开终端」静默失效
- **Pitfall:** 「访达右键 → 打开终端」点击毫无反应,而「新建空文件」(纯扩展内动作)正常,极具迷惑性。扩展 os_log 仅报 `submit: failed to write`,底层为 `NSCocoaErrorDomain Code=513 / NSPOSIXErrorDomain Code=1 (EPERM)`;group container 里从未出现 `finder-command-*.plist`,主 app 日志零条 `finderCommand`。GitHub CI 的 ad-hoc 包必现,Team 签名构建正常。
- **Cause:** ad-hoc 签名(`TeamIdentifier=not set`)的沙盒扩展,系统不认可其 `com.apple.security.application-groups` entitlement,沙盒只放行 group container 的**读**、**写**被拒(EPERM)。扩展读设置正常所以菜单/文案都正常,只有「写请求文件」这一步死;非沙盒主 app 不受沙盒中介、读写都正常——这种读写不对称掩盖了问题。Team 签名(真证书)即可放行写,实测无需嵌入 provisioning profile。
- **Prevention:** 涉及 FinderSync 扩展的产物必须 Team 签名(`CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=8NHN73Q43T`)。CI 已加 `Import signing certificate` 步骤从 secrets 导入证书,发 tag 时断言 appex `TeamIdentifier=8NHN73Q43T`;无 secrets 回退 ad-hoc 仅限编译检查(那种包右键命令功能无效)。排障用 `log show --info --predicate 'subsystem == "com.zeroflow.app.finderSync"'`(必须 `--info`,否则只剩 error 级);`CustomCommandRunner.submit` 的失败日志已改为输出真实 NSError + 完整路径(之前只打布尔,排障信息为零)。

## DEV-019: MediaRemote 私有框架在 macOS 15.4+ 的可用读取路径与 JXA 细节
- **Pitfall:** `MRMediaRemoteGetNowPlayingInfo` C 函数在 15.4+ 被封(符号在但回调永不来);legacy `MediaRemote` ObjC 类在 macOS 27 已不存在;JXA 里 NSBundle 调用 `-loadBundle` 报 "not a function"(方法名是 `-load`)。
- **Cause:** Apple 逐步收紧 MediaRemote;唯一仍开放的进程内读取路径是 `MRNowPlayingRequest` 类属性(`localNowPlayingItem`/`localNowPlayingPlayerPath`),对无自动化授权的进程也开放(osascript JXA 与进程内 KVC 均实测可用)。播放控制 `MRMediaRemoteSendCommand` 的 dlsym 符号仍存在。
- **Prevention:** 读取优先进程内 `(NSClassFromString("MRNowPlayingRequest") as AnyObject).value(forKey:)`(KVC 前一律 `responds(to:)` 守卫,未知 key 会抛 ObjC 异常崩溃);类缺失再降级 `osascript -l JavaScript` 子进程(bundle.load 而非 loadBundle,数值字段经 `.js` 转 String 再解析);控制走 dlsym `MRMediaRemoteSendCommand`,Swift block 参数用 `@convention(c)`(命令号 toggle=2/next=4/previous=5)。app 名/图标从 `playerPath.client.displayName/bundleIdentifier` + `NSWorkspace.runningApplications` 取,info dict 不含封面字节。

## DEV-020: IOKit 统计键的 C 宏不进 Swift,host_statistics64 计数要从结构体尺寸算
- **Pitfall:** `kIOBlockStorageDriverStatisticsKey` 等按符号用报 "cannot find in scope";内存采样 count 直接用常量或拍脑袋会返回 KERN_INVALID_ARGUMENT。
- **Cause:** 这些键是 IOKit 头文件里的字符串宏(`#define kIOBlockStorageDriverStatisticsKey "Statistics"`,读/写键为 `"Bytes (Read)"`/`"Bytes (Write)"`),Swift 侧不导入;`HOST_VM_INFO64_COUNT` 也是宏。
- **Prevention:** IOKit 键直接写字符串值(真实值查 SDK 头文件 `IOKit.framework/Headers/storage/IOBlockStorageDriver.h`);`mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)` 自算 count。资源监控数据源速记(macOS 27 实测,全免 root):CPU=host_processor_info 两次 ticks 差值;内存已用=active+inactive+speculative+wired+compressor−purgeable−external(≈活动监视器「内存已用」,≠top 的 PhysMem used=总−free,后者含缓存文件,别拿来对数);网络=sysctl NET_RT_IFLIST2 的 if_data64 逐接口差值(排除 IFT_LOOP);磁盘=IOService("IOBlockStorageDriver") 注册表 "Statistics" 的读写字节差值;GPU=IOAccelerator "PerformanceStatistics" 的 "Device Utilization %"(本机存在,瞬时值无需差分;备用 "GPU Activity(%)")。`swiftc | head` 会因管道 SIGPIPE 杀掉编译器且 `&&` 拿到的是 head 的退出码,验证脚本要重定向到文件再 grep。

## DEV-021: macOS 窗口 frame 弹簧动画无公开 API,需主线程定时器积分实现
- **Pitfall:** 灵动岛面板要做 iPhone 式「从刘海长出/缩回」的弹簧动画,`NSAnimationContext` 只支持贝塞尔 `CAMediaTimingFunction`,`CASpringTimingFunction` 在 macOS 不公开,窗口 frame 无法用系统弹簧曲线动画。
- **Cause:** NSWindow 经 animator() 可动画的属性走 Core Animation 但只暴露贝塞尔曲线;UIKit 语义的弹簧参数(response/dampingFraction)动画必须自己积分。
- **Prevention:** 主线程 120Hz `Timer` 对弹簧微分方程半隐式欧拉积分(k=(2π/response)²,c=2ζ√k)后直接 `setFrame(_:display:)`(dt 远小于稳定域 2/ω 不会发散);打断续接需用各分量当前值与速度重建弹簧、作废旧动画的 completion(否则收起的 orderOut 会在重展开后误触发);Timer 必须加进 `.common` mode,否则面板按钮的事件跟踪期间动画冻结。参考 `NotchPanelView.swift` 的 `NotchSpringAnimator`。

## DEV-022: 窗口弹簧动画里 alpha 走独立快速淡入,会把「生长」动画感知成「从一侧滑入」
- **Pitfall:** 灵动岛面板做「从刘海长出」弹簧动画,frame 用弹簧、alpha 用独立的 0.15s 快速淡入:用户看到的是半透明面板从一侧快速滑到位 + 渐显,完全不是「从刘海逐渐长大」,方向感全错。
- **Cause:** 弹簧位移前 ~15% 时间就走完 85% 路程,独立淡入结束时可变大半已展开;肉眼能捕捉的只剩后段残留位移( leading 边缘扫过),感知成滑入。弹性动画里透明度与几何分开调,时序感知必然错位。
- **Prevention:** 「刘海生长/缩回」动画全程不透明(深色 HUD 起点盖住黑色刘海,出现/消失都无感,形状渐变本身就是全部视觉),透明度完全不参与动画;若别的窗口必须有淡入淡出,alpha 须由几何进度推导而非独立时长,打断时以当前值续接。

## DEV-023: 打断在途窗口动画时,严禁 setContentSize/setFrame 直接改窗口尺寸
- **Pitfall:** 面板「收起弹簧未播完→再次弹出」走打断路径时调用了 `setContentSize`(最终尺寸):窗口几何绕过弹簧直接跳变(尺寸瞬间到位、按原点锚定另一侧瞬移),随后位置再弹簧滑到位 → 用户看到「全尺寸面板从屏幕一侧平移到中间」,与弹簧动画预期完全不符。
- **Cause:** `setContentSize`/`setFrame` 是瞬时几何赋值;打断场景窗口处于中间态,直接改尺寸等于把「在途位移」换成「瞬移 + 平移收尾」。`setContentSize` 还按窗口原点(左下)锚定缩放,另一侧边缘瞬移,平移感更明显。
- **Prevention:** 打断动画只做一件事——弹簧目标重定向(以当前值/速度续接);任何路径都不要在动画在途时用 `setContentSize`/`setFrame` 改尺寸。`present` 的起始定位(setFrame 刘海矩形)只放在「窗口不可见」的全新展开分支。参考 `NotchPanel.present`。

## DEV-024: NSHostingView 经约束/glass.contentView 挂载会把窗口宽高反向钳死
- **Pitfall:** 灵动岛面板弹簧 setFrame 每帧改窗口尺寸,内容却不动:只有原点生效,宽高被「静默锁死」在 SwiftUI 的固定尺寸上,「从刘海生长」退化成全尺寸面板平移。
- **Cause:** 把 `NSHostingView` 赋给 `NSGlassEffectView.contentView` 或对 hosting 用 Auto Layout 约束后,SwiftUI 固定 `.frame` 尺寸会经约束链/玻璃层反向钳制窗口的 contentLayoutGuide,窗口 setFrame 的宽高分量被覆盖。
- **Prevention:** hosting 必须以 `addSubview` + `autoresizingMask = [.width, .height]` 跟随宿主视图,宿主铺满 contentView;绝不能用约束挂载。参考 `NotchPanel.makeContentView`。

## DEV-025: NSView 没有 viewDidChangeBounds 可重写,bounds 变化的回调是 layout()
- **Pitfall:** 想在窗口每帧改尺寸时同步重建 CAShapeLayer 遮罩路径,重写 `viewDidChangeBounds()` 直接编译错 "method does not override any method from its superclass"(AppKit swiftinterface 里根本没有这个方法)。
- **Cause:** 该方法名与 UIView 的直觉混淆;NSView 的几何变化回调就是 `layout()`,bounds 尺寸变化时 AppKit 会触发它。
- **Prevention:** 跟随窗口/容器尺寸的 layer 工作(遮罩路径、子图层 frame)统一放 `override func layout()`;若担心首帧,可在初始化时用已知目标尺寸先算一遍。CAShapeLayer 每帧改 path 记得设 `actions = ["path": NSNull(), ...]` 禁隐式动画,否则遮罩滞后于弹簧。

## DEV-026: layer-backed NSView 的图层坐标系跟随 isFlipped,非 flipped 视图 = y 向上
- **Pitfall:** 手写 CGPath 给 NSView 的 layer 做遮罩(iOS 思维默认左上原点 y 向下),在 macOS 上路径垂直翻转,圆角上下颠倒。
- **Cause:** macOS 图层坐标系不是固定 y 向下:`isGeometryFlipped` 跟随视图的 `isFlipped`(默认 false → 原点左下、y 向上;flipped 视图 → true)。与 UIKit 相反方向的坑。
- **Prevention:** 写路径前先确认宿主视图 isFlipped;非 flipped 视图按 y 向上写(底边在 y=0)。实测方法:`swift` 脚本建 `NSView` + `wantsLayer = true`,打印 `layer?.isGeometryFlipped`(注意 Swift 里是 `isGeometryFlipped` 不是 `geometryFlipped`,后者编译错)。
