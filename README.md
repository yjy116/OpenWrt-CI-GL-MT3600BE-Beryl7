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

From OpenWrt, a clean sysupgrade looks like this:

```sh
sysupgrade -n openwrt-mediatek-filogic-glinet_gl-mt3600be-squashfs-sysupgrade.bin
```

Remove `-n` only when you intentionally want to preserve compatible settings
from the current firmware.
