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

- 日常刷机：保持 `默认使用 #35 稳定版 mt76` 为勾选状态。
- OpenWrt 主线源码编译失败、内核或基础包整体回归：再填写 `openwrt_ref` 固定源码提交。
- 想验证最新上游 WiFi 驱动：保持 `openwrt_ref` 为空，并取消勾选 mt76 稳定快照。

## 为什么使用源码编译

当前插件集合来自旧的 ImmortalWrt CI 项目，其中包含 `daed`、BPF/BTF 内核选项、
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
快照。2026-09-04 核对时，OpenWrt `main` 的 `package/kernel/mt76/Makefile`
已更新为：

```text
PKG_SOURCE_DATE:=2026-09-01
PKG_SOURCE_VERSION:=be5ce7910521492d4a2e4ce7ee3843680a46c047
```

同时，上游仍有未合入的 mt76 修复 PR 和未关闭问题需要观察：

- `openwrt/openwrt#24810`：修复 AP interface bring-up 后的崩溃/内存破坏，当前仍为 blocked、未合并。
- `openwrt/mt76#1097`：`mt7996e` 在 `2026.07.01~59676919` 后触发网络不可达，当前仍为 open。
- `openwrt/mt76#1101`：2.4 GHz IoT 客户端触发静默数据面失效，当前仍为 open。
- `openwrt/mt76#1109`：`mt7996_mcu_rx_event` RCU stall 的一个明确原因已关闭修复。

`2026-09-01 / be5ce791...` 已包含 PS-sync 无限循环、TX DMA 映射泄漏、越界访问、
连接监控及 WED 状态清理等多项 `mt7996` 修复，适合继续手动验证。但最新源码中
`mt76_wcid_cleanup()` 的 `idr_destroy()` 仍位于状态锁之外，对应的竞态补丁尚未合入；
在 MT3600BE 实机长时间验证通过前，不把它作为日常固件默认驱动。

2026-06-28 实机日志确认：OpenWrt 主线 `r0-23e5161` 上连接 WiFi 后曾触发
`mt7996e ... Message 00130022 timeout`，随后 `napi/phy0-0` 在
`mt7996_mcu_rx_event -> mt7996_queue_rx_skb -> mt76_dma_rx_poll` 中发生 RCU stall。
最近自动构建日志已经确认曾使用 `2026-07-01 / 59676919...` 主线快照，实机刷入后
很快出现 WiFi 假死。上游虽然继续更新，但相关崩溃修复尚未全部合入，因此日常
构建默认保持勾选：

```text
默认使用 #35 稳定版 mt76；取消勾选可测试 OpenWrt 主线 WiFi 驱动
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

定位 mt76 具体坏点时，可以手动填写：

- `Custom mt76 source date`
- `Custom mt76 commit`
- `Custom mt76 mirror hash`
- `Apply old mt76 Linux 6.18 compatibility patches for early bisect commits`

其中 `Custom mt76 commit` 用于测试指定 mt76 commit；`Custom mt76 mirror hash`
可以留空，构建脚本会对自定义 commit 使用 `skip`，适合临时二分测试。较早的 mt76
commit 如果尚未包含 Linux 6.18 兼容改动，需要打开兼容补丁开关。

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

`daed` 需要的额外内核和 BPF 选项在：

```text
Config/MT3600BE.kernel.txt
```

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
