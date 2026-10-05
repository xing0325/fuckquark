![FUCK QUARK — 用自己喜欢的方式，看自己的网盘。](docs/cover.png)

# fuck quark

**把夸克网盘接到 Mac，用 IINA 播放原文件。**

[下载 Mac 安装包](https://github.com/xing0325/fuckquark/releases/latest) · macOS 13+ · Apple Silicon / Intel 双架构

不想每次看剧都翻一长串文件名，也不想围着网页播放器的会员档位转。所以有了这个私人影院：打开片库、点海报、选一季，再点一集就播。署名：`xing0325/fuckquark`。

![片库首页](docs/library.png)

## 已经能做什么

- 在本机启动只读 WebDAV 服务，访问自己的夸克网盘。
- 把原文件交给 IINA 流式播放，不必先下载完整一集。
- 按剧、季、集浏览，搜索当前季，记录最近打开的剧集。
- 匹配同目录的外挂字幕；视频加载后自动加载并选中字幕。
- 原生 SwiftUI 界面，自动显示所选目录里的影视文件夹；三部预设剧集有专属海报，其他文件夹使用通用封面。
- 内置夸克登录窗口、可视化目录选择和 IINA 官网安装入口。

![剧集与外挂字幕](docs/wire.png)

## 怎么连接

**夸克网盘 → quarkdrive-webdav（本机）→ fuck quark 片库 → IINA**

当前界面通过本地 HTTP/WebDAV 地址播放，不依赖 Finder 挂载卷，避免旧版本 Finder 挂载的兼容问题。它不会把网盘全部同步到硬盘。

## 画质测试

同一份《火线》S01E01，在一次账号与网络环境下的结果：

| 播放路径 | 视频分辨率 | 视频流帧率 |
| --- | --- | --- |
| 本项目 / 原文件 | 1920 × 1080 | 标称 23.976 fps |
| 夸克网页接口默认返回的转码版本 | 1440 × 810 | 抽样解码 23.976 fps |

原片下载约五分钟后进行了本地解码验证，临时视频已删除。网页转码样本和原片都约 24 帧。此测试没有测量浏览器播放过程中的丢帧，也没有验证 SVIP 的 60 帧功能；不能据此认定平台故意降帧。实际画质、帧率与流畅度仍取决于原文件、网络及设备。

## 安装与开始播放

1. 从 [Releases](https://github.com/xing0325/fuckquark/releases/latest) 下载 `fuckquark-0.2.0-universal.dmg`，把应用拖进 Applications。
2. 打开应用，点击“登录夸克”，在官网窗口扫码登录，再点“登录完成”。
3. 浏览到自己的影视根目录，点击“使用这个目录，进入片库”。没有 IINA 时，点击“安装 IINA”即可从官网下载并安装。
4. 点海报选剧，再点一集播放。外挂字幕和视频放在同一目录，用相同文件名主体或对应的 SxxExx 集号。

安装不需要终端、Python 或开发环境。已有 IINA 不会覆盖；新安装的 IINA 位于 `~/Applications/IINA.app`，下载后会检查官方开发者签名。应用只读取自己的网盘。

**首次打开：此版本未做 Apple Developer ID 签名和公证。** 如果 macOS 拦截，确认下载来源后，由用户在「系统设置 → 隐私与安全性」选择「仍要打开」。不需要关闭系统安全保护。完整步骤随 DMG 附带。

支持 macOS 13+，包含 arm64 与 x86_64 主程序和对应网盘组件。Apple Silicon 已实测；Intel 尚未在实机验证。退出片库会停止本应用启动的网盘服务，播放时请保持片库开启。

登录过期或更换目录，打开左下角「网盘与播放器」重新设置。Cookie 只保存在本机私密目录；不会上传给项目作者。

## 从源码构建

需要 Xcode Command Line Tools。分别下载上游 quarkdrive-webdav v1.3.9 的 arm64 与 x86_64 二进制，放到 `build/backends/arm64/` 和 `build/backends/x86_64/`。然后运行：

```bash
bash scripts/build.sh "$PWD/build/backends"
bash scripts/package.sh
```

应用输出在 `build/fuck quark.app`，DMG 在 `dist/`。默认使用本机 macOS SDK，可通过 `SDKROOT` 指定与编译器匹配的 SDK。

```bash
bash scripts/test.sh              # 目录识别、字幕配对、配置权限
bash scripts/test.sh --installer  # 额外实测官网下载、签名校验及临时安装
```

## 后续计划

- Apple Developer ID 签名和公证、Intel 实机兼容验证。
- 更多影片元数据与海报识别。
- 播放进度同步。当前记录的是最近打开的剧集，不是跨设备进度。

## 项目组成与致谢

- [quarkdrive-webdav](https://github.com/chenqimiao/quarkdrive-webdav)：连接夸克网盘，本项目启动其独立进程。
- [IINA](https://github.com/iina/iina)：播放原文件，通过 mpv IPC 加载外挂字幕。
- SwiftUI / AppKit：片库、剧集页面和本机应用。
- TVmaze：剧集元数据与海报来源，记录见 `Resources/posters/sources.json`。海报、剧名和商标属于各自权利人；本项目不提供影视文件或分享链接。

账号 Cookie、密码、播放列表、观看记录不属于项目源码，不应提交到仓库。WebDAV 只监听 `127.0.0.1:18084`，启用独立密码并以只读模式运行。
