# DPDK — Deep Dive Q&A

Data Plane Development Kit (DPDK) is a set of libraries and drivers for fast packet processing in userspace, bypassing the Linux kernel network stack.

---

## Q: How does DPDK achieve high throughput?

DPDK combines five techniques — removing any one drops throughput significantly.

### 1. Kernel Bypass (Direct Hardware Access)

Standard Linux path:
```
NIC → kernel driver → kernel socket buffer → system call → userspace app
```

DPDK path:
```
NIC → DPDK PMD (userspace driver) → userspace app
```

**PMD (Poll Mode Driver)** runs entirely in userspace and talks directly to the NIC's registers via memory-mapped I/O. No context switches, no kernel interrupt handling.

### 2. Zero-Copy

Standard kernel path copies a packet multiple times:
```
NIC DMA → kernel sk_buff → socket recv buffer → memcpy → user buffer
```

DPDK eliminates this — the NIC DMAs directly into a **pre-allocated userspace memory buffer** (`rte_mbuf`). The application reads the packet in-place. **0 copies.**

### 3. Poll Mode Instead of Interrupts

| Interrupt Mode (kernel) | Poll Mode (DPDK) |
|---|---|
| NIC fires interrupt → CPU stops → handles it | CPU spins in a tight loop checking the NIC ring |
| Low latency at low traffic | No interrupt overhead |
| Overhead per packet: ~microseconds | Overhead per packet: ~nanoseconds |

At 10–100 Gbps, packets arrive every ~10ns. Interrupt overhead would dominate. Polling wins decisively.

```c
// DPDK main loop — tight poll
while (running) {
    nb_rx = rte_eth_rx_burst(port, queue, mbufs, BURST_SIZE);
    process_packets(mbufs, nb_rx);
}
```

### 4. Huge Pages (TLB Optimization)

Normal pages are 4 KB. DPDK uses **2 MB or 1 GB huge pages**.

With 4 KB pages, a large packet buffer causes frequent **TLB misses** (expensive page table walks). With 2 MB huge pages, the same buffer fits in far fewer TLB entries → near-zero TLB misses.

### 5. CPU Pinning (No Scheduler Jitter)

DPDK dedicates **entire CPU cores** to packet processing — the OS scheduler never preempts them:

```bash
# Pin DPDK to cores 2,3 — OS never touches these cores
dpdk-app -l 2,3 --proc-type primary
```

Combined with **NUMA awareness** (buffers on same NUMA node as NIC), memory latency is minimized.

### Summary Table

| Technique | What It Eliminates |
|---|---|
| Kernel bypass | System calls, context switches |
| Zero-copy | `memcpy` between kernel/userspace |
| Poll mode | Interrupt overhead, IRQ latency |
| Huge pages | TLB misses |
| CPU pinning | Scheduler jitter, cache thrashing |

Result: DPDK achieves ~**80 million small packets/second per core** vs ~1–2 million for the standard Linux stack.

---

## Q: Does DPDK need any kernel component?

Yes — a thin kernel shim is needed for privileged setup operations. DPDK uses one of two kernel modules:

| Driver | Description |
|---|---|
| `uio_pci_generic` / `igb_uio` | Older. Exposes NIC registers via `/dev/uioX` |
| `vfio-pci` | Modern, preferred. Uses IOMMU for safe DMA isolation |

```bash
# Bind NIC to DPDK's vfio-pci (away from kernel driver)
modprobe vfio-pci
dpdk-devbind.py --bind=vfio-pci 0000:01:00.0
```

The kernel shim does three privileged jobs:

| Job | Details |
|---|---|
| **CPU configuration** | Isolates cores (`isolcpus`), sets affinity, disables C-states |
| **MMIO mapping** | `mmap()` exposes NIC BAR registers to userspace |
| **IOMMU programming** | Maps userspace physical pages → IOVA for NIC DMA |

Once setup is complete, the kernel is completely out of the hot path. Every packet is handled in userspace with no syscalls.

---

## Q: Do virtual addresses need to be contiguous?

The answer differs by address type:

| Address Type | Must Be Contiguous? | Why |
|---|---|---|
| **Virtual** (CPU view) | ✅ Yes | MMU guarantees flat virtual space; your code needs it |
| **Physical** (RAM) | ⚠️ Preferred | Required for DMA without IOMMU |
| **IOVA** (NIC/DMA view) | ✅ Yes | NIC sees it as flat |
| **Physical with IOMMU** | ❌ No | IOMMU handles scatter-gather for the NIC |

**Why huge pages matter for DMA:**

| Page Size | 2 MB buffer needs | Physical contiguity |
|---|---|---|
| 4 KB pages | 512 pages, likely scattered | ❌ Probably non-contiguous |
| 2 MB huge page | **1 page** | ✅ Guaranteed physically contiguous |

The **IOMMU** adds address translation for the NIC (like the MMU does for the CPU). With IOMMU, DPDK can map scattered physical pages into one flat IOVA range — the NIC sees a contiguous buffer.

---

## Q: Show DPDK IOMMU scatter-gather in C

### Part 1: Allocate Non-Contiguous Physical Pages

```c
#include <stdio.h>
#include <stdint.h>
#include <sys/mman.h>
#include <linux/vfio.h>
#include <sys/ioctl.h>

#define PAGE_SIZE  4096
#define NUM_PAGES  4

void *pages[NUM_PAGES];

void alloc_scattered_pages(void) {
    for (int i = 0; i < NUM_PAGES; i++) {
        pages[i] = mmap(NULL, PAGE_SIZE,
                        PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE,
                        -1, 0);
        // MAP_POPULATE faults the page in immediately so the kernel
        // assigns a real physical frame now (may be non-contiguous).
        printf("Page %d: virt=%p\n", i, pages[i]);
    }
}
```

### Part 2: Map Pages to Contiguous IOVA via VFIO

```c
/*
 * We want the NIC to see:
 *   IOVA 0x0000 → physical frame of pages[0]
 *   IOVA 0x1000 → physical frame of pages[1]  (scattered in RAM)
 *   IOVA 0x2000 → physical frame of pages[2]
 *   IOVA 0x3000 → physical frame of pages[3]
 *
 * From the NIC: one flat 16KB buffer at IOVA 0x0000.
 */
void map_pages_to_iova(int container_fd) {
    uint64_t iova_base = 0x00000000;

    for (int i = 0; i < NUM_PAGES; i++) {
        struct vfio_iommu_type1_dma_map dma_map = {
            .argsz = sizeof(dma_map),
            .flags = VFIO_DMA_MAP_FLAG_READ | VFIO_DMA_MAP_FLAG_WRITE,
            .vaddr = (uint64_t)pages[i],           // CPU virtual address
            .iova  = iova_base + (i * PAGE_SIZE),  // NIC's view (contiguous)
            .size  = PAGE_SIZE,
        };

        ioctl(container_fd, VFIO_IOMMU_MAP_DMA, &dma_map);
        printf("Mapped page %d: virt=%p → IOVA=0x%lx\n",
               i, pages[i], dma_map.iova);
    }
    /*
     * IOMMU table:
     *   IOVA 0x0000 → phys 0x2a000000  (pages[0])
     *   IOVA 0x1000 → phys 0x8f100000  (pages[1], scattered)
     *   IOVA 0x2000 → phys 0x1c300000  (pages[2], scattered)
     *   IOVA 0x3000 → phys 0xff200000  (pages[3], scattered)
     */
}
```

### Part 3: Program the NIC Using the Flat IOVA

```c
struct rx_descriptor {
    uint64_t iova_addr;
    uint16_t length;
    uint16_t status;
};

void setup_rx_ring(volatile struct rx_descriptor *ring) {
    // NIC sees one flat 16KB buffer, IOMMU handles page crossings
    ring[0].iova_addr = 0x00000000;
    ring[0].length    = NUM_PAGES * PAGE_SIZE;
    ring[0].status    = 0;
}
```

### Translation Chain

```
CPU reads packet:
  pages[1] virtual addr  →  MMU   →  phys 0x8f100000  →  RAM

NIC writes packet:
  IOVA 0x1000            →  IOMMU →  phys 0x8f100000  →  RAM (same cell!)
```

### In Real DPDK (Abstracted)

```c
// DPDK hides all VFIO calls behind:
const struct rte_memzone *mz = rte_memzone_reserve(
    "my_buf", NUM_PAGES * PAGE_SIZE,
    rte_socket_id(), RTE_MEMZONE_IOVA_CONTIG
);
//                           ↑ ensures flat IOVA even if phys pages scattered

uint64_t iova = mz->iova;  // hand to NIC descriptor
void    *virt = mz->addr;  // hand to your CPU code
```

---

## Q: Does scatter-gather also need NIC hardware support?

There are **two independent** scatter-gather mechanisms:

### Layer 1: IOMMU Scatter-Gather (Transparent)

IOMMU maps non-contiguous physical pages into a flat IOVA for the NIC. The NIC and driver see a contiguous buffer — no special NIC support required.

```
Driver says:  "DMA to IOVA 0x0000, size 16KB"
IOMMU does:   page 0→physA, page 1→physB, page 2→physC  (scattered)
NIC sees:     one flat 16KB buffer
```

### Layer 2: Driver-Level Scatter-Gather (Explicit SGL)

The driver hands the NIC a **list of (address, length) pairs**. The NIC's DMA engine chains them itself, treating multiple segments as one logical packet.

```c
// Linux kernel DMA scatter-gather API
struct scatterlist sg[3];
sg_set_page(&sg[0], page0, PAGE_SIZE, 0);
sg_set_page(&sg[1], page1, PAGE_SIZE, 0);
sg_set_page(&sg[2], page2, PAGE_SIZE, 0);

dma_map_sg(dev, sg, 3, DMA_FROM_DEVICE);

for (int i = 0; i < 3; i++) {
    ring[i].dma_addr = sg_dma_address(&sg[i]);
    ring[i].length   = sg_dma_len(&sg[i]);
}
// NIC chains these 3 descriptors as one logical packet
```

**NIC descriptor format with SGL support:**
```
Chained descriptor:
┌──────────────┬────────┬─────────┬───────────────┐
│  dma_addr    │  len   │  flags  │ next_desc_ptr │  ← EOP bit marks last
└──────────────┴────────┴─────────┴───────────────┘
```

### Comparison

| | IOMMU S-G | Driver/NIC S-G |
|---|---|---|
| Who does the work | IOMMU hardware | NIC DMA engine |
| Driver awareness | None — transparent | Must build SGL explicitly |
| NIC requirement | None | NIC must support SGL descriptors |
| IOMMU required | Yes | No |

### Real-World NIC SGL Support

| NIC | SGL Support | Max Segments |
|---|---|---|
| Intel i40e (server) | ✅ Yes | 8 segments |
| Mellanox ConnectX-5 | ✅ Yes | 30 segments |
| Virtio-net (VM) | ✅ Yes | Configurable |
| Old/embedded NICs | ❌ No | 1 (must be contiguous) |

### What Happens Without SGL or IOMMU

```
Old NIC + no IOMMU:
  Jumbo frame (9KB) → driver must find one 9KB physically contiguous region
  → Very hard under memory pressure → allocation failure → dropped packet
```

---

## Q: What is SR-IOV in PCIe?

**SR-IOV (Single Root I/O Virtualization)** — a PCIe standard that lets one physical NIC appear as multiple independent virtual devices to VMs or containers, with near-zero hypervisor overhead.

### The Problem

Without SR-IOV, every VM's traffic goes through the hypervisor:
```
VM1 ──┐
VM2 ──┼──► Hypervisor (software bridge) ──► Physical NIC ──► Network
VM3 ──┘     ↑ bottleneck: CPU cycles per packet
```

With SR-IOV, VMs talk to the NIC **directly**:
```
VM1 ──► VF0 ──┐
VM2 ──► VF1 ──┼──► Physical NIC ──► Network
VM3 ──► VF2 ──┘
        ↑ hypervisor bypassed in the data path
```

### PF vs. VF

| | PF (Physical Function) | VF (Virtual Function) |
|---|---|---|
| What it is | The real NIC | Lightweight virtual slice |
| Who uses it | Host / hypervisor | VM or container |
| Capabilities | Full config, create/destroy VFs | Data TX/RX only |
| Count | 1 per NIC | Up to 256 per PF |

### Dedicated Hardware Queues per VF

```
Physical NIC Hardware
┌──────────────────────────────────────────────────┐
│  PF:  TX queue 0,  RX queue 0  (host)            │
│  VF0: TX queue 1,  RX queue 1  ──► VM1           │
│  VF1: TX queue 2,  RX queue 2  ──► VM2           │
│  VF2: TX queue 3,  RX queue 3  ──► VM3           │
└──────────────────────────────────────────────────┘
```

### Setup

```bash
# Create 4 VFs on eth0
echo 4 > /sys/class/net/eth0/device/sriov_numvfs

# Assign VF0 directly to a VM
qemu-system-x86_64 -device vfio-pci,host=01:00.1 ...

# Per-VF bandwidth limits (NIC enforces in hardware)
ip link set eth0 vf 1 max_tx_rate 10000   # 10 Gbps cap
ip link set eth0 vf 1 min_tx_rate 1000    # 1 Gbps guaranteed
```

### Performance Comparison

| Approach | Latency | Throughput | Isolation |
|---|---|---|---|
| Software bridge (virtio) | High | Medium | Good |
| OVS-DPDK | Medium | High | Good |
| **SR-IOV** | ~Bare metal | Wire speed | HW-enforced |
| Bare metal | Lowest | Wire speed | None |

**Tradeoff:** Live VM migration is harder because NIC state is in hardware, not software.

---

## Q: Multiple VFs share one physical link — is that a bottleneck?

**Yes.** SR-IOV eliminates the CPU/software bottleneck, not the bandwidth bottleneck.

```
VM1 (VF0) ──┐
VM2 (VF1) ──┤──► NIC ──► [single 25GbE cable] ──► Switch
VM3 (VF2) ──┘
             ↑                    ↑
    SR-IOV eliminates        Fixed. All VMs share it.
    this bottleneck
```

| Bottleneck | SR-IOV fixes it? |
|---|---|
| Hypervisor CPU cycles per packet | ✅ Yes |
| Context switches | ✅ Yes |
| HW queue contention | ✅ Yes — each VF has dedicated queues |
| **Physical link bandwidth** | ❌ No |
| **Switch port capacity** | ❌ No |

### Mitigation Strategies

**1. Faster links**

| Speed | Use Case |
|---|---|
| 10 GbE | Older servers |
| 25 GbE | Current standard |
| 100 GbE | High-density hypervisors |
| 400 GbE | AI clusters, spine switches |

**2. Dual-port bonding**
```bash
ip link add bond0 type bond mode 802.3ad
ip link set eth0 master bond0
ip link set eth1 master bond0
# 2 × 25GbE = 50GbE effective; VFs created on bond0
```

**3. Per-VF hardware rate limiting**
```bash
ip link set eth0 vf 1 max_tx_rate 10000   # Mbps
ip link set eth0 vf 1 min_tx_rate 1000
```

**4. DPDK + SR-IOV + IOMMU (gold standard)**
```
VM gets VF (SR-IOV)
  └── DPDK inside VM with VFIO driver
        └── IOMMU maps VM memory → DMA-safe IOVA
              └── VF DMAs packets directly into DPDK buffers
                    └── Zero copies, zero hypervisor, wire speed
```
