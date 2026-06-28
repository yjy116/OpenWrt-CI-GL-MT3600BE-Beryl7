# OpenWrt-CI-GL-MT3600BE-Beryl7

This repository builds custom OpenWrt firmware for the GL.iNet GL-MT3600BE
Beryl 7 with GitHub Actions.

It is migrated from the previous ImmortalWrt CI project, but the firmware source
tree now defaults to upstream OpenWrt main:

- Source tree: `https://github.com/openwrt/openwrt.git`
- Default source branch: `main`
- Target: `mediatek/filogic`
- Device profile: `glinet_gl-mt3600be`
- Device DTS: `mt7987a-glinet-gl-mt3600be`

## Why This Is A Source Build

The package set is copied from the existing ImmortalWrt CI project and includes
packages that need more than ImageBuilder can provide, especially `daed` with
BPF/BTF kernel options and several third-party LuCI apps. This repository
therefore uses a full OpenWrt source build.

## Feeds Strategy

The default `FEEDS_PROFILE` is `immortalwrt-compatible`.

That means:

- OpenWrt source code comes from `openwrt/openwrt@main`.
- The `packages` and `luci` feeds come from ImmortalWrt-compatible feed forks.
- This preserves the plugin set from the old project, including packages that
  are not available in OpenWrt official feeds.

An `openwrt-official` feed profile is also included for experiments, but it is
expected to drop or miss some packages from `Config/GENERAL.txt`.

## MT3600BE WiFi Driver Pin

The workflow pins `mt76` to the known-good snapshot used by build #35 by
default:

```text
PKG_SOURCE_DATE:=2026-03-21
PKG_SOURCE_VERSION:=018f60316d4dd6b4e741874eda40e2dfaa29df3b
```

中文：`openwrt/openwrt` 在 `304525e75451..f5d928e52a5f` 之间把 mt76
升级到 `2026-06-23` 快照。GL-MT3600BE 的 mt7996 WiFi 在该新快照上出现
连接客户端后异常，因此默认只锁定 mt76，并同步恢复该旧快照在 Linux 6.18
下需要的兼容补丁，无需回退整个 OpenWrt 主线。要测试上游最新 mt76，可以在手动触发 workflow 时关闭
`Pin mt76 to the #35 known-good WiFi snapshot`。

## Workflows

- `MT3600BE-TEST`: fast validation; prepares feeds, injects third-party
  packages, runs `make defconfig`, and uploads config/log artifacts.
- `MT3600BE`: full firmware build; optionally publishes a GitHub prerelease.
- `Auto-Build`: scheduled full build.
- `Clear-Cache`: manual GitHub Actions cache cleanup.

Recommended first run:

1. Run `MT3600BE-TEST`.
2. Inspect the uploaded `.config`, `build.log`, and `dropped-packages.txt` if it
   exists.
3. Run `MT3600BE` after the test workflow is clean enough.

## Package Customization

Most package changes should happen in:

```text
Config/GENERAL.txt
```

Device selection lives in:

```text
Config/MT3600BE.txt
```

Extra kernel/BPF options for `daed` live in:

```text
Config/MT3600BE.kernel.txt
```

Third-party packages are declared with `@vendor` comments in `Config/GENERAL.txt`.
The build script only fetches a vendor package when the corresponding
`CONFIG_PACKAGE_*` entry is enabled.

## Flashing Notes

Do not commit Wi-Fi passwords, VPN keys, Tailscale auth keys, DDNS tokens, or
other device secrets to this public repository.

For first tests, keep a copy of the official GL.iNet firmware and confirm the
router recovery process before flashing a custom image.

中文：不要在 GL.iNet U-Boot 恢复页面里刷
`openwrt-mediatek-filogic-glinet_gl-mt3600be-squashfs-sysupgrade.bin`。这个
文件是给 GL.iNet Web UI、OpenWrt LuCI 或 OpenWrt shell 里的 `sysupgrade`
流程使用的；在 U-Boot 恢复模式里刷入可能无法正常自动启动。

中文：如果路由器已经进不了系统，优先用 GL.iNet 官方固件通过 U-Boot 恢复
回可启动状态，再从 GL.iNet Web UI 或 OpenWrt 里刷本仓库生成的 sysupgrade
镜像。

From GL.iNet Web UI, OpenWrt LuCI, or OpenWrt shell, a clean sysupgrade looks
like this:

```sh
sysupgrade -n openwrt-mediatek-filogic-glinet_gl-mt3600be-squashfs-sysupgrade.bin
```

Remove `-n` only when you intentionally want to preserve compatible settings
from the current firmware.

This project also builds `initramfs-kernel.bin` for recovery/testing parity with
official OpenWrt snapshots. Treat it as a recovery or temporary-boot helper, not
as the normal permanent upgrade path.
