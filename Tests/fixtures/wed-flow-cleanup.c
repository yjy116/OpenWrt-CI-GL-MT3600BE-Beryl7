/* 中文：在主机执行真实筛选与清理函数，检查设备范围与同步顺序，不模拟硬件。 */
#include <stdbool.h>
#define IS_ENABLED(x) 1
struct wiphy { int id; };
struct wireless_dev { struct wiphy *wiphy; };
struct net_device {
	struct wireless_dev *ieee80211_ptr;
	struct net_device *next, *upper;
	int calls;
};
struct net { struct net_device *first; };
struct mt7996_dev { struct { unsigned long state; } mphy; };
static struct wiphy phy, other;
static struct { struct wiphy *wiphy; } hw = { &phy };
static struct net ns;
static int held, reading, symbols, broken, loaded = 1, fe_race;
static struct mt7996_dev dev;
#define mt76_hw(d) (&hw)
#define wiphy_net(w) (&ns)
#define for_each_netdev(n, d) for ((d)=(n)->first; (d); (d)=(d)->next)
#define MT76_STATE_WED_RESET 1
#define test_bit(bit, addr) (*(addr) != 0)
#define symbol_get(sym) (loaded ? (++symbols, sym) : 0)
#define symbol_put(sym) (--symbols)
static void rtnl_lock(void) { held++; if (fe_race) dev.mphy.state = 1; }
static void rtnl_unlock(void) { held--; }
static void rcu_read_lock(void) { reading++; }
static void rcu_read_unlock(void) { reading--; }
static bool netdev_has_upper_dev_all_rcu(struct net_device *d, struct net_device *up)
{
	if (held != 1 || reading != 1) broken = 1;
	while ((d = d->upper)) if (d == up) return true;
	return false;
}
static void nf_flow_table_cleanup(struct net_device *d)
{
	if (held != 1 || reading || symbols != 1) broken = 1;
	d->calls++;
}
/* FUNCTIONS */
int main(void)
{
	struct wireless_dev local = { &phy }, foreign = { &other };
	struct net_device wan = {0}, other_ap = { &foreign, &wan, 0, 0 };
	struct net_device vlan = {0, &other_ap, 0, 0}, br = {0, &vlan, &vlan, 0};
	struct net_device ap = { &local, &br, &br, 0 };
	ns.first = &ap;
	loaded = 0;
	mt7996_wed_flow_cleanup(&dev);
	if (symbols || ap.calls || held) return 1;
	loaded = 1;
	fe_race = 1;
	mt7996_wed_flow_cleanup(&dev);
	if (symbols || ap.calls || held) return 2;
	fe_race = 0;
	dev.mphy.state = 0;
	mt7996_wed_flow_cleanup(&dev);
	if (ap.calls != 2 || br.calls != 2 || vlan.calls != 2) return 3;
	return broken || wan.calls || other_ap.calls || reading || held || symbols;
}
