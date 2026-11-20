"""在回放后的真实源码上核对复位顺序，不把源码检查当作实机结果。"""
from pathlib import Path
import argparse
import subprocess
import tempfile


def body(path, name):
    source = path.read_text(encoding="utf-8")
    start = source.index(name + "(")
    return source[start:source.index("\n}", start) + 2]


def ordered(source, *tokens):
    pos = 0
    for token in tokens:
        index = source.find(token, pos)
        if index < 0:
            raise AssertionError(f"恢复路径缺失或顺序错误：{token}")
        pos = index + len(token)


def check(kernel, radio):
    wed = kernel / "drivers/net/ethernet/mediatek/mtk_wed.c"
    mac = radio / "mt7996/mac.c"
    ordered(body(wed, "mtk_wed_reset_dma"), "mtk_wed_rx_reset(dev)",
            "mtk_wed_free_tx_buffer(dev)", "mtk_wed_tx_buffer_alloc(dev)", "return ret")
    ordered(body(radio / "mt7996/dma.c", "mt7996_dma_reset"), "if (force)",
            "mtk_wed_device_stop", "mt7996_tx_token_put", "mt76_queue_tx_cleanup",
            "return ret", "mt7996_dma_enable")
    ordered(body(radio / "mt7996/init.c", "mt7996_unregister_device"),
            "mt76_unregister_device", "mtk_wed_device_stop", "mt7996_wed_rro_free")
    ordered(body(mac, "mt7996_mac_full_reset"), "flow_blocked, true",
            "mt7996_wed_flow_cleanup", "mutex_lock", "return false",
            "mt7996_mac_reset_sta_iter", "flow_blocked, false")
    ordered(body(mac, "mt7996_wed_flow_cleanup"), "rtnl_lock()", "MT76_STATE_WED_RESET",
            "rcu_read_unlock()", "cleanup(netdev)", "rtnl_unlock()")
    ordered(body(radio / "mt7996/main.c", "mt7996_net_fill_forward_path"),
            "smp_load_acquire", "IEEE80211_MLD_MAX_NUM_LINKS", "mt7996_vif_link",
            "mt7996_sta_link", "connected", "DEV_PATH_MTK_WDMA")
    ordered(body(mac, "mt7996_mac_reset_work"), "mt7996_dma_reset(dev, false)",
            "goto resume_napi", "MT_MCU_INT_EVENT_DMA_INIT", "resume_napi:",
            "retrying full recovery", "queue_work", "return;", "ieee80211_wake_queues")


def exercise_cleanup(options):
    source = options.radio / "mt7996/mac.c"
    funcs = ("static bool\n" + body(source, "mt7996_wed_flow_netdev") +
             "\nstatic void\n" + body(source, "mt7996_wed_flow_cleanup"))
    fixture = Path(__file__).with_name("fixtures") / "wed-flow-cleanup.c"
    with tempfile.TemporaryDirectory() as tmp:
        script = Path(tmp) / "check.c"
        exe = Path(tmp) / "check.exe"
        script.write_text(fixture.read_text(encoding="utf-8").replace("/* FUNCTIONS */", funcs),
                          encoding="utf-8")
        args = (["/nologo", "/WX", "/utf-8", "/TC", str(script), f"/Fe:{exe}"]
                if options.msvc else ["-Wall", "-Werror", str(script), "-o", str(exe)])
        subprocess.run([options.compiler, *args], cwd=tmp, check=True, timeout=60)
        subprocess.run([str(exe)], cwd=tmp, check=True, timeout=60)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel", type=Path)
    parser.add_argument("radio", type=Path)
    parser.add_argument("--compiler", default="cc")
    parser.add_argument("--msvc", action="store_true")
    opts = parser.parse_args()
    check(opts.kernel, opts.radio)
    exercise_cleanup(opts)
    print("复位顺序、流表清理范围、锁边界及 FE 复位跳过检查通过。")
