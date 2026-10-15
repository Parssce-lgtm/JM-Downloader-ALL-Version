# JM-Downloader ALL Version

JMComic / PicACG 漫画下载工具，iOS 与 Android 为独立原生应用，当前版本统一为 **1.8.0**。源码采用 MIT License。

- **iOS**：最低 iOS 16；SwiftUI 原生 Picker、分页、导航与按钮。iOS 16–18 使用传统界面，iOS 26 及以上由系统呈现液态玻璃。
- **Android**：最低 Android 7.0（API 24）；Jetpack Compose Material 3。Android 12 及以上支持 Material You 动态配色，旧系统使用 Material 3 默认配色。
- 两个平台均支持 JM/PicACG 登录、收藏、标签推荐、搜索、下载、图片解扰与 PDF 合成；账号、平台、收藏标签缓存和下载队列独立保存。

## 下载与安装

请在 [Releases](https://github.com/Parssce-lgtm/JM-Downloader-ALL-Version/releases) 下载对应安装包。Android APK 可直接安装；iOS 未签名 IPA 需要自行签名。两种应用不共享账号凭据和本地数据。

## 使用

首次在设置中选择平台并登录，按需要修改 API 主机、图片主机及无需认证的 HTTP CONNECT 代理。推荐根据收藏中的完整标签生成；首次读取详情需要等待，之后复用账号独立的持久标签缓存。

- 普通搜索：漫画名、编号或模糊标签；`JM12345` 可直接搜索 JM 编号。
- `#纯爱`：只匹配完整标签，统一简繁、大小写和全半角。
- `纯爱+彩漫` / `#纯爱+#彩漫`：漫画必须同时含有全部完整标签。每批检查候选的完整详情；有后续分页时可继续加载。
- 收藏与推荐的搜索分别保留；刷新继续当前查询，切页不会自动退回推荐。
- 收藏的“查看已下载 / 查看已隐藏”互斥，并且只显示对应状态。
- 已排除作品不会随“全部开始”或自动下载启动；单独下载需要确认。删除任务及缓存保留已经输出的 PDF。

## PDF 预览

默认隐藏，在 **设置 → 开发者功能 → 预览** 开启，入口位于顶部最左侧。开发者功能在主题、缓存设置下方、关于上方单独显示。

PDF 直接放入软件文件根目录，不需要新建文件夹。iOS：文件 App → 我的 iPhone → JM downloader；Android：应用外部文件根目录，具体路径在“缓存与文件”显示。新版 Android 可使用预览页“更多 → 导入 PDF”通过系统文件选择器复制到根目录。

支持按下载时间、页数、文件大小排序，按漫画名、JM 号以及 `#完整标签` 搜索。外部导入 PDF 没有标签元数据时无法按标签搜索；应用导出的文件可关联已保存的漫画资料。阅读页面按需渲染。

## 构建

### iOS

使用 macOS 与 Xcode 26 或更新版本打开 `JMDownloader.xcodeproj`，设置自己的 Development Team 和 Bundle ID，或运行：

```sh
bash scripts/build-unsigned-ipa.sh
```

### Android

使用 JDK 17、Android SDK 35：

```sh
cd android
bash gradlew testDebugUnitTest lintRelease assembleRelease
```

发布签名使用 `RELEASE_STORE_FILE`、`RELEASE_STORE_PASSWORD`、`RELEASE_KEY_ALIAS` 环境变量；仓库不包含私钥、证书密码或用户登录信息。没有签名配置时本地 Release 输出为未签名 APK。GitHub Actions 使用加密 Secrets 生成签名 APK。

工作流 `Build 1.8 iOS and Android` 构建两个平台，仅测试 Android：JVM 单元测试、Lint、Android 7/API 24 与 Android 12/API 31 设备检查；iOS 本轮只编译，不重复运行测试。

发布验证记录：[1.8.0 构建与 Android 检查](https://github.com/Parssce-lgtm/JM-Downloader-ALL-Version/actions/runs/38808618062)。真实账号和 iOS 新增预览功能的真机操作未单独实测。

## 注意事项

服务端为非官方接口，可能变更或限制线路。自动测试不代表真实账号、所有网络线路和真机后台均已验证。仅保存自己有权访问的内容。

Android 下载使用前台服务和通知，应用被强行停止或系统限制执行时，可重新打开并继续任务。Android 15 的前台数据同步时间限制同样适用；未完成任务保留图片缓存。登录会话通过 AndroidKeyStore 加密保存，密码不写入本地快照。iOS 后台行为仍由系统调度。

## 更新记录

### 1.8.0 / iOS Build 25

- iOS 底部共享提示卡片在下载、收藏与推荐之间保持固定材质和位置，仅文字渐隐渐显；切换 PDF 预览时整张卡片平滑淡出、淡入，隐藏期间不接受点击。
- 右上角设置图标随当前主题配色，与下载按钮保持一致；继续使用系统原生按钮。
- 验证记录：[普通三页提示卡片检查](https://github.com/Parssce-lgtm/JM-Downloader-ALL-Version/actions/runs/38816424907)、[PDF 预览往返检查与 IPA 构建](https://github.com/Parssce-lgtm/JM-Downloader-ALL-Version/actions/runs/38819683781)。

### 1.8.0

- 新增独立 Android 应用，最低 Android 7，采用原生 Material 3 / Material You。
- 新增默认关闭的本地 PDF 预览、排序、漫画名 / JM 号 / 精确标签搜索。
- iOS 顶部保留系统 SwiftUI 控件，移除分页外额外叠加的切换动画。
- 仓库更名为 JM-Downloader ALL Version，统一两个平台版本号。

### 1.7.0

- 完善收藏与推荐搜索、多标签匹配、下载排除名单、共享底部提示与系统原生界面。

协议参考和第三方许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
