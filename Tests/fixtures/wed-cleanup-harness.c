/* 中文：仅用于主机上的错误路径单元测试；不模拟或宣称 DMA 硬件工作正常。 */
typedef unsigned int u32;
typedef unsigned long long dma_addr_t;
#define NULL ((void *)0)
#define ENOMEM 12
#define GFP_KERNEL 0
#define GFP_DMA32 0
#define __GFP_NOWARN 0
#define __GFP_ZERO 0
#define __GFP_COMP 0
#define DMA_TO_DEVICE 0
#define MTK_WED_AMSDU_NPAGES 4
#define MTK_WED_AMSDU_BUF_SIZE 65536
#define CHECK(test) do { if (!(test)) return __LINE__; } while (0)

struct mtk_wed_amsdu { void *txd; dma_addr_t txd_phy; };
struct mtk_wed_bm_desc { u32 value; };
struct mtk_wed_hw { void *dev; struct mtk_wed_amsdu *wed_amsdu; };
struct mtk_wed_device {
    struct mtk_wed_hw *hw;
    struct { int size; struct mtk_wed_bm_desc *desc; dma_addr_t desc_phys; } rx_buf_ring;
    struct {
        int rx_nbuf, rx_npkt;
        u32 (*init_rx_buf)(struct mtk_wed_device *, int);
        void (*release_rx_buf)(struct mtk_wed_device *);
    } wlan;
};

static struct mtk_wed_amsdu storage[MTK_WED_AMSDU_NPAGES];
static struct mtk_wed_bm_desc rx_desc;
static int pages[MTK_WED_AMSDU_NPAGES], maps[MTK_WED_AMSDU_NPAGES];
static int allocated, page_calls, map_calls, error;
static int fail_metadata, fail_page, fail_map, fail_rx, rx_allocated, hwrro_calls;
static int fail_coherent, release_calls;

static int mtk_wed_is_v3_or_greater(struct mtk_wed_hw *hw) { return 1; }
static int get_order(int size) { return 4; }
static void *kcalloc(int count, unsigned long long size, int flags)
{
    if (fail_metadata) return NULL;
    if (allocated) error = 1;
    allocated = 1;
    return storage;
}
static void *devm_kcalloc(void *dev, int count, unsigned long long size, int flags)
{
    return kcalloc(count, size, flags);
}
static void kfree(void *ptr) { if (!allocated) error = 1; allocated = 0; }
static unsigned long long __get_free_pages(int flags, int order)
{
    int index = page_calls++;
    if (index == fail_page) return 0;
    pages[index] = 1;
    return index + 1;
}
static void free_pages(unsigned long ptr, int order)
{
    int index = (int)ptr - 1;
    if (index < 0 || index >= MTK_WED_AMSDU_NPAGES || !pages[index]) { error = 1; return; }
    pages[index] = 0;
}
static dma_addr_t dma_map_single(void *dev, void *ptr, int size, int direction)
{
    int index = map_calls++;
    if (index == fail_map) return 0;
    maps[index] = 1;
    return index + 1;
}
static int dma_mapping_error(void *dev, dma_addr_t address) { return !address; }
static void dma_unmap_single(void *dev, dma_addr_t address, int size, int direction)
{
    int index = (int)address - 1;
    if (index < 0 || index >= MTK_WED_AMSDU_NPAGES || !maps[index]) { error = 1; return; }
    maps[index] = 0;
}
static void *dma_alloc_coherent(void *dev, unsigned long long size, dma_addr_t *address, int flags)
{
    if (fail_coherent) return NULL;
    rx_allocated++;
    *address = 1;
    return &rx_desc;
}
static void dma_free_coherent(void *dev, unsigned long long size, void *ptr, dma_addr_t address)
{
    if (!rx_allocated) error = 1;
    rx_allocated--;
}
static u32 init_rx(struct mtk_wed_device *dev, int size) { return fail_rx ? (u32)-ENOMEM : 0; }
static int mtk_wed_hwrro_buffer_alloc(struct mtk_wed_device *dev) { hwrro_calls++; return 0; }
static void mtk_wed_hwrro_free_buffer(struct mtk_wed_device *dev) { }
static void release_rx(struct mtk_wed_device *dev) { release_calls++; }

/* WED_FUNCTIONS */

static void reset_faults(void)
{
    int i;
    allocated = page_calls = map_calls = error = 0;
    fail_metadata = fail_rx = rx_allocated = hwrro_calls = 0;
    fail_coherent = release_calls = 0;
    fail_page = fail_map = -1;
    for (i = 0; i < MTK_WED_AMSDU_NPAGES; i++) {
        pages[i] = maps[i] = 0;
        storage[i].txd = NULL;
        storage[i].txd_phy = 0;
    }
}

static int check_amsdu_failures(void)
{
    int scenario, i;
    for (scenario = 0; scenario < 5; scenario++) {
        struct mtk_wed_hw hw = {0};
        struct mtk_wed_device dev = {0};
        dev.hw = &hw;
        reset_faults();
        if (scenario == 0) fail_metadata = 1;
        if (scenario == 1) fail_page = 0;
        if (scenario == 2) fail_page = 2;
        if (scenario == 3) fail_map = 0;
        if (scenario == 4) fail_map = 2;
        CHECK(mtk_wed_amsdu_buffer_alloc(&dev) == -ENOMEM);
        mtk_wed_amsdu_free_buffer(&dev);
        CHECK(!hw.wed_amsdu && !allocated && !error);
        for (i = 0; i < MTK_WED_AMSDU_NPAGES; i++) CHECK(!pages[i] && !maps[i]);
    }
    return 0;
}

static int check_repeated_free(void)
{
    struct mtk_wed_hw hw = {0};
    struct mtk_wed_device dev = {0};
    int i;
    dev.hw = &hw;
    reset_faults();
    CHECK(mtk_wed_amsdu_buffer_alloc(&dev) == 0);
    mtk_wed_amsdu_free_buffer(&dev);
    mtk_wed_amsdu_free_buffer(&dev);
    CHECK(!hw.wed_amsdu && !allocated && !error);
    for (i = 0; i < MTK_WED_AMSDU_NPAGES; i++) CHECK(!pages[i] && !maps[i]);
    fail_metadata = 1;
    CHECK(mtk_wed_amsdu_buffer_alloc(&dev) == -ENOMEM);
    mtk_wed_amsdu_free_buffer(&dev);
    CHECK(!error);
    return 0;
}

static int check_rx_failure(void)
{
    struct mtk_wed_hw hw = {0};
    struct mtk_wed_device dev = {0};
    dev.hw = &hw;
    dev.wlan.rx_nbuf = dev.wlan.rx_npkt = 1;
    dev.wlan.init_rx_buf = init_rx;
    reset_faults();
    fail_rx = 1;
    CHECK(mtk_wed_rx_buffer_alloc(&dev) == -ENOMEM);
    CHECK(!dev.rx_buf_ring.desc && !rx_allocated && !hwrro_calls && !error);
    fail_rx = 0;
    CHECK(mtk_wed_rx_buffer_alloc(&dev) == 0);
    CHECK(dev.rx_buf_ring.desc && rx_allocated == 1 && hwrro_calls == 1);
    return 0;
}

static int check_rx_reset_failure(void)
{
    struct mtk_wed_hw hw = {0};
    struct mtk_wed_device dev = {0};
    dev.hw = &hw;
    dev.wlan.rx_nbuf = dev.wlan.rx_npkt = 1;
    dev.wlan.init_rx_buf = init_rx;
    dev.wlan.release_rx_buf = release_rx;
    reset_faults();
    CHECK(mtk_wed_rx_buffer_alloc(&dev) == 0);
    mtk_wed_free_rx_buffer(&dev);
    fail_coherent = 1;
    CHECK(mtk_wed_rx_buffer_alloc(&dev) == -ENOMEM);
    mtk_wed_free_rx_buffer(&dev);
    CHECK(!dev.rx_buf_ring.desc && !rx_allocated && !error);
    CHECK(release_calls == 1);
    return 0;
}

int main(void)
{
    int result = check_amsdu_failures();
    if (!result) result = check_repeated_free();
    if (!result) result = check_rx_failure();
    if (!result) result = check_rx_reset_failure();
    return result;
}
