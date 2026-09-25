//
//  main.c
//  eul (linux)
//
//  A calm system monitor for the terminal — the command line variant of
//  the macOS menu bar app. Glanceable when things are fine; when a signal
//  trips a threshold, exactly the responsible number tints amber or red.
//

#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include "json.h"
#include "peer.h"
#include "stats.h"

#define EUL_VERSION "2.3.0"

#define COLOR_RESET "\033[0m"
#define COLOR_BOLD "\033[1m"
#define COLOR_DIM "\033[2m"
#define COLOR_AMBER "\033[33m"
#define COLOR_RED "\033[31m"
#define SCREEN_ENTER "\033[?1049h\033[H\033[?25l"
#define SCREEN_LEAVE "\033[?25h\033[?1049l"

typedef struct {
    double interval;
    int once;
    int json_output;
    int no_color;
    int ascii;
    int show_top;
    int show_peers;
    int headless;
    const char *secret;
    const char *name;
    const char *brokers; // comma separated host:port overrides
    int want_generate_secret;
} options;

static volatile sig_atomic_t interrupted = 0;

static void on_signal(int sig) {
    (void)sig;
    interrupted = 1;
}

static void usage(FILE *out) {
    fprintf(out,
        "eul %s (linux) — a calm system monitor for the terminal\n"
        "\n"
        "usage: eul [options]\n"
        "\n"
        "  -i, --interval SECONDS  refresh interval, fractions ok (default 2)\n"
        "  -1, --once              print one frame and exit\n"
        "  -j, --json              print one JSON snapshot and exit\n"
        "      --no-color          plain text, no ANSI colors (NO_COLOR works too)\n"
        "      --ascii             # bars instead of unicode blocks\n"
        "      --no-top            hide the top processes table\n"
        "  -s, --share SECRET      join the eul peer network (EUL_SHARE_SECRET env)\n"
        "  -p, --peers             show discovered peers in the dashboard\n"
        "      --name NAME         name advertised to peers (default: hostname)\n"
        "      --broker HOST:PORT  replace the default broker list (comma separated)\n"
        "      --headless          no dashboard; share only (for systemd)\n"
        "      --generate-secret   print a fresh shareable secret and exit\n"
        "  -v, --version           print version\n"
        "  -h, --help              this help\n",
        EUL_VERSION);
}

static void parse_args(int argc, char **argv, options *opt) {
    memset(opt, 0, sizeof *opt);
    opt->interval = 2.0;
    opt->show_top = 1;

    #define NEXT() (i + 1 < argc ? argv[++i] : NULL)
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];

        if (strcmp(a, "-i") == 0 || strcmp(a, "--interval") == 0) {
            const char *v = NEXT();
            char *end = NULL;
            double value = v ? strtod(v, &end) : 0;
            if (!v || end == v || *end != '\0' || !isfinite(value) || value <= 0) {
                fprintf(stderr, "eul: -i wants a positive number of seconds\n");
                exit(2);
            }
            opt->interval = value;
        } else if (strcmp(a, "-1") == 0 || strcmp(a, "--once") == 0) {
            opt->once = 1;
        } else if (strcmp(a, "-j") == 0 || strcmp(a, "--json") == 0) {
            opt->json_output = 1;
        } else if (strcmp(a, "--no-color") == 0) {
            opt->no_color = 1;
        } else if (strcmp(a, "--ascii") == 0) {
            opt->ascii = 1;
        } else if (strcmp(a, "--no-top") == 0) {
            opt->show_top = 0;
        } else if (strcmp(a, "-s") == 0 || strcmp(a, "--share") == 0) {
            opt->secret = NEXT();
        } else if (strcmp(a, "-p") == 0 || strcmp(a, "--peers") == 0) {
            opt->show_peers = 1;
        } else if (strcmp(a, "--name") == 0) {
            opt->name = NEXT();
        } else if (strcmp(a, "--broker") == 0) {
            opt->brokers = NEXT();
        } else if (strcmp(a, "--headless") == 0) {
            opt->headless = 1;
        } else if (strcmp(a, "--generate-secret") == 0) {
            opt->want_generate_secret = 1;
        } else if (strcmp(a, "-v") == 0 || strcmp(a, "--version") == 0) {
            printf("eul %s (linux)\n", EUL_VERSION);
            exit(0);
        } else if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) {
            usage(stdout);
            exit(0);
        } else {
            fprintf(stderr, "eul: unknown option %s\n\n", a);
            usage(stderr);
            exit(2);
        }
    }
    #undef NEXT

    if (!opt->secret) {
        opt->secret = getenv("EUL_SHARE_SECRET");
    }
    if ((opt->show_peers || opt->headless) && !opt->secret) {
        fprintf(stderr, "eul: --peers/--headless need --share SECRET (or EUL_SHARE_SECRET)\n");
        exit(2);
    }
    if (opt->headless && (opt->json_output || opt->once)) {
        fprintf(stderr, "eul: --headless has no dashboard; drop --json/--once\n");
        exit(2);
    }
    if (opt->interval < 0.25) {
        opt->interval = 0.25;
    }
    if (opt->json_output) {
        opt->once = 1;
    }
    if (!isatty(STDOUT_FILENO)) {
        opt->no_color = 1;
    }
    if (getenv("NO_COLOR")) {
        opt->no_color = 1;
    }
}

// --- rendering helpers ---------------------------------------------------------------

typedef struct {
    int color;
    int ascii;
} theme;

/// value tinted by eul's health language: monochrome when fine, amber at
/// elevated, red at critical
static const char *tint(const theme *t, double pct, double elevated, double critical) {
    if (!t->color) {
        return "";
    }
    if (pct >= critical) {
        return COLOR_RED;
    }
    if (pct >= elevated) {
        return COLOR_AMBER;
    }
    return "";
}

static void bar(const theme *t, double pct, int width, char *out, size_t cap) {
    if ((size_t)width + 3 > cap) {
        width = (int)cap - 3;
    }
    if (width < 1) {
        if (cap > 0) {
            out[0] = '\0';
        }
        return;
    }
    if (pct < 0) {
        pct = 0;
    }
    if (pct > 100) {
        pct = 100;
    }
    double exact = pct / 100.0 * width;
    int full = (int)exact;
    int part = (int)((exact - full) * 8.0);
    if (part > 7) {
        part = 0;
        full++;
    }

    size_t len = 0;
    out[len++] = '[';
    for (int i = 0; i < width && len + 12 < cap; i++) {
        if (i < full) {
            len += (size_t)sprintf(out + len, "%s", t->ascii ? "#" : "█");
        } else if (i == full && part > 0 && !t->ascii) {
            static const char *const partials[8] = {
                "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█",
            };
            len += (size_t)sprintf(out + len, "%s", partials[part - 1]);
        } else {
            len += (size_t)sprintf(out + len, "%s", t->ascii ? "-" : "░");
        }
    }
    out[len++] = ']';
    out[len] = '\0';
}

static void uptime_string(double seconds, char *out, size_t cap) {
    long total = (long)seconds;
    long days = total / 86400;
    long hrs = (total % 86400) / 3600;
    long mins = (total % 3600) / 60;
    if (days > 0) {
        snprintf(out, cap, "%ldd %ldh %ldm", days, hrs, mins);
    } else {
        snprintf(out, cap, "%ldh %ldm", hrs, mins);
    }
}

// eul §2.4 disk thresholds: elevated < 10% or < 15 GB free, critical < 3% or < 4 GB
static const char *disk_color(const theme *t, const eul_disk *d) {
    if (!t->color) {
        return "";
    }
    double free_gb = d->free_b / 1e9;
    if (d->used_pct >= 97 || free_gb < 4) {
        return COLOR_RED;
    }
    if (d->used_pct >= 90 || free_gb < 15) {
        return COLOR_AMBER;
    }
    return "";
}

static int terminal_size(int *rows, int *cols) {
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) != 0) {
        *rows = 24;
        *cols = 80;
        return 0;
    }
    *rows = ws.ws_row > 0 ? ws.ws_row : 24;
    *cols = ws.ws_col > 0 ? ws.ws_col : 80;
    return 1;
}

/// writes one frame line, cut to `width` columns. Escape sequences take no
/// columns; every UTF-8 sequence here (bars, arrows, °) is one column.
/// On a TTY the rest of the row is erased, so a shorter frame leaves no
/// debris from the previous one.
static void emit_clipped(const char *line, size_t len, int width, int tty) {
    int cols = 0;
    size_t i = 0;
    while (i < len) {
        unsigned char c = (unsigned char)line[i];
        if (c == 0x1b) { // CSI: ESC [ params final
            size_t j = i + 1;
            if (j < len && line[j] == '[') {
                j++;
                while (j < len && !((unsigned char)line[j] >= 0x40 && (unsigned char)line[j] <= 0x7e)) {
                    j++;
                }
                j++;
            }
            fwrite(line + i, 1, (j < len ? j : len) - i, stdout);
            i = j;
            continue;
        }
        size_t n = c < 0x80 ? 1 : c >= 0xf0 ? 4 : c >= 0xe0 ? 3 : c >= 0xc0 ? 2 : 1;
        if (cols >= width) {
            i += n; // keep scanning so trailing color resets still go out
            continue;
        }
        fwrite(line + i, 1, i + n <= len ? n : len - i, stdout);
        cols++;
        i += n;
    }
    fputs(tty ? "\033[K\n" : "\n", stdout);
}

// --- dashboard -------------------------------------------------------------------------

static void render_dashboard(const system_stats *s, const theme *t, const options *opt,
                             peer_store *ps, int frame) {
    int rows, width;
    terminal_size(&rows, &width);
    // built in memory, then emitted line by line clipped to the terminal
    // width — a wrapped line would throw the row budget off
    char *frame_buf = NULL;
    size_t frame_len = 0;
    FILE *o = open_memstream(&frame_buf, &frame_len);
    if (!o) {
        return;
    }
    int width_bars = width >= 110 ? 60 : width >= 90 ? 44 : 28;
    const char *dim = t->color ? COLOR_DIM : "";
    const char *bold = t->color ? COLOR_BOLD : "";
    const char *rst = t->color ? COLOR_RESET : "";

    // header: pulse dot, host, distro, kernel, uptime
    char up[48];
    uptime_string(s->uptime_s, up, sizeof up);
    fprintf(o, "%s%s eul %s", bold, frame % 2 ? "·" : " ", s->hostname);
    fprintf(o, "  %s· %s", dim, s->distro);
    fprintf(o, "  %s· %s", dim, s->kernel);
    fprintf(o, "  %s· up %s", dim, up);
    fprintf(o, "%s\n", rst);
    rows--;
    int rows_left = rows - 1;

    // cpu: total usage, load, temperature, frequency
    char bar_buf[600];
    bar(t, s->cpu_usage_pct, width_bars, bar_buf, sizeof bar_buf);
    fprintf(o, "%s cpu %s", dim, rst);
    fprintf(o, "%s%4.0f%% %s %s load %.2f %.2f %.2f",
           tint(t, s->cpu_usage_pct, 90, 97), s->cpu_usage_pct, bar_buf, rst,
           s->load[0], s->load[1], s->load[2]);
    if (s->has_temp) {
        fprintf(o, "%s%4.0f°C%s", tint(t, s->temp_c, 80, 95), s->temp_c, rst);
    }
    if (s->has_freq) {
        fprintf(o, "  %.1f GHz", s->freq_ghz);
    }
    fprintf(o, "\n");

    // per-core bars
    if (s->cpu_count > 1 && s->cpu_count <= 32 && rows_left > 8) {
        int per_line = width >= 130 ? 4 : width >= 90 ? 3 : 2;
        int printed = 0;
        while (printed < s->cpu_count && rows_left > 6) {
            fprintf(o, " ");
            for (int i = 0; i < per_line && printed < s->cpu_count; i++, printed++) {
                char core_bar[48];
                bar(t, s->cpu_core[printed], per_line >= 4 ? 12 : 10, core_bar,
                    sizeof core_bar);
                double pct = s->cpu_core[printed];
                fprintf(o, "%s%2d%s %s%s%3.0f%%%s ",
                       dim, printed, rst,
                       tint(t, pct, 90, 97), core_bar, pct, rst);
            }
            fprintf(o, "\n");
            rows_left--;
        }
    }

    // gpu, when there is a readable one (AMD, NVIDIA)
    if (s->has_gpu && rows_left > 5) {
        char gpu_bar[600];
        bar(t, s->gpu_pct, width_bars, gpu_bar, sizeof gpu_bar);
        fprintf(o, "%s gpu %s", dim, rst);
        fprintf(o, "%s%4.0f%% %s %s  %s%s%s\n", tint(t, s->gpu_pct, 90, 97), s->gpu_pct, gpu_bar, rst,
                dim, s->gpu_source, rst);
        rows_left--;
    }

    // memory + swap
    if (s->mem_total_b > 0 && rows_left > 4) {
        char used[24], total[24];
        format_bytes(s->mem_used_b, used, sizeof used);
        format_bytes(s->mem_total_b, total, sizeof total);
        double avail_pct = s->mem_avail_b / s->mem_total_b * 100;
        char mem_bar[256];
        bar(t, s->mem_used_pct, width_bars, mem_bar, sizeof mem_bar);
        fprintf(o, "%s mem %s", dim, rst);
        fprintf(o, "%s%4.0f%% %s %s  %s of %s\n",
               tint(t, 100 - avail_pct, 90, 97), s->mem_used_pct, mem_bar, rst,
               used, total);
        rows_left--;
        if (s->swap_total_b > 0 && rows_left > 4) {
            char swap_used[24], swap_total[24];
            format_bytes(s->swap_used_b, swap_used, sizeof swap_used);
            format_bytes(s->swap_total_b, swap_total, sizeof swap_total);
            double swap_pct = s->swap_used_b / s->swap_total_b * 100;
            fprintf(o, "      %sswap %4.0f%%%s  %s of %s\n",
                   tint(t, swap_pct, 80, 95), swap_pct, rst,
                   swap_used, swap_total);
            rows_left--;
        }
    }

    // disks, one row each; then the network line
    if (rows_left > 4) {
        for (int i = 0; i < s->disk_count && rows_left > 3; i++) {
            const eul_disk *d = &s->disks[i];
            char used[24], total[24];
            format_bytes(d->used_b, used, sizeof used);
            format_bytes(d->total_b, total, sizeof total);
            char disk_bar[80];
            bar(t, d->used_pct, 18, disk_bar, sizeof disk_bar);
            fprintf(o, "%s%s%s %s%-12s %s %5.1f%%  %s of %s%s\n",
                   dim, i == 0 ? " disk" : "     ", rst,
                   disk_color(t, d), d->mount, disk_bar, d->used_pct, used,
                   total, rst);
            rows_left--;
        }
        char in[24], out[24];
        format_rate(s->net_rx_bps, in, sizeof in);
        format_rate(s->net_tx_bps, out, sizeof out);
        fprintf(o, "%s net %s", dim, rst);
        fprintf(o, "%s↓%s %s  %s↑%s %s",
               dim, rst, in, dim, rst, out);
        int shown = 0;
        for (int k = 0; k < s->iface_count && shown < 2; k++) {
            const eul_iface *ifc = &s->ifaces[k];
            if (strcmp(ifc->name, "lo") == 0 || ifc->ipv4[0] == '\0') {
                continue;
            }
            fprintf(o, "%s %s %s", shown ? "," : " ", ifc->name, ifc->ipv4);
            shown++;
        }
        fprintf(o, "\n");
        rows_left--;
    }

    // top processes: cpu on the left, memory on the right
    if (opt->show_top && rows_left > 4
        && (s->top_cpu_count > 0 || s->top_mem_count > 0)) {
        fprintf(o, "%s top cpu              top mem%s\n", dim, rst);
        rows_left--;
        for (int i = 0; i < EUL_TOP_PROCS && rows_left > 2; i++) {
            if (i >= s->top_cpu_count && i >= s->top_mem_count) {
                break;
            }
            char left[64] = "";
            char right[64] = "";
            if (i < s->top_cpu_count) {
                const eul_proc *p = &s->top_cpu[i];
                snprintf(left, sizeof left, "%5.1f%% %s", p->cpu_pct, p->name);
            }
            if (i < s->top_mem_count) {
                const eul_proc *p = &s->top_mem[i];
                char rss[24];
                format_bytes(p->rss_b, rss, sizeof rss);
                snprintf(right, sizeof right, "%7s %s", rss, p->name);
            }
            double left_pct = i < s->top_cpu_count ? s->top_cpu[i].cpu_pct : 0;
            fprintf(o, " %s%-22s%s %s%22s%s\n",
                   tint(t, left_pct, 70, 90), left, rst,
                   rst, right, rst);
            rows_left--;
        }
    }

    // peers
    if (ps != NULL && rows_left >= 1) {
        pthread_mutex_lock(&ps->lock);
        fprintf(o, "%s peers %s", dim, rst);
        if (!ps->connected) {
            fprintf(o, "connecting…");
        } else {
            fprintf(o, "%s sharing via %s", ps->self_name, ps->broker_label);
        }
        fprintf(o, "\n");
        rows_left--;

        for (int i = 0; i < ps->peer_count && rows_left >= 1; i++, rows_left--) {
            const peer_entry *p = &ps->peers[i];
            fprintf(o, "   %s%s%s", bold, p->name, rst);
            if (p->cpu >= 0) {
                fprintf(o, "  cpu %s%.0f%%%s", tint(t, p->cpu, 90, 97), p->cpu, rst);
            }
            if (p->memory >= 0) {
                fprintf(o, "  mem %s%.0f%%%s", tint(t, p->memory, 85, 95), p->memory, rst);
            }
            double temp = peer_temperature_celsius(p);
            if (temp > 0) {
                fprintf(o, "  %.0f°C", temp);
            }
            if (p->net_in > 0 || p->net_out > 0) {
                char in[24], out[24];
                format_rate(p->net_in, in, sizeof in);
                format_rate(p->net_out, out, sizeof out);
                fprintf(o, "  ↓%s ↑%s", in, out);
            }
            fprintf(o, "\n");
        }
        pthread_mutex_unlock(&ps->lock);
    }

    fclose(o);
    int tty = isatty(STDOUT_FILENO);
    for (char *line = frame_buf; line && *line;) {
        char *nl = strchr(line, '\n');
        size_t len = nl ? (size_t)(nl - line) : strlen(line);
        emit_clipped(line, len, width, tty);
        line = nl ? nl + 1 : NULL;
    }
    free(frame_buf);
    if (tty) {
        fputs("\033[J", stdout); // clear anything below in case the window shrank
    }
    fflush(stdout);
}

// --- JSON output --------------------------------------------------------------------

static void print_json(const system_stats *s, const options *opt, peer_store *ps) {
    // 64 interfaces × their addresses can outgrow a stack buffer
    size_t cap = 256 * 1024;
    char *buf = malloc(cap);
    if (!buf) {
        return;
    }
    json_writer w;
    json_writer_init(&w, buf, cap);

    json_put_raw(&w, "{");
    json_put_raw(&w, "\"hostname\":");
    json_put_string(&w, s->hostname);
    json_put_raw(&w, ",\"os\":");
    json_put_string(&w, s->distro);
    json_put_raw(&w, ",\"kernel\":");
    json_put_string(&w, s->kernel);
    json_put_raw(&w, ",\"uptime_seconds\":");
    json_put_double(&w, s->uptime_s);

    char num[48];
    json_put_raw(&w, ",\"cpu\":{\"usage_pct\":");
    json_put_double(&w, s->cpu_usage_pct);
    json_put_raw(&w, ",\"cores\":[");
    for (int i = 0; i < s->cpu_count; i++) {
        if (i) {
            json_put_raw(&w, ",");
        }
        json_put_double(&w, s->cpu_core[i]);
    }
    json_put_raw(&w, "],\"count\":");
    snprintf(num, sizeof num, "%d", s->cpu_count);
    json_put_raw(&w, num);
    json_put_raw(&w, ",\"loadavg\":[");
    json_put_double(&w, s->load[0]);
    json_put_raw(&w, ",");
    json_put_double(&w, s->load[1]);
    json_put_raw(&w, ",");
    json_put_double(&w, s->load[2]);
    json_put_raw(&w, "]");
    if (s->has_temp) {
        json_put_raw(&w, ",\"temp_c\":");
        json_put_double(&w, s->temp_c);
    }
    if (s->has_freq) {
        json_put_raw(&w, ",\"freq_ghz\":");
        json_put_double(&w, s->freq_ghz);
    }
    json_put_raw(&w, "}");

    json_put_raw(&w, ",\"gpu\":");
    if (s->has_gpu) {
        json_put_raw(&w, "{\"usage_pct\":");
        json_put_double(&w, s->gpu_pct);
        json_put_raw(&w, ",\"source\":");
        json_put_string(&w, s->gpu_source);
        json_put_raw(&w, "}");
    } else {
        json_put_raw(&w, "null");
    }

    json_put_raw(&w, ",\"memory\":{\"total_bytes\":");
    json_put_double(&w, s->mem_total_b);
    json_put_raw(&w, ",\"used_bytes\":");
    json_put_double(&w, s->mem_used_b);
    json_put_raw(&w, ",\"available_bytes\":");
    json_put_double(&w, s->mem_avail_b);
    json_put_raw(&w, ",\"used_pct\":");
    json_put_double(&w, s->mem_used_pct);
    json_put_raw(&w, ",\"swap_total_bytes\":");
    json_put_double(&w, s->swap_total_b);
    json_put_raw(&w, ",\"swap_used_bytes\":");
    json_put_double(&w, s->swap_used_b);
    json_put_raw(&w, "}");

    json_put_raw(&w, ",\"disks\":[");
    for (int i = 0; i < s->disk_count; i++) {
        if (i) {
            json_put_raw(&w, ",");
        }
        json_put_raw(&w, "{\"mount\":");
        json_put_string(&w, s->disks[i].mount);
        json_put_raw(&w, ",\"fs\":");
        json_put_string(&w, s->disks[i].fs);
        json_put_raw(&w, ",\"total_bytes\":");
        json_put_double(&w, s->disks[i].total_b);
        json_put_raw(&w, ",\"free_bytes\":");
        json_put_double(&w, s->disks[i].free_b);
        json_put_raw(&w, ",\"used_pct\":");
        json_put_double(&w, s->disks[i].used_pct);
        json_put_raw(&w, "}");
    }
    json_put_raw(&w, "]");

    json_put_raw(&w, ",\"network\":{\"rx_bps\":");
    json_put_double(&w, s->net_rx_bps);
    json_put_raw(&w, ",\"tx_bps\":");
    json_put_double(&w, s->net_tx_bps);
    json_put_raw(&w, ",\"interfaces\":[");
    for (int i = 0; i < s->iface_count; i++) {
        if (i) {
            json_put_raw(&w, ",");
        }
        json_put_raw(&w, "{\"name\":");
        json_put_string(&w, s->ifaces[i].name);
        json_put_raw(&w, ",\"rx_bps\":");
        json_put_double(&w, s->ifaces[i].rx_bps);
        json_put_raw(&w, ",\"tx_bps\":");
        json_put_double(&w, s->ifaces[i].tx_bps);
        json_put_raw(&w, ",\"ipv4\":");
        json_put_string(&w, s->ifaces[i].ipv4);
        json_put_raw(&w, ",\"ipv6\":[");
        for (int k = 0; k < s->ifaces[i].ipv6_count; k++) {
            if (k) {
                json_put_raw(&w, ",");
            }
            json_put_string(&w, s->ifaces[i].ipv6[k]);
        }
        json_put_raw(&w, "]}");
    }
    json_put_raw(&w, "]}");

    json_put_raw(&w, ",\"top_cpu\":[");
    for (int i = 0; i < s->top_cpu_count; i++) {
        if (i) {
            json_put_raw(&w, ",");
        }
        json_put_raw(&w, "{\"pid\":");
        snprintf(num, sizeof num, "%d", s->top_cpu[i].pid);
        json_put_raw(&w, num);
        json_put_raw(&w, ",\"name\":");
        json_put_string(&w, s->top_cpu[i].name);
        json_put_raw(&w, ",\"cpu_pct\":");
        json_put_double(&w, s->top_cpu[i].cpu_pct);
        json_put_raw(&w, ",\"rss_bytes\":");
        json_put_double(&w, s->top_cpu[i].rss_b);
        json_put_raw(&w, "}");
    }
    json_put_raw(&w, "],\"top_mem\":[");
    for (int i = 0; i < s->top_mem_count; i++) {
        if (i) {
            json_put_raw(&w, ",");
        }
        json_put_raw(&w, "{\"pid\":");
        snprintf(num, sizeof num, "%d", s->top_mem[i].pid);
        json_put_raw(&w, num);
        json_put_raw(&w, ",\"name\":");
        json_put_string(&w, s->top_mem[i].name);
        json_put_raw(&w, ",\"rss_bytes\":");
        json_put_double(&w, s->top_mem[i].rss_b);
        json_put_raw(&w, "}");
    }
    json_put_raw(&w, "]");

    json_put_raw(&w, ",\"processes\":");
    snprintf(num, sizeof num, "%d", s->proc_count);
    json_put_raw(&w, num);

    json_put_raw(&w, ",\"battery\":");
    if (s->has_battery) {
        json_put_raw(&w, "{\"percent\":");
        snprintf(num, sizeof num, "%d", s->battery_pct);
        json_put_raw(&w, num);
        json_put_raw(&w, ",\"charging\":");
        json_put_raw(&w, s->battery_charging ? "true" : "false");
        json_put_raw(&w, "}");
    } else {
        json_put_raw(&w, "null");
    }

    if (ps != NULL) {
        pthread_mutex_lock(&ps->lock);
        json_put_raw(&w, ",\"peers\":[");
        for (int i = 0; i < ps->peer_count; i++) {
            if (i) {
                json_put_raw(&w, ",");
            }
            const peer_entry *p = &ps->peers[i];
            json_put_raw(&w, "{\"name\":");
            json_put_string(&w, p->name);
            // unknown values are null, not -1
            double values[] = { p->cpu, p->memory, peer_temperature_celsius(p) };
            const char *keys[] = { ",\"cpu\":", ",\"memory\":", ",\"temperature_c\":" };
            for (int k = 0; k < 3; k++) {
                json_put_raw(&w, keys[k]);
                if (values[k] < 0) {
                    json_put_raw(&w, "null");
                } else {
                    json_put_double(&w, values[k]);
                }
            }
            json_put_raw(&w, ",\"net_in\":");
            json_put_double(&w, p->net_in);
            json_put_raw(&w, ",\"net_out\":");
            json_put_double(&w, p->net_out);
            json_put_raw(&w, "}");
        }
        json_put_raw(&w, "]");
        pthread_mutex_unlock(&ps->lock);
    }

    json_put_raw(&w, "}\n");
    if (w.truncated) {
        fprintf(stderr, "eul: JSON snapshot too large\n"); // never emit cut-off JSON
    } else {
        fwrite(buf, 1, w.len, stdout);
    }
    free(buf);
    (void)opt;
}

// --- main ------------------------------------------------------------------------------

int main(int argc, char **argv) {
    options opt;
    parse_args(argc, argv, &opt);

    if (opt.want_generate_secret) {
        char secret[64];
        peer_generate_secret(secret, sizeof secret);
        printf("%s\n", secret);
        return 0;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);
    signal(SIGQUIT, on_signal);
    signal(SIGPIPE, SIG_IGN);

    peer_store peer;
    peer_store *ps = NULL;
    if (opt.secret) {
        if (peer_start(&peer, opt.secret, opt.name, opt.brokers)) {
            ps = &peer;
        } else {
            fprintf(stderr, "eul: unable to start the peer share thread\n");
        }
    }

    theme t = { .color = !opt.no_color, .ascii = opt.ascii };
    stats_ctx ctx;
    stats_init(&ctx);

    if (opt.headless) {
        // no dashboard — just share, log status transitions to stderr
        if (ps == NULL) {
            fprintf(stderr, "eul: --headless needs a secret (--share or EUL_SHARE_SECRET)\n");
            return 1;
        }
        fprintf(stderr, "eul: connecting to the peer relays\n");
        int was_connected = 0; // nothing to report until the first connect
        while (!interrupted) {
            struct timespec ts = { 0, 200 * 1000 * 1000 };
            nanosleep(&ts, NULL);
            pthread_mutex_lock(&peer.lock);
            int connected = peer.connected;
            int count = peer.peer_count;
            pthread_mutex_unlock(&peer.lock);
            if (connected != was_connected) {
                was_connected = connected;
                pthread_mutex_lock(&peer.lock);
                if (connected) {
                    fprintf(stderr, "eul: sharing via %s\n", peer.broker_label);
                } else {
                    fprintf(stderr, "eul: no peer relay reachable, retrying\n");
                }
                pthread_mutex_unlock(&peer.lock);
            }
            (void)count;
        }
        if (ps) {
            peer_stop(ps);
        }
        return 0;
    }

    system_stats stats;
    int frame = 0;
    int screen_active = 0;
    int tty = isatty(STDOUT_FILENO);
    if (opt.once || opt.json_output) {
        // every rate is a delta: one sample alone would read 0% / 0 B/s
        stats_sample(&ctx, &stats);
        struct timespec settle = { 0, 500 * 1000 * 1000 };
        nanosleep(&settle, NULL);
    }
    for (;;) {
        stats_sample(&ctx, &stats);
        frame++;

        if (opt.once || opt.json_output) {
            if (opt.json_output) {
                print_json(&stats, &opt, ps);
            } else {
                render_dashboard(&stats, &t, &opt, ps, frame);
            }
            break;
        }

        // piped or redirected: plain frames one after another, no cursor
        // control in the file
        if (tty && !screen_active) {
            fputs(SCREEN_ENTER, stdout);
            screen_active = 1;
        }
        if (tty) {
            printf("\033[H");
        } else if (frame > 1) {
            printf("\n");
        }
        render_dashboard(&stats, &t, &opt, ps, frame);

        // sleep in small slices so Ctrl+C feels instant
        double remaining = opt.interval;
        while (remaining > 0 && !interrupted) {
            double slice = remaining > 0.2 ? 0.2 : remaining;
            struct timespec ts = { (time_t)slice, (long)((slice - (long)slice) * 1e9) };
            nanosleep(&ts, NULL);
            remaining -= slice;
        }
        if (interrupted) {
            break;
        }
    }

    if (screen_active) {
        fputs(SCREEN_LEAVE, stdout);
    }
    if (ps) {
        peer_stop(ps);
    }
    return 0;
}
