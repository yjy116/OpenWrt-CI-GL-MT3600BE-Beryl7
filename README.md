# OpenWrt-CI-GL-MT3600BE-Beryl7

本仓库用于通过 GitHub Actions 为 GL.iNet GL-MT3600BE / Beryl 7 编译自定义
OpenWrt 固件。

项目从原 ImmortalWrt CI 配置迁移而来，但固件源码默认跟随 OpenWrt 主线：

- 源码仓库：`https://github.com/openwrt/openwrt.git`
- 默认源码分支：`main`
- 默认源码提交：跟随 `main` 最新提交
- 目标平台：`mediatek/filogic`
- 设备 profile：`glinet_gl-mt3600be`
- 设备 DTS：`mt7987a-glinet-gl-mt3600be`

## OpenWrt 源码与稳定回退策略

`MT3600BE` 和 `Auto-Build` 默认跟随 `openwrt/openwrt@main` 最新提交，不再固定到
某一个历史源码版本。这样可以持续拿到上游对 GL-MT3600BE、Linux 内核和基础
软件包的更新；无线驱动则默认使用实机验证过的 mt76 稳定快照。

如果某次 OpenWrt 主线回归导致编译失败或固件异常，手动运行 `MT3600BE` 时可以在
`openwrt_ref` 输入框填写上一次确认稳定的 OpenWrt commit 或 tag。留空则继续跟随
所选 `openwrt_branch` 的最新提交。

手动回退建议按故障范围选择：

- 日常刷机：保持 `使用已验证的稳定版 mt76 WiFi 驱动` 为勾选状态。
- OpenWrt 主线源码编译失败、内核或基础包整体回归：再填写 `openwrt_ref` 固定源码提交。
- 想验证最新上游 WiFi 驱动：保持 `openwrt_ref` 为空，并取消勾选 mt76 稳定快照。

手动运行页面只保留以下 3 个必要选项：

- `OpenWrt 源码分支`：通常保持 `main`，用于持续跟随 OpenWrt 主线。
- `固定 OpenWrt 源码提交或标签`：留空表示使用分支最新版本，填写 commit 或 tag 表示临时回退。
- `使用已验证的稳定版 mt76 WiFi 驱动`：蓝色方框内有勾表示启用稳定驱动，也是日常刷机的推荐设置；取消勾选才会改用 OpenWrt 主线 mt76。

兼容 feeds、Runner 空间清理和 Release 发布策略已经固定在工作流内部。完整构建会自动
清理空间并发布预发行版；只想检查配置时使用 `MT3600BE-TEST`，它不会发布固件。

## 为什么使用源码编译

当前插件集合来自旧的 ImmortalWrt CI 项目，其中包含 Honk、BPF/BTF 内核选项、
第三方 LuCI 应用和若干需要完整源码树参与的包。仅使用 ImageBuilder 很难完整
复现这些功能，所以本仓库使用完整 OpenWrt source build。

## Feeds 策略

默认 `FEEDS_PROFILE` 是 `immortalwrt-compatible`：

- OpenWrt 源码来自 `openwrt/openwrt@main`。
- `packages` 和 `luci` feeds 使用 ImmortalWrt 兼容分支。
- 这样可以保留旧项目里的插件集合，减少从 ImmortalWrt 切换到 OpenWrt 主线时的缺包问题。

仓库也保留了 `openwrt-official` profile 供实验使用，但它可能缺少
`Config/GENERAL.txt` 中的部分插件。

## MT3600BE WiFi / mt76 策略

完整固件构建默认固定到 #35 已验证的 mt76 快照，避免主线 mt76 回归导致可刷固件
出现 WiFi 连接后假死。OpenWrt 主线源码本身仍继续更新，只有无线驱动包使用稳定
快照。2026-10-13 核对时，OpenWrt `main` 的 `package/kernel/mt76/Makefile`
已更新为：

```text
PKG_SOURCE_DATE:=2026-10-08
PKG_SOURCE_VERSION:=467ae2e3f190baf737e15e318906da0dc7d0ab91
```

相比此前的 9 月快照，10 月 6 至 8 日已经合入新的修复：

- [b1bc93f](https://github.com/openwrt/mt76/commit/b1bc93f95379ae1370ad7a32c01b92c022d724ba)：将 WCID 的 `idr_destroy()` 移入锁内，修复并发导致的数据破坏；此前文档中“尚未合入”已不再成立。
- [7ff2f29](https://github.com/openwrt/mt76/commit/7ff2f295a629162867e1ef26e1a7f6d9aae47947)：修正硬件重启时 WCID 清理顺序。
- [d5ead84](https://github.com/openwrt/mt76/commit/d5ead84240fe4f8e1bd0678a3a4b3712069db1f1)：硬件重启完成前拒绝扫描和 ROC 请求。
- [d39a5b5](https://github.com/openwrt/mt76/commit/d39a5b53249cf4bcf7383759f59d81c521d255f9)：在卸载驱动、清理 DMA 之前停用 RX NAPI，避免访问已经清理的资源。

这些修复已进入 [OpenWrt 主线的 mt76 快照](https://github.com/openwrt/openwrt/blob/main/package/kernel/mt76/Makefile)，
但不能等同于 MT3600BE 长时间使用已经验证稳定。
[MT7990 长时性能衰退/失效报告 #1065](https://github.com/openwrt/mt76/issues/1065)
仍未关闭，报告的测试硬件不是本项目的实机；
[WiFi IPv4 NAT 下载性能报告 #1043](https://github.com/openwrt/mt76/issues/1043)
也仍在讨论。它们是风险线索，不足以证明与本机过去的假死是同一个根因。

2026-06-28 实机日志确认：OpenWrt 主线 `r0-23e5161` 上连接 WiFi 后曾触发
`mt7996e ... Message 00130022 timeout`，随后 `napi/phy0-0` 在
`mt7996_mcu_rx_event -> mt7996_queue_rx_skb -> mt76_dma_rx_poll` 中发生 RCU stall。
最近自动构建日志已经确认曾使用 `2026-07-01 / 59676919...` 主线快照，实机刷入后
很快出现 WiFi 假死。上游现在已有新增修复，但本机尚未完成新版驱动长时验证，因此日常
构建默认保持勾选：

```text
使用已验证的稳定版 mt76 WiFi 驱动（推荐；取消勾选则使用 OpenWrt 主线驱动）
```

该兜底模式会把 mt76 固定到 #35 已验证快照：

```text
PKG_SOURCE_DATE:=2026-03-21
PKG_SOURCE_VERSION:=018f60316d4dd6b4e741874eda40e2dfaa29df3b
PKG_MIRROR_HASH:=54a8125453a6fe04c89cf5335bdf0ea16c409361e1e5a79fb339d67cee26df0e
```

它还会同步恢复旧 mt76 在 Linux 6.18 下需要的兼容补丁。这样无需回退整个
OpenWrt 主线，只回退无线驱动包。`push` 和 `Auto-Build` 没有交互输入，因此也默认
使用该稳定快照；需要验证最新驱动时，请手动运行 `MT3600BE` 并取消勾选。

## MTK PPE 硬件流量卸载状态

固件默认启用防火墙软件流量卸载和 MTK PPE 硬件流量卸载，并保留
`kmod-nft-offload`。LuCI 系统概览会显示 CPU、连接跟踪和流量卸载状态：

- `HW Offload On`：UCI 开关已启用，nftables 硬件 flowtable 规则已经生成。
- `Software Flows`：当前进入 Linux 软件 flowtable 的连接数。
- `Hardware Flows`：conntrack 中带硬件卸载标记的连接数。
- `PPE Ready (0 Bound)`：MTK PPE 调试接口已就绪，但刷新页面时没有绑定中的转发流。
- `PPE Unavailable`：系统无法读取 PPE 调试接口，需要继续检查驱动或 debugfs。

PPE 只处理符合条件的路由转发流量，访问路由器自身的 LuCI 页面不会产生 PPE 命中。
验证时应让有线 LAN 客户端持续访问 WAN，再刷新系统概览。为避免重新引入此前的
WiFi 假死问题，本项目不强制启用 mt7996 WED，因此 WiFi 客户端流量不保证显示为
PPE 绑定流。

## Workflows

- `MT3600BE-TEST`：快速验证 feeds、第三方包和最终 `.config`。
- `MT3600BE`：完整固件编译，可在成功后发布 GitHub prerelease。
- `Auto-Build`：定时完整编译。
- `Clear-Cache`：手动清理 GitHub Actions cache。

工作流使用默认运行于 Node.js 24 的官方 `checkout`、`cache` 和
`upload-artifact` Action，避免 Node.js 20 弃用告警。

推荐流程：

1. 先运行 `MT3600BE-TEST`。
2. 检查上传的 `.config`、`build.log` 和 `dropped-packages.txt`。
3. 验证干净后再运行 `MT3600BE` 完整编译。

## 插件定制

常规插件开关主要在：

```text
Config/GENERAL.txt
```

设备选择在：

```text
Config/MT3600BE.txt
```

DAE/DAED/Honk 共用的额外内核和 BPF 选项在：

```text
Config/MT3600BE.kernel.txt
```

### DAEDE 与 Honk + Doona 共存

同时编入 `dae`、`daed`、`luci-app-daede`、`honk` 和 `luci-app-honk`。
“服务 → DAEDE”切换 DAE/DAED；“服务 → Honk”管理 Honk + Doona。
这不是三个同时工作的代理：**三个后端全部默认关闭，同一时刻只允许一个接管流量。**
Doona 已包含在 `luci-app-honk` 中，不是需要另外勾选的 OpenWrt 包。
Honk 是 Rust 实现的新核心，不是简单把原 DAE/DAED 改名。

DAE 和 DAED 均使用 [kenzok8/openwrt-daede](https://github.com/kenzok8/openwrt-daede) 的
`main` 打包源；`Scripts/Daede.sh` 核验版本、核心来源锁定值、SHA256 与中文资源契约。
2026-10-13 核对的两者版本均为 `2026.09.24-r2`，DAEDE 为 `1.15-r9`：

- 独立 DAE：`daeuniverse/dae` 核心，装配时在性能分支基线 `be2b6047eff8...` 上合并官方提交 `6f2f2aa66084...`。
- DAED：`daeuniverse/daed` 前端 `be4ef873c352...` + `dae-wing` 后端 `b089b568649f...`，内嵌同一套 DAE 核心；不是调用另一个已运行的 `dae` 服务。
- 编译从该维护源的 `dae-src`/`daed-src` 发布下载冻结源码并核对 `PKG_HASH`，随后本地 Go/eBPF 编译；源头由 `ci/pins.env` 与装配工作流共同记录。
- DAEDE 自带中文翻译，不添加不存在的 `luci-i18n-daede-zh-cn`；保留内核 BTF，`vmlinux-btf` 只引入包定义消除缺依赖元数据警告，不编译、不安装影子内核 BTF。

本次下载两份实际源码归档并验证 SHA256；独立 DAE 与 DAED 内嵌核心的共有文件中，
只有 `go.mod/go.sum` 不同，独立 DAE 另含 `default.pgo`，其余核心源码内容一致。

Honk + Doona 维持已验证的同一批发布：

- 打包源：[kenzok8/openwrt-honk](https://github.com/kenzok8/openwrt-honk)，固定正式发布 `v2026.10.12-r38236606118`。
- 核心源：[Glassyiris/honk](https://github.com/Glassyiris/honk)，提交 `8b6778cefa12611492187ac2560f014452f0a64a`。
- 前端源：[Zakkaus/doona](https://github.com/Zakkaus/doona)，`0.1.0-beta.20`，提交 `25fc26a7a17697c1c11a3b31f51940966ac86c2f`。
- 上游采用预编译的多架构核心与 Doona 前端归档，本 CI 再将其打包进固件，并非在 Runner 上重新编译 Honk 的 Rust 源码。核心仍标注 alpha，需实机验证，不视为稳定性保证。

`Scripts/Honk.sh` 获取同批 `source-38236606118` 的核心哈希清单、来源证明与前端清单，
先验证 SHA256 再复制到源码树；后续 OpenWrt 下载核心和前端时继续校验归档 SHA256。
没有退回 `staging` 下载地址或 `SKIP` 哈希的路径。更新此插件时，发布标签、打包提交和
三份元数据哈希应成套更新，不要只把 vendor 分支改成 `main`。

Honk 中文翻译直接内置于包中，不添加不存在的 `luci-i18n-honk-zh-cn`。
先初始化管理账户和配置，再手动启动并打开 Doona。
原有 HomeProxy/OpenClash 可保留安装，但使用 Honk 前应停止它们；
上游会检查正在运行的 dae、daed、sing-box、mihomo 等冲突进程，拒绝重复接管流量。
内核继续保留 BTF、sched-bpf、veth、nft-queue 等依赖。

#### 默认关闭与切换方法

`99-proxy-backends-disabled` 在**每次刷入本固件后的首次启动**执行一次，包括保留配置升级：
保留订阅、业务配置和数据库，仅关闭 `dae.config.enabled`、`daed.config.enabled`、
`honk.main.enabled`、`honk.main.boot_enabled`，并禁用三项服务的开机自启。
配置完成后可手动启用其中一个；正常重启不会反复清除用户启用设置。

1. 在当前后端页面停止服务，并取消它的开机自启。
2. 等待进程退出和网络资源清理完成，再到目标页面启动另一个后端。
3. 若提示 `Proxy service conflict` 或 `Proxy transaction busy`，先查看系统日志中 `proxy-service-guard` 的说明，不要同时反复点启动。

`Scripts/ProxyServices.sh` 将公共互斥入口加到三个上游 init 脚本，
`/usr/share/mt3600be/proxy-guard.sh` 以共享 `flock` 锁覆盖整个 init/procd 登记事务，
并检查其它后端的 procd 实例及残留进程。未拿到 PID、等待自动重启的实例也算占用。
启动、重启、重载、开机启动与停止都受保护，防止停止未运行的 DAE 时误删 Honk 的
`dae0/daens` 资源；不会自动停止其它后端，不改写 Honk 的进程身份和管理 API。
DAEDE 原有双后端切换界面保留，Honk 不强行嵌入 DAEDE。

保护范围是本固件的服务启动入口，不覆盖直接手工运行核心二进制或直接调用 ubus 创建实例。
通过外部软件包或插件“更新程序包”功能替换 init 文件会覆盖本地互斥补丁，应通过本仓库
重新编译升级，或在替换后核验补丁仍在。三套核心并存会增加固件体积，但关闭时不会同时占用运行内存。

切换前请导出配置/订阅；DAED 的 `wing.db` 不会自动转换为 Honk 数据库。
Honk 支持在界面重新添加订阅或导入支持的 `.dae` 业务配置。后续保留配置升级会保留
`/etc/config/honk` 与 `/etc/honk/`；升级前仍建议使用 Honk 维护页导出完整备份，
避免仅复制运行中的 SQLite 数据库造成不一致。

第三方包通过 `Config/GENERAL.txt` 中的 `@vendor` 注释声明。只有对应
`CONFIG_PACKAGE_*` 启用时，构建脚本才会拉取 vendor 包。

## 刷机说明

新刷机或恢复出厂后的默认管理地址是 `192.168.18.1`。该设置由首次启动脚本写入；
如果升级时保留了旧配置，现有 LAN 地址不会被强制覆盖。需要应用新默认地址时，使用
`sysupgrade -n` 干净升级，或刷机后恢复出厂设置。

不要把 WiFi 密码、VPN key、Tailscale auth key、DDNS token 或其它设备密钥提交到
这个公开仓库。

不要在 GL.iNet U-Boot 恢复页面里刷：

```text
openwrt-mediatek-filogic-glinet_gl-mt3600be-squashfs-sysupgrade.bin
```

这个文件用于 GL.iNet Web UI、OpenWrt LuCI 或 OpenWrt shell 的 `sysupgrade`
流程；在 U-Boot 恢复模式刷入可能导致设备无法正常自动启动。

如果路由器已经进不了系统，优先用 GL.iNet 官方固件通过 U-Boot 恢复到可启动状态，
再从 GL.iNet Web UI 或 OpenWrt 系统里刷本仓库生成的 sysupgrade 镜像。

在 GL.iNet Web UI、OpenWrt LuCI 或 OpenWrt shell 中，干净升级示例：

```sh
sysupgrade -n openwrt-mediatek-filogic-glinet_gl-mt3600be-squashfs-sysupgrade.bin
```

只有在明确需要保留兼容配置时，才移除 `-n`。

本项目也生成 `initramfs-kernel.bin`，用于恢复或临时启动测试；它不是常规永久升级路径。
