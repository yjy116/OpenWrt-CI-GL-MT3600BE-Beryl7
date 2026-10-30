# MT7987 WED 3.1 实验移植

**实验版，不是稳定性修复已经验证的日常固件。** 本目录仅供
`experiment/mt7987-wed-6.18` 分支的 `MT3600BE-WED-EXPERIMENTAL` 工作流使用。
不开启实验参数时，日常固件不应用这些补丁，也不强制请求 WiFi WED。

## 固定的评估基线

| 组成 | 来源与提交 |
| --- | --- |
| OpenWrt / Linux 6.18.55 | `openwrt/openwrt@5700101d7c85381889d890dc1d3d001d0b4b6446` |
| 稳定 mt76 | `openwrt/mt76@018f60316d4dd6b4e741874eda40e2dfaa29df3b`，先应用项目原有 002 至 006 兼容补丁 |
| 官方内核参考 | `mediatek/mtk-openwrt-feeds@cc3641f440cbb2f233b930684fa53c079a196fac`，25.12 / Linux 6.12 补丁 |
| 官方无线参考 | `mediatek/softmac_mt76@5021497903176e83144dde2ac53d34f55e1d2647`，`mp4.3-6.12` |

固定版本只用于本次实验复现，不改变 main 分支跟随 OpenWrt 主线的策略。
插件与主题继续沿用本项目配置，feeds 并未全部固定，因此不是完整的二进制可复现构建。

## 移植内容与边界

- 内核主体来自官方 `999-wed-10-add-mt7987-hwpath-support.patch`：
  WED 3.1 识别、MT7987 寄存器布局、TX/RX 队列、RRO 3.1、DMA 初始化/复位、
  配套公共头文件接口和不使用 WO 的硬件路径。
- 保留 Linux 6.18 / OpenWrt 已有的 DMA 清理、PPE 五参数 WCID 接口、
  `flow_flush` 与空闲统计，不用旧版整文件覆盖新版驱动。
- 从官方 08 补充版本寄存器定义；09 的 RRO 初始化顺序纳入移植。
  纳入 14 的中断状态修正、20 的复位轮询时间、23 的按 `nbuf` 计算 TX BM 大小。
  13 的 WDMA 门控仅应用于 MT7987 WDMA0，避免为此改写整个 NETSYS 端口映射。
  16 只取避免重复分配 DMA 环的检查，保留主线其他设备的初始化顺序。
- `mt76/100-mt7987-wed31.patch` 为对应的最小无线侧移植，保留稳定版本的
  token 分区和现有 PPE 接口适配；不是替换为整个厂商无线分支。
- `kernel/951-mt7987-wed-buffer-errors.patch` 修复新路径继承的分配失败清理缺陷：
  RX 缓冲区初始化失败时停止启动 DMA；AMSDU 部分分配完整释放，并清空所有权指针，
  避免重复释放；RX 描述符释放后清空指针，覆盖复位后重新分配失败的清理路径。
  主机故障注入测试覆盖这些错误路径，不代表硬件 DMA 验证。
- MT7987 不使用 MT7988 WO 固件，不添加错误的 WO 固件包。
  当前 OpenWrt 的 MT7987 DTS 已有相同的 WED 节点，因此不修改分区、DTS 或网口拓扑。
- 不整体导入厂商 NETSYS/RSS/LRO、调度、调试工具和可选 PCIe IRQ 模式。
  官方 18 的可变 MSDU 页环、19 的 IRQ 模式及 21 的 TX BM 重建不在本轮移植中；
  实验需要特别验证错误恢复路径，不能因为编译通过就认为所有厂商功能已经移植。
  不承诺其他双 HIF 设备的 AMSDU 流控与厂商分支完全等价，本轮仅面向 GL-MT3600BE。
- 实验固件通过官方同款 `MODPARAMS.mt7996e:=wed_enable=1` 请求 WED。
  这与日常版不强制 WED 的策略隔离，不把 `Requested` 显示为“硬件加速已生效”。

## 构建与检查

提交到实验分支会触发独立工作流。该工作流不恢复、不保存 GitHub 编译缓存，
不发布 Release，产物及 LuCI 版本标识包含 `WED-EXPERIMENTAL`。
工作流先完成真实工具链、内核、mac80211、mt76 编译，再构建整机固件。
任一步骤失败会直接留下失败日志，不跳过补丁，不降级成普通驱动后伪装成功。

本地源码检查（需要 Python 3、Git 和指定提交的 OpenWrt 源码树）：

```sh
bash Tests/check-experimental-wed.sh
python3 Tests/check-wed-source.py --openwrt-tree /path/to/openwrt
```

源码检查会下载对应的真实 Linux / mt76 文件，先应用 OpenWrt 和原有兼容补丁，
再应用实验补丁，核对寄存器定义与关键 ABI。它不等同于真实交叉编译。

## 实机验证与回退

1. 保留当前稳定固件、配置备份和已确认可用的恢复方式；用有线管理测试路由器。
   实验固件只适用于 GL-MT3600BE，不建议直接替换唯一的生产网络设备。
2. 刷入后记录 `ubus call system board`、`uname -a`、`dmesg`。
   检查 `cat /sys/module/mt7996e/parameters/wed_enable` 与 `dmesg | grep -i wed`。
   参数为 `Y` 仅证明请求开启；必须确认驱动成功 attach 到对应 WED 设备。
3. 使用 WiFi 客户端访问 WAN 侧独立服务器产生持续 TCP/UDP 转发流量。
   路由器自身测速、同桥 LAN 内互传不能作为 WAN 路由卸载的充分证据。
   首轮暂停透明代理、VPN 和 SQM，先验证普通直连流量。
4. 对照 `nft list ruleset` 的 flowtable、conntrack 的卸载状态，
   以及 `/sys/kernel/debug/mtk_ppe*/bind` 中对应测试五元组的绑定记录。
   查看 `/sys/kernel/debug/wed*/txinfo`、`rxinfo` 的计数是否随测试流量变化。
   PPE 绑定总数不为零也不能单独证明 WiFi 测试流量被卸载。
5. 分别验证 WiFi 到 WAN、WAN 到 WiFi、双向并发、断连重连和至少数小时负载，
   观察内存、温度、驱动复位、丢包及管理页可达性。没有这些证据不能宣布修复完成。
6. 如果异常，先保存日志；通过有线连接将 `/etc/modules.d/` 中 mt7996e 条目的
   `wed_enable=1` 改为 `wed_enable=0`，重启后核对参数。最终回退应重新刷回保存的
   稳定固件，并确认未保留实验模块参数。这里不会自动降级或自动替用户刷机。

## 来源及许可

- [MediaTek 官方 WED 补丁目录](https://github.com/mediatek/mtk-openwrt-feeds/tree/cc3641f440cbb2f233b930684fa53c079a196fac/25.12/files/target/linux/mediatek/patches-6.12)
- [MediaTek 官方 softmac_mt76](https://github.com/mediatek/softmac_mt76/tree/5021497903176e83144dde2ac53d34f55e1d2647)
- [OpenWrt 本次基线](https://github.com/openwrt/openwrt/tree/5700101d7c85381889d890dc1d3d001d0b4b6446)

硬件实现归原作者所有，继续遵循各源文件的原有许可：内核为 GPL-2.0-only，
本次涉及的 mt76 源文件为 BSD-3-Clause-Clear。
该目录记录移植来源，不把 MediaTek 原始实现声明为本项目原创。
