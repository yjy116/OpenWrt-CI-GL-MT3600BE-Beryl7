# OpenWrt-CI-GL-MT3600BE-Beryl7

本仓库用于通过 GitHub Actions 为 GL.iNet GL-MT3600BE / Beryl 7 编译自定义
OpenWrt 固件。

项目从原 ImmortalWrt CI 配置迁移而来，但固件源码默认跟随 OpenWrt 主线：

- 源码仓库：`https://github.com/openwrt/openwrt.git`
- 默认源码分支：`main`
- 目标平台：`mediatek/filogic`
- 设备 profile：`glinet_gl-mt3600be`
- 设备 DTS：`mt7987a-glinet-gl-mt3600be`

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
出现 WiFi 连接卡死。`MT3600BE-TEST` 仍默认跟随 OpenWrt mainline 的 mt76 驱动，
用于继续跟踪上游修复和定位具体坏点。

2026-06-28 实机日志确认：OpenWrt 主线 `r0-23e5161` 上连接 WiFi 后曾触发
`mt7996e ... Message 00130022 timeout`，随后 `napi/phy0-0` 在
`mt7996_mcu_rx_event -> mt7996_queue_rx_skb -> mt76_dma_rx_poll` 中发生 RCU stall。
因此在上游修复前，日常可刷固件建议保持：

```text
Pin mt76 to the #35 known-good WiFi snapshot
```

该兜底模式会把 mt76 固定到 #35 已验证快照：

```text
PKG_SOURCE_DATE:=2026-03-21
PKG_SOURCE_VERSION:=018f60316d4dd6b4e741874eda40e2dfaa29df3b
PKG_MIRROR_HASH:=54a8125453a6fe04c89cf5335bdf0ea16c409361e1e5a79fb339d67cee26df0e
```

它还会同步恢复旧 mt76 在 Linux 6.18 下需要的兼容补丁。这样无需回退整个
OpenWrt 主线，只回退无线驱动包。

定位 mt76 具体坏点时，可以手动填写：

- `Custom mt76 source date`
- `Custom mt76 commit`
- `Custom mt76 mirror hash`
- `Apply old mt76 Linux 6.18 compatibility patches for early bisect commits`

其中 `Custom mt76 commit` 用于测试指定 mt76 commit；`Custom mt76 mirror hash`
可以留空，构建脚本会对自定义 commit 使用 `skip`，适合临时二分测试。较早的 mt76
commit 如果尚未包含 Linux 6.18 兼容改动，需要打开兼容补丁开关。

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
