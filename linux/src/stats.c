//
//  stats.c
//  eul (linux)
//

#include "stats.h"

#include <ctype.h>
#include <dirent.h>
#include <dlfcn.h>
#include <pthread.h>
#include <ifaddrs.h>
#include <math.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

// IFF_UP is a BSD/glibc extension hidden on macOS under strict POSIX;
// it is bit 0 on every implementation
#define EUL_IFF_UP 0x1

void stats_init(stats_ctx *ctx) {
    memset(ctx, 0, sizeof *ctx);
}

static double mono_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void read_hostname(char *out, size_t cap) {
    if (gethostname(out, cap - 1) != 0) {
        snprintf(out, cap, "localhost");
    }
    out[cap - 1] = '\0';
    if (!out[0]) {
        snprintf(out, cap, "localhost");
    }
    char *dot = strstr(out, ".local");
    if (dot) {
        *dot = '\0';
    }
}

static void read_distro(char *out, size_t cap) {
    snprintf(out, cap, "Linux");
    FILE *f = fopen("/etc/os-release", "r");
    if (!f) {
        return;
    }
    char line[256];
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, "PRETTY_NAME=", 12) == 0) {
            char *start = line + 12;
            size_t n = strlen(start);
            if (n > 0 && start[n - 1] == '\n') {
                start[--n] = '\0';
            }
            if (n >= 2 && start[0] == '"' && start[n - 1] == '"') {
                start++;
                n -= 2;
            }
            snprintf(out, cap, "%.*s", (int)n, start);
            break;
        }
    }
    fclose(f);
}

static void read_kernel(char *out, size_t cap) {
    struct utsname uts;
    if (uname(&uts) == 0) {
        snprintf(out, cap, "%.20s %.38s", uts.sysname, uts.release);
    } else {
        snprintf(out, cap, "Linux");
    }
}

static double read_uptime(void) {
    FILE *f = fopen("/proc/uptime", "r");
    if (!f) {
        return 0;
    }
    double up = 0;
    if (fscanf(f, "%lf", &up) != 1) {
        up = 0;
    }
    fclose(f);
    return up;
}

// --- CPU --------------------------------------------------------------------

/// reads /proc/stat's "cpu" (row 0) and "cpuN" (rows 1+) tick lines into
/// [0]=user+nice, [1]=unused, [2]=system+irq+softirq+steal, [3]=idle+iowait
static int read_cpu_ticks(long long ticks[EUL_MAX_CORES + 1][4], int *core_count) {
    FILE *f = fopen("/proc/stat", "r");
    if (!f) {
        return 0;
    }
    char line[512];
    *core_count = 0;
    int have_total = 0;
    while (fgets(line, sizeof line, f)) {
        long long v[8] = { 0 };
        if (strncmp(line, "cpu ", 4) == 0) {
            if (sscanf(line, "cpu %lld %lld %lld %lld %lld %lld %lld %lld",
                       &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]) < 4) {
                continue;
            }
            ticks[0][0] = v[0] + v[1]; // user + nice
            ticks[0][1] = 0;
            ticks[0][2] = v[2] + v[5] + v[6] + v[7]; // system + irq + softirq + steal
            ticks[0][3] = v[3] + v[4]; // idle + iowait
            have_total = 1;
            continue;
        }
        if (strncmp(line, "cpu", 3) == 0 && isdigit(line[3])) {
            int core = 0;
            if (sscanf(line + 3, "%d", &core) != 1 || core < 0 || core >= EUL_MAX_CORES) {
                continue;
            }
            if (sscanf(line + 3, "%*d %lld %lld %lld %lld %lld %lld %lld %lld",
                       &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]) < 4) {
                continue;
            }
            core++;
            ticks[core][0] = v[0] + v[1];
            ticks[core][1] = 0;
            ticks[core][2] = v[2] + v[5] + v[6] + v[7];
            ticks[core][3] = v[3] + v[4];
            if (core > *core_count) {
                *core_count = core;
            }
        }
    }
    fclose(f);
    return have_total;
}

static double usage_from_ticks(const long long now[4], const long long prev[4]) {
    long long busy = (now[0] - prev[0]) + (now[2] - prev[2]);
    long long idle = now[3] - prev[3];
    long long total = busy + idle;
    if (total <= 0) {
        return -1;
    }
    double pct = (double)busy / (double)total * 100.0;
    if (pct < 0) {
        pct = 0;
    }
    if (pct > 100) {
        pct = 100;
    }
    return pct;
}

static double read_milli_celsius(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) {
        return -1000;
    }
    long milli = 0;
    double c = -1000;
    if (fscanf(f, "%ld", &milli) == 1 && milli / 1000.0 > -50 && milli / 1000.0 < 200) {
        c = milli / 1000.0;
    }
    fclose(f);
    return c;
}

static void read_line(const char *path, char *out, size_t cap) {
    out[0] = '\0';
    FILE *f = fopen(path, "r");
    if (!f) {
        return;
    }
    if (fgets(out, (int)cap, f)) {
        out[strcspn(out, "\n")] = '\0';
    }
    fclose(f);
}

/// first reading of the hwmon driver `name`; with name NULL and `any` set,
/// of any driver that is not a disk, radio or battery sensor
static double hwmon_temp(const char *name, int any) {
    static const char *const not_cpu[] = { "nvme", "drivetemp", "iwlwifi", "ath", "mt7", "BAT", "acpitz" };
    for (int i = 0; i < 32; i++) {
        char path[192], driver[64];
        snprintf(path, sizeof path, "/sys/class/hwmon/hwmon%d/name", i);
        read_line(path, driver, sizeof driver);
        if (!driver[0]) {
            continue;
        }
        if (name && strcmp(driver, name) != 0) {
            continue;
        }
        if (!name && any) {
            int skip = 0;
            for (size_t k = 0; k < sizeof not_cpu / sizeof not_cpu[0]; k++) {
                skip |= strncmp(driver, not_cpu[k], strlen(not_cpu[k])) == 0;
            }
            if (skip) {
                continue;
            }
        }
        for (int t = 1; t <= 16; t++) {
            snprintf(path, sizeof path, "/sys/class/hwmon/hwmon%d/temp%d_input", i, t);
            double c = read_milli_celsius(path);
            if (c > -500) {
                return c;
            }
        }
    }
    return -1000;
}

/// a thermal zone reading: CPU/SoC zones, or with `acpi` set the acpitz one
static double zone_temp(int acpi) {
    for (int z = 0; z < 16; z++) {
        char path[160], type[64];
        snprintf(path, sizeof path, "/sys/class/thermal/thermal_zone%d/type", z);
        read_line(path, type, sizeof type);
        int match = acpi ? strncmp(type, "acpitz", 6) == 0
                         : strncmp(type, "x86_pkg_temp", 12) == 0 || strncmp(type, "cpu", 3) == 0
                               || strncmp(type, "soc", 3) == 0;
        if (!match) {
            continue;
        }
        snprintf(path, sizeof path, "/sys/class/thermal/thermal_zone%d/temp", z);
        double c = read_milli_celsius(path);
        if (c > -500) {
            return c;
        }
    }
    return -1000;
}

static void sample_cpu(stats_ctx *ctx, system_stats *out, double elapsed) {
    // offline/hotplugged cores leave holes below core_count — zero, not garbage
    long long ticks[EUL_MAX_CORES + 1][4] = { { 0 } };
    int core_count = 0;
    if (!read_cpu_ticks(ticks, &core_count)) {
        return;
    }
    out->cpu_count = core_count;
    if (ctx->initialized) {
        double total = usage_from_ticks(ticks[0], ctx->cpu_ticks[0]);
        if (total >= 0) {
            out->cpu_usage_pct = total;
        }
        for (int c = 1; c <= core_count && c <= EUL_MAX_CORES; c++) {
            double pct = usage_from_ticks(ticks[c], ctx->cpu_ticks[c]);
            out->cpu_core[c - 1] = pct >= 0 ? pct : 0;
        }
        (void)elapsed;
    }
    memcpy(ctx->cpu_ticks, ticks, sizeof ticks);

    FILE *f = fopen("/proc/loadavg", "r");
    if (f) {
        if (fscanf(f, "%lf %lf %lf", &out->load[0], &out->load[1], &out->load[2]) != 3) {
            out->load[0] = out->load[1] = out->load[2] = 0;
        }
        fclose(f);
    }

    // temperature, most specific source first: the CPU/SoC hwmon drivers in
    // preference order, then CPU/SoC thermal zones, then acpitz (often a
    // fixed board value), then any other hwmon that is not a disk/radio/battery
    static const char *const preferred[] = {
        "coretemp", "k10temp", "zenpower", "cpu_thermal", "soc_thermal",
    };
    double temp = -1000;
    for (size_t k = 0; k < sizeof preferred / sizeof preferred[0] && temp < -500; k++) {
        temp = hwmon_temp(preferred[k], 0);
    }
    if (temp < -500) {
        temp = zone_temp(0);
    }
    if (temp < -500) {
        temp = hwmon_temp("acpitz", 0);
    }
    if (temp < -500) {
        temp = zone_temp(1);
    }
    if (temp < -500) {
        temp = hwmon_temp(NULL, 1);
    }
    if (temp > -500) {
        out->has_temp = 1;
        out->temp_c = temp;
    }

    // frequency: mean scaling_cur_freq, else cpuinfo's cpu MHz (x86)
    double freq_sum = 0;
    int freq_count = 0;
    for (int c = 0; c < core_count && c < EUL_MAX_CORES; c++) {
        char path[128];
        snprintf(path, sizeof path, "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq", c);
        FILE *ff = fopen(path, "r");
        if (!ff) {
            continue;
        }
        long khz = 0;
        if (fscanf(ff, "%ld", &khz) == 1 && khz > 0) {
            freq_sum += (double)khz;
            freq_count++;
        }
        fclose(ff);
    }
    if (freq_count > 0) {
        out->has_freq = 1;
        out->freq_ghz = freq_sum / freq_count / 1e6;
    } else {
        FILE *cf = fopen("/proc/cpuinfo", "r");
        if (cf) {
            char line[512];
            double mhz_sum = 0;
            int mhz_count = 0;
            while (fgets(line, sizeof line, cf)) {
                char *colon = strchr(line, ':');
                if (colon && strncmp(line, "cpu MHz", 7) == 0) {
                    double mhz = 0;
                    if (sscanf(colon + 1, "%lf", &mhz) == 1 && mhz > 0) {
                        mhz_sum += mhz;
                        mhz_count++;
                    }
                }
            }
            fclose(cf);
            if (mhz_count > 0) {
                out->has_freq = 1;
                out->freq_ghz = mhz_sum / mhz_count / 1000;
            }
        }
    }
}

// --- GPU ----------------------------------------------------------------------

/// amdgpu publishes a plain busy percentage per card
static int amd_gpu_busy(double *pct) {
    double sum = 0;
    int count = 0;
    for (int card = 0; card < 8; card++) {
        char path[96];
        snprintf(path, sizeof path, "/sys/class/drm/card%d/device/gpu_busy_percent", card);
        FILE *f = fopen(path, "r");
        if (!f) {
            continue;
        }
        int value = 0;
        if (fscanf(f, "%d", &value) == 1 && value >= 0 && value <= 100) {
            sum += value;
            count++;
        }
        fclose(f);
    }
    if (count == 0) {
        return 0;
    }
    *pct = sum / count;
    return 1;
}

// NVML, loaded at runtime from the NVIDIA driver: no build dependency, and
// machines without the driver simply have no GPU row
typedef struct {
    unsigned int gpu, memory;
} eul_nvml_utilization;
static struct {
    int ready;
    unsigned int count;
    int (*get_handle)(unsigned int, void **);
    int (*get_utilization)(void *, eul_nvml_utilization *);
} nvml;
static pthread_once_t nvml_once = PTHREAD_ONCE_INIT;

static void nvml_load(void) {
    void *lib = dlopen("libnvidia-ml.so.1", RTLD_LAZY | RTLD_LOCAL);
    if (!lib) {
        return;
    }
    // POSIX's sanctioned way to turn dlsym's void * into a function pointer
    int (*init)(void);
    int (*get_count)(unsigned int *);
    *(void **)&init = dlsym(lib, "nvmlInit_v2");
    *(void **)&get_count = dlsym(lib, "nvmlDeviceGetCount_v2");
    *(void **)&nvml.get_handle = dlsym(lib, "nvmlDeviceGetHandleByIndex_v2");
    *(void **)&nvml.get_utilization = dlsym(lib, "nvmlDeviceGetUtilizationRates");
    if (!init || !get_count || !nvml.get_handle || !nvml.get_utilization || init() != 0
        || get_count(&nvml.count) != 0 || nvml.count == 0) {
        return; // keep the library loaded: an initialised NVML must stay mapped
    }
    nvml.ready = 1;
}

static int nvidia_gpu_busy(double *pct) {
    pthread_once(&nvml_once, nvml_load);
    if (!nvml.ready) {
        return 0;
    }
    double sum = 0;
    int count = 0;
    for (unsigned int i = 0; i < nvml.count && i < 16; i++) {
        void *device = NULL;
        eul_nvml_utilization use;
        if (nvml.get_handle(i, &device) == 0 && nvml.get_utilization(device, &use) == 0) {
            sum += use.gpu;
            count++;
        }
    }
    if (count == 0) {
        return 0;
    }
    *pct = sum / count;
    return 1;
}

static void sample_gpu(system_stats *out) {
    if (amd_gpu_busy(&out->gpu_pct)) {
        out->has_gpu = 1;
        snprintf(out->gpu_source, sizeof out->gpu_source, "amdgpu");
    } else if (nvidia_gpu_busy(&out->gpu_pct)) {
        out->has_gpu = 1;
        snprintf(out->gpu_source, sizeof out->gpu_source, "nvidia");
    }
}

// --- memory ------------------------------------------------------------------

static void sample_memory(system_stats *out) {
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) {
        return;
    }
    char line[256];
    long mem_total = 0, mem_avail = 0, mem_free = 0, buffers = 0, cached = 0, s_reclaim = 0;
    long swap_total = 0, swap_free = 0;
    int have_avail = 0;
    while (fgets(line, sizeof line, f)) {
        long kb = 0;
        char key[64];
        if (sscanf(line, "%63s %ld", key, &kb) != 2) {
            continue;
        }
        if (strcmp(key, "MemTotal:") == 0) {
            mem_total = kb;
        } else if (strcmp(key, "MemAvailable:") == 0) {
            mem_avail = kb;
            have_avail = 1;
        } else if (strcmp(key, "MemFree:") == 0) {
            mem_free = kb;
        } else if (strcmp(key, "Buffers:") == 0) {
            buffers = kb;
        } else if (strcmp(key, "Cached:") == 0) {
            cached = kb;
        } else if (strcmp(key, "SReclaimable:") == 0) {
            s_reclaim = kb;
        } else if (strcmp(key, "SwapTotal:") == 0) {
            swap_total = kb;
        } else if (strcmp(key, "SwapFree:") == 0) {
            swap_free = kb;
        }
    }
    fclose(f);

    if (mem_total <= 0) {
        return;
    }
    if (!have_avail) { // pre-3.14 kernels
        mem_avail = mem_free + buffers + cached + s_reclaim;
    }
    out->mem_total_b = (double)mem_total * 1024;
    out->mem_avail_b = (double)mem_avail * 1024;
    out->mem_used_b = out->mem_total_b - out->mem_avail_b;
    out->mem_used_pct = out->mem_used_b / out->mem_total_b * 100;
    out->swap_total_b = (double)swap_total * 1024;
    out->swap_used_b = (double)(swap_total - swap_free) * 1024;
}

// --- disks ---------------------------------------------------------------------

static int known_fs(const char *fs) {
    static const char *const real[] = {
        "ext2", "ext3", "ext4", "xfs", "btrfs", "zfs", "f2fs", "jfs", "reiserfs",
        "vfat", "exfat", "ntfs", "ntfs3", "ntfs-3g", "fuseblk", "udf",
    };
    for (size_t i = 0; i < sizeof real / sizeof real[0]; i++) {
        if (strcmp(fs, real[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

/// /proc/self/mounts escapes space, tab, newline and backslash as \ooo
static void unescape_mount(char *path) {
    char *w = path;
    for (const char *r = path; *r; r++) {
        if (r[0] == '\\' && r[1] >= '0' && r[1] <= '3' && r[2] >= '0' && r[2] <= '7'
            && r[3] >= '0' && r[3] <= '7') {
            *w++ = (char)((r[1] - '0') * 64 + (r[2] - '0') * 8 + (r[3] - '0'));
            r += 3;
        } else {
            *w++ = *r;
        }
    }
    *w = '\0';
}

static void sample_disks(system_stats *out) {
    FILE *f = fopen("/proc/self/mounts", "r");
    if (!f) {
        return;
    }
    char line[1024];
    while (fgets(line, sizeof line, f) && out->disk_count < EUL_MAX_DISKS) {
        char dev[256], mount[256], fs[64];
        if (sscanf(line, "%255s %255s %63s", dev, mount, fs) != 3) {
            continue;
        }
        unescape_mount(mount);
        if (!known_fs(fs)) {
            continue;
        }
        struct stat mount_stat;
        if (stat(mount, &mount_stat) != 0 || !S_ISDIR(mount_stat.st_mode)) {
            continue; // bind mounts of single files (docker's /etc/hosts etc.)
        }
        // bind mounts show the same filesystem under other paths: one device,
        // one row
        int dup = 0;
        for (int i = 0; i < out->disk_count; i++) {
            if (out->disks[i].dev == (unsigned long long)mount_stat.st_dev) {
                dup = 1;
                break;
            }
        }
        if (dup) {
            continue;
        }
        struct statvfs vfs;
        if (statvfs(mount, &vfs) != 0 || vfs.f_blocks == 0) {
            continue;
        }
        eul_disk *d = &out->disks[out->disk_count];
        snprintf(d->mount, sizeof d->mount, "%.159s", mount);
        snprintf(d->fs, sizeof d->fs, "%.23s", fs);
        double frsize = (double)vfs.f_frsize;
        double used = (double)(vfs.f_blocks - vfs.f_bfree) * frsize;
        double avail = (double)vfs.f_bavail * frsize;
        d->total_b = (double)vfs.f_blocks * frsize;
        d->free_b = avail;
        d->used_b = used; // like df: excludes the root reserve, as used_pct does
        d->dev = (unsigned long long)mount_stat.st_dev;
        d->used_pct = used + avail > 0 ? used / (used + avail) * 100 : 0;
        out->disk_count++;
    }
    fclose(f);

    // root first, the rest in mount order
    for (int i = 0; i < out->disk_count; i++) {
        if (strcmp(out->disks[i].mount, "/") == 0 && i > 0) {
            eul_disk root = out->disks[i];
            memmove(&out->disks[1], &out->disks[0], sizeof(eul_disk) * (size_t)i);
            out->disks[0] = root;
            break;
        }
    }
}

// --- network ---------------------------------------------------------------------

static void format_addr(const struct ifaddrs *ifa, char *out, size_t cap) {
    void *src = NULL;
    if (ifa->ifa_addr->sa_family == AF_INET) {
        src = &((struct sockaddr_in *)ifa->ifa_addr)->sin_addr;
    } else if (ifa->ifa_addr->sa_family == AF_INET6) {
        src = &((struct sockaddr_in6 *)ifa->ifa_addr)->sin6_addr;
    }
    if (!src || inet_ntop(ifa->ifa_addr->sa_family, src, out, (socklen_t)cap) == NULL) {
        out[0] = '\0';
    }
}

static void sample_network(stats_ctx *ctx, system_stats *out, double elapsed) {
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) == 0) {
        for (struct ifaddrs *ifa = addrs; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_name || !ifa->ifa_addr) {
                continue;
            }
            int family = ifa->ifa_addr->sa_family;
            if (family != AF_INET && family != AF_INET6) {
                continue;
            }
            eul_iface *iface = NULL;
            for (int i = 0; i < out->iface_count; i++) {
                if (strcmp(out->ifaces[i].name, ifa->ifa_name) == 0) {
                    iface = &out->ifaces[i];
                    break;
                }
            }
            if (!iface && out->iface_count < EUL_MAX_IFACES) {
                iface = &out->ifaces[out->iface_count++];
                memset(iface, 0, sizeof *iface);
                snprintf(iface->name, sizeof iface->name, "%s", ifa->ifa_name);
            }
            if (!iface) {
                continue;
            }
            iface->up = (ifa->ifa_flags & EUL_IFF_UP) != 0;
            if (family == AF_INET && iface->ipv4[0] == '\0') {
                format_addr(ifa, iface->ipv4, sizeof iface->ipv4);
            } else if (family == AF_INET6 && iface->ipv6_count < EUL_MAX_ADDRS) {
                format_addr(ifa, iface->ipv6[iface->ipv6_count], sizeof iface->ipv6[0]);
                if (iface->ipv6[iface->ipv6_count][0] != '\0') {
                    iface->ipv6_count++;
                }
            }
        }
        freeifaddrs(addrs);
    }
    int prev_count = ctx->net_count;
    char prev_name[EUL_MAX_IFACES][16];
    long long prev_rx[EUL_MAX_IFACES], prev_tx[EUL_MAX_IFACES];
    memcpy(prev_name, ctx->net_name, sizeof prev_name);
    memcpy(prev_rx, ctx->net_rx, sizeof prev_rx);
    memcpy(prev_tx, ctx->net_tx, sizeof prev_tx);

    FILE *f = fopen("/proc/net/dev", "r");
    if (!f) {
        return;
    }
    char line[512];
    if (!fgets(line, sizeof line, f) || !fgets(line, sizeof line, f)) { // 2 header lines
        fclose(f);
        return;
    }
    int count = 0, physical = 0;
    double total_rx = 0, total_tx = 0, any_rx = 0, any_tx = 0;
    while (fgets(line, sizeof line, f) && count < EUL_MAX_IFACES) {
        char name[64];
        long long rx = 0, tx = 0;
        char *colon = strchr(line, ':');
        if (!colon) {
            continue;
        }
        *colon = '\0';
        if (sscanf(line, "%63s", name) != 1) {
            continue;
        }
        // fields after the colon: rx bytes, 7 skipped, then tx bytes
        char *cursor = colon + 1, *end = NULL;
        int ok = 1;
        for (int field = 0; field < 9 && ok; field++) {
            long long value = strtoll(cursor, &end, 10);
            if (end == cursor) {
                ok = 0;
                break;
            }
            cursor = end;
            if (field == 0) {
                rx = value;
            } else if (field == 8) {
                tx = value;
            }
        }
        if (!ok) {
            continue;
        }
        long long rx_delta = 0, tx_delta = 0;
        for (int i = 0; i < prev_count; i++) {
            if (strcmp(prev_name[i], name) == 0) {
                // counters reset on reconnect/wrap: treat as zero (#226)
                rx_delta = rx >= prev_rx[i] ? rx - prev_rx[i] : 0;
                tx_delta = tx >= prev_tx[i] ? tx - prev_tx[i] : 0;
                break;
            }
        }
        snprintf(ctx->net_name[count], sizeof ctx->net_name[count], "%.15s", name);
        ctx->net_rx[count] = rx;
        ctx->net_tx[count] = tx;
        count++;

        double secs = elapsed > 0.05 ? elapsed : 0;
        double rx_bps = ctx->initialized && secs > 0 ? (double)rx_delta / secs : 0;
        double tx_bps = ctx->initialized && secs > 0 ? (double)tx_delta / secs : 0;
        for (int i = 0; i < out->iface_count; i++) {
            if (strcmp(out->ifaces[i].name, name) == 0) {
                out->ifaces[i].rx_bps = rx_bps;
                out->ifaces[i].tx_bps = tx_bps;
                break;
            }
        }
        // docker0/veth/br-/tun carry the same bytes again: total only real
        // NICs (they have a backing device); fall back to everything but lo
        // when there are none, as inside a container
        char device_path[128];
        snprintf(device_path, sizeof device_path, "/sys/class/net/%.40s/device", name);
        if (access(device_path, F_OK) == 0) {
            total_rx += (double)rx_delta;
            total_tx += (double)tx_delta;
            physical++;
        }
        if (strcmp(name, "lo") != 0) {
            any_rx += (double)rx_delta;
            any_tx += (double)tx_delta;
        }
    }
    fclose(f);
    ctx->net_count = count;
    if (physical == 0) {
        total_rx = any_rx;
        total_tx = any_tx;
    }
    if (ctx->initialized && elapsed > 0.05) {
        out->net_rx_bps = total_rx / elapsed;
        out->net_tx_bps = total_tx / elapsed;
    }

}

// --- processes ---------------------------------------------------------------------

struct proc_sample {
    int pid;
    long long ticks;
    long long rss_pages;
    double cpu_pct;
    double rss_b;
    char name[64];
};

/// /proc/PID/stat: pid (comm) state ... utime(14) stime(15) ... rss(24)
static int read_proc_stat(int pid, struct proc_sample *out) {
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/stat", pid);
    FILE *f = fopen(path, "r");
    if (!f) {
        return 0;
    }
    char line[1024];
    if (!fgets(line, sizeof line, f)) {
        fclose(f);
        return 0;
    }
    fclose(f);

    // comm may itself hold spaces and parens: it runs from the first '('
    // to the last ')'
    char *open_paren = strchr(line, '(');
    char *close_paren = strrchr(line, ')');
    if (!open_paren || !close_paren || close_paren < open_paren) {
        return 0;
    }
    size_t name_len = (size_t)(close_paren - open_paren - 1);
    if (name_len >= sizeof out->name) {
        name_len = sizeof out->name - 1;
    }
    memcpy(out->name, open_paren + 1, name_len);
    out->name[name_len] = '\0';
    // any process can rename itself (prctl): no escape sequences into the
    // terminal of whoever runs eul
    for (char *c = out->name; *c; c++) {
        if ((unsigned char)*c < 0x20 || *c == 0x7f) {
            *c = '?';
        }
    }

    // after ") " comes the state letter (field 3), then numbers from ppid
    // (field 4): utime is 14, stime 15, rss 24 — proc(5)
    char *p = close_paren + 1;
    while (*p == ' ') {
        p++;
    }
    while (*p && *p != ' ') {
        p++; // state
    }
    long long utime = 0, stime = 0, rss = 0;
    int seen_rss = 0;
    for (int field = 4; field <= 24; field++) {
        char *end;
        long long v = strtoll(p, &end, 10);
        if (end == p) {
            break;
        }
        if (field == 14) {
            utime = v;
        } else if (field == 15) {
            stime = v;
        } else if (field == 24) {
            rss = v;
            seen_rss = 1;
        }
        p = end;
    }
    if (!seen_rss) {
        return 0;
    }
    out->pid = pid;
    out->ticks = utime + stime;
    out->rss_pages = rss;
    return 1;
}

static int find_prev_tick(const stats_ctx *ctx, int pid, long long *ticks) {
    for (int i = 0; i < ctx->proc_epoch; i++) {
        if (ctx->procs[i].pid == pid) {
            *ticks = ctx->procs[i].ticks;
            return 1;
        }
    }
    return 0;
}

static void sample_processes(stats_ctx *ctx, system_stats *out, double elapsed) {
    DIR *dir = opendir("/proc");
    if (!dir) {
        return;
    }
    struct dirent *entry;
    // as many as ctx->procs remembers, so a busy process late in /proc
    // can still reach the top list
    enum { MAX_SAMPLES = sizeof ctx->procs / sizeof ctx->procs[0] };
    struct proc_sample *samples = malloc(sizeof *samples * MAX_SAMPLES);
    if (!samples) {
        closedir(dir);
        return;
    }
    int sample_count = 0;
    int total = 0;
    long page_size = sysconf(_SC_PAGESIZE);
    long clk = sysconf(_SC_CLK_TCK);
    double secs = elapsed > 0.05 ? elapsed : 0;

    while ((entry = readdir(dir)) != NULL) {
        if (!isdigit(entry->d_name[0])) {
            continue;
        }
        total++;
        if (sample_count >= MAX_SAMPLES) {
            continue;
        }
        struct proc_sample s;
        if (!read_proc_stat(atoi(entry->d_name), &s)) {
            continue;
        }
        long long prev = 0;
        int have_prev = ctx->initialized && find_prev_tick(ctx, s.pid, &prev);
        s.cpu_pct = have_prev && secs > 0
                        ? (double)(s.ticks - prev) / clk / secs * 100.0
                        : 0;
        if (s.cpu_pct < 0) {
            s.cpu_pct = 0; // pid reused since the last sample
        }
        s.rss_b = (double)s.rss_pages * page_size;
        if (s.rss_b <= 0 && s.cpu_pct <= 0) {
            continue; // idle background noise
        }
        samples[sample_count++] = s;
    }
    closedir(dir);
    out->proc_count = total;

    // record this tick's per-pid ticks (replace epoch; recycle slots)
    int epoch = 0;
    for (int i = 0; i < sample_count && epoch < (int)(sizeof ctx->procs / sizeof ctx->procs[0]); i++) {
        ctx->procs[epoch].pid = samples[i].pid;
        ctx->procs[epoch].ticks = samples[i].ticks;
        epoch++;
    }
    ctx->proc_epoch = epoch;

    // top lists: insertion sort into small fixed arrays
    for (int i = 0; i < sample_count; i++) {
        for (int list = 0; list < 2; list++) {
            double value = list == 0 ? samples[i].cpu_pct : (double)samples[i].rss_b;
            eul_proc *top = list == 0 ? out->top_cpu : out->top_mem;
            int *count = list == 0 ? &out->top_cpu_count : &out->top_mem_count;
            if (*count < EUL_TOP_PROCS) {
                (*count)++;
            } else if (value <= (list == 0 ? top[*count - 1].cpu_pct : top[*count - 1].rss_b)) {
                continue;
            }
            int pos = *count - 1;
            while (pos > 0
                   && value > (list == 0 ? top[pos - 1].cpu_pct : top[pos - 1].rss_b)) {
                top[pos] = top[pos - 1];
                pos--;
            }
            top[pos].pid = samples[i].pid;
            snprintf(top[pos].name, sizeof top[pos].name, "%s", samples[i].name);
            top[pos].cpu_pct = samples[i].cpu_pct;
            top[pos].rss_b = samples[i].rss_b;
        }
    }
    free(samples);
}

// --- battery ------------------------------------------------------------------

static void sample_battery(system_stats *out) {
    DIR *dir = opendir("/sys/class/power_supply");
    if (!dir) {
        return;
    }
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        char type_path[192], cap_path[192], status_path[192];
        snprintf(type_path, sizeof type_path, "/sys/class/power_supply/%.100s/type",
                 entry->d_name);
        FILE *tf = fopen(type_path, "r");
        if (!tf) {
            continue;
        }
        char type[32] = "";
        if (fgets(type, sizeof type, tf)) {
            size_t n = strlen(type);
            if (n && type[n - 1] == '\n') {
                type[n - 1] = '\0';
            }
        }
        fclose(tf);
        if (strcmp(type, "Battery") != 0) {
            continue;
        }
        // a wireless mouse/keyboard battery is type Battery too, scope Device
        char scope_path[192], scope[32];
        snprintf(scope_path, sizeof scope_path, "/sys/class/power_supply/%.100s/scope", entry->d_name);
        read_line(scope_path, scope, sizeof scope);
        if (strcmp(scope, "Device") == 0) {
            continue;
        }
        snprintf(cap_path, sizeof cap_path, "/sys/class/power_supply/%.100s/capacity",
                 entry->d_name);
        snprintf(status_path, sizeof status_path, "/sys/class/power_supply/%.100s/status",
                 entry->d_name);
        FILE *cf = fopen(cap_path, "r");
        if (!cf) {
            continue;
        }
        int pct = 0;
        int ok = fscanf(cf, "%d", &pct) == 1;
        fclose(cf);
        if (!ok) {
            continue;
        }
        int charging = 0;
        FILE *sf = fopen(status_path, "r");
        if (sf) {
            char status[32] = "";
            if (fgets(status, sizeof status, sf)) {
                charging = strncmp(status, "Charging", 8) == 0
                           || strncmp(status, "Full", 4) == 0;
            }
            fclose(sf);
        }
        out->has_battery = 1;
        out->battery_pct = pct;
        out->battery_charging = charging;
        break;
    }
    closedir(dir);
}

// --- entry point -----------------------------------------------------------------

void stats_sample(stats_ctx *ctx, system_stats *out) {
    double now = mono_now();
    double elapsed = ctx->initialized ? now - ctx->mono_time : 0;

    memset(out, 0, sizeof *out);
    read_hostname(out->hostname, sizeof out->hostname);
    read_distro(out->distro, sizeof out->distro);
    read_kernel(out->kernel, sizeof out->kernel);
    out->uptime_s = read_uptime();

    sample_cpu(ctx, out, elapsed);
    sample_gpu(out);
    sample_memory(out);
    sample_disks(out);
    sample_network(ctx, out, elapsed);
    sample_processes(ctx, out, elapsed);
    sample_battery(out);

    ctx->mono_time = now;
    ctx->initialized = 1;
}

// --- formatting --------------------------------------------------------------------

void format_bytes(double bytes, char *out, size_t cap) {
    if (bytes < 0) {
        bytes = 0;
    }
    double kb = bytes / 1024;
    double mb = kb / 1024;
    double gb = mb / 1024;
    if (mb >= 1024) {
        snprintf(out, cap, gb >= 100 ? "%.0f GB" : "%.1f GB", gb);
    } else if (kb >= 1024) {
        snprintf(out, cap, mb >= 100 ? "%.0f MB" : "%.1f MB", mb);
    } else {
        snprintf(out, cap, "%.0f KB", kb);
    }
}

void format_rate(double bytes_per_sec, char *out, size_t cap) {
    format_bytes(bytes_per_sec, out, cap);
    size_t n = strlen(out);
    snprintf(out + n, cap - n, "/s");
}
