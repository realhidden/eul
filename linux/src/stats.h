//
//  stats.h
//  eul (linux)
//
//  Hardware sampling from /proc, /sys, statvfs and getifaddrs — syscalls
//  and file reads, no shelled-out tools. Mirrors what the Mac app shows:
//  CPU (total + per core + load + temp + freq), memory + swap, mounted
//  disks, network rates and addresses, top processes, battery.
//
//  Deltas (CPU ticks, network counters, process ticks) live in a
//  stats_ctx owned by the caller, so the dashboard and the peer sharer
//  can sample at their own cadences without stepping on each other.
//

#ifndef EUL_STATS_H
#define EUL_STATS_H

#include <stddef.h>
#include <stdint.h>

#define EUL_MAX_CORES 128
#define EUL_MAX_DISKS 16
#define EUL_MAX_IFACES 64 // docker hosts carry a veth per container
#define EUL_MAX_ADDRS 8
#define EUL_TOP_PROCS 5

typedef struct {
    double total_b, free_b; // free = available to non-root, like df
    double used_b;          // blocks in use, like df (root reserve excluded)
    unsigned long long dev; // st_dev, to fold bind mounts together
    double used_pct;
    char mount[160];
    char fs[24];
} eul_disk;

typedef struct {
    char name[32];
    double rx_bps, tx_bps;
    char ipv4[64];
    char ipv6[EUL_MAX_ADDRS][64];
    int ipv6_count;
    int up;
} eul_iface;

typedef struct {
    int pid;
    char name[64];
    double cpu_pct; // can exceed 100 on multi-core
    double rss_b;
} eul_proc;

typedef struct {
    char hostname[128];
    char distro[128];
    char kernel[64];
    double uptime_s;

    int cpu_count;
    double cpu_usage_pct;
    double cpu_core[EUL_MAX_CORES];
    double load[3];
    int has_temp;
    double temp_c;
    int has_freq;
    double freq_ghz;

    // GPU busy %: AMD from sysfs, NVIDIA via NVML when the driver is
    // installed; nothing for Intel iGPUs and the Raspberry Pi
    int has_gpu;
    double gpu_pct;
    char gpu_source[16]; // "amdgpu" / "nvidia"

    double mem_total_b, mem_used_b, mem_avail_b, mem_used_pct;
    double swap_total_b, swap_used_b;

    eul_disk disks[EUL_MAX_DISKS];
    int disk_count;

    double net_rx_bps, net_tx_bps;
    eul_iface ifaces[EUL_MAX_IFACES];
    int iface_count;

    eul_proc top_cpu[EUL_TOP_PROCS];
    int top_cpu_count;
    eul_proc top_mem[EUL_TOP_PROCS];
    int top_mem_count;
    int proc_count;

    int has_battery;
    int battery_pct;
    int battery_charging;
} system_stats;

typedef struct {
    int initialized;
    long long cpu_ticks[EUL_MAX_CORES + 1][4]; // user, nice, system, idle(+) rest
    long long net_rx[EUL_MAX_IFACES], net_tx[EUL_MAX_IFACES];
    char net_name[EUL_MAX_IFACES][16];
    int net_count;
    double mono_time;
    struct { // previous process CPU ticks, keyed by pid
        int pid;
        long long ticks;
    } procs[1024];
    int proc_epoch;
} stats_ctx;

void stats_init(stats_ctx *ctx);
void stats_sample(stats_ctx *ctx, system_stats *out);

/// human sizes, eul style: binary KB/MB/GB, one decimal under 100
void format_bytes(double bytes, char *out, size_t cap);
void format_rate(double bytes_per_sec, char *out, size_t cap);

#endif
