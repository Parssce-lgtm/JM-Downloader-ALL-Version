# JM downloader

原生 SwiftUI / UIKit iOS 26 应用，针对 iPhone 17 Pro Max 的安全区域、自适应布局与动态字体设计。版本 1.0.0。

- 右上角设置 → 账号设置：登录、切换钥匙串账号、API 域名、HTTP CONNECT 代理、图片并发、刷新收藏、记住账号、文件目录、隐藏已完成/已删除任务。
- 上方收藏 / 推荐，下方约半屏下载状态与提示记录。搜索、收藏夹、更多依次排列；选择漫画 / 不再自动下载均从左侧展开勾选。
- 长按暂停、继续、不再自动下载、删除任务；批量删除保留已经导出的 PDF。
- 设置 → 漫画设置管理自动下载排除名单。刷新收藏自动补充队列可独立开关。
- URLSession 后台图片传输、持久化队列、图片解扰、原生 PDF 输出。账号切换保留各自的收藏与排除名单。

## 构建

用 Xcode 26 或更新版本打开 `JMDownloader.xcodeproj`，选择 `JMDownloader`。真机安装设置自己的 Development Team 与 Bundle ID。

```sh
bash scripts/test-ios.sh
bash scripts/build-unsigned-ipa.sh
```

GitHub Actions 手动执行 Build iOS，先测试再生成 `JM-downloader-unsigned.ipa`。未签名 IPA 需要自行签名后安装。默认不包含开发者证书、个人账号或个人漫画文件。

## 使用

首次进入右上角设置登录。API 域名可填多个 HTTPS 主机，以逗号分隔。代理仅支持无需认证的 HTTP CONNECT 代理（主机、端口），使用系统 Network / URLSession API；SOCKS 可由系统 VPN 提供。网络设置保存后重新登录；后台传输代理在下次启动时生效，图片域名在任务暂停再继续时更新。

默认 PDF 在“文件 → 我的 iPhone → JM downloader”。选择其他目录使用系统文件选择器与安全作用域书签；外部云盘不可用时任务显示失败并保留缓存，可重试。删除任务不会删除已导出的 PDF；可在文件 App 自行管理。

后台图片传输由 iOS 调度。应用被用户强制划掉时系统会取消传输，重新打开恢复未完成任务。章节清单准备、推荐计算及 PDF 合成需要应用获得执行时间；不承诺锁屏后永久运行。推荐为基于收藏标签的候选（最多采样 12 本收藏），没有收藏时读取热门列表。

服务端 API 非官方，可能随服务端升级变化。原版 jmcomic 2.7.7 的协议算法参考与 MIT 许可见 `THIRD_PARTY_NOTICES.md`。
