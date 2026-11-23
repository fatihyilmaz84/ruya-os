/* SPDX-License-Identifier: CC0-1.0 */
/*
 * platform-demo: the smallest app that uses the console's lifecycle events
 * (org.ruyaos.Platform1.Lifecycle, experimental). It registers once, saves and answers SaveDone
 * on Stopping, reports Resume(frozen_ms), and detects a freeze from its own clock first, because
 * an app that did not register, a console without the service and a failed call give no event.
 * It runs the same without the service at all.
 *
 * It talks to the system bus, as an app does on a console (through its one permission,
 * --system-talk-name=org.ruyaos.Platform1). Off the console, `make test` points the system bus at
 * a private bus with the developer mock on it (DBUS_SYSTEM_BUS_ADDRESS).
 *
 *     platform-demo [--frames N]     N frames of about 16 ms, then save and exit; default: until
 *                                    Stopping or SIGTERM
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <systemd/sd-bus.h>

#define PLATFORM "org.ruyaos.Platform1"
#define PLATFORM_PATH "/org/ruyaos/Platform1"
#define LIFECYCLE "org.ruyaos.Platform1.Lifecycle"

#define MAX_STEP 0.1   /* the longest time step the simulation takes, in seconds */
#define PAUSED_GAP 1.0 /* a gap this long between two frames means we were frozen */
#define FRAME_US 16000

static volatile sig_atomic_t g_terminate;
static int g_stopping; /* a Stopping came: save, then SaveDone */

static void on_term(int sig)
{
    (void)sig;
    g_terminate = 1; /* only set a flag here; the main loop does the work */
}

static double now_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

/* The three signals, sent to this connection alone. */
static int on_lifecycle(sd_bus_message *m, void *userdata, sd_bus_error *ret_error)
{
    const char *member = sd_bus_message_get_member(m);
    (void)userdata;
    (void)ret_error;
    if (!member)
        return 0;
    if (strcmp(member, "Background") == 0) {
        printf("Background: kept running behind Home, lowering work\n");
    } else if (strcmp(member, "Resume") == 0) {
        uint64_t frozen_ms = 0;
        if (sd_bus_message_read(m, "t", &frozen_ms) >= 0)
            printf("Resume: in front again, frozen for %llu ms\n", (unsigned long long)frozen_ms);
    } else if (strcmp(member, "Stopping") == 0) {
        uint32_t deadline_ms = 0;
        if (sd_bus_message_read(m, "u", &deadline_ms) >= 0)
            printf("Stopping: saving, %u ms left\n", (unsigned)deadline_ms);
        g_stopping = 1; /* the main loop saves and answers */
    }
    return 0;
}

/* Registers once, after start. NULL when there are no lifecycle events for us (no bus, no
 * service, or not "ok"): the game runs on without them. */
static sd_bus *lifecycle_register(void)
{
    sd_bus *bus = NULL;
    sd_bus_message *reply = NULL;
    sd_bus_error error = SD_BUS_ERROR_NULL;
    const char *status = NULL;
    int r = sd_bus_open_system(&bus);
    if (r < 0) {
        printf("no system bus (%s): running without lifecycle events\n", strerror(-r));
        return NULL;
    }
    /* The match first, so no signal is missed between Register and it. */
    r = sd_bus_match_signal(bus, NULL, PLATFORM, PLATFORM_PATH, LIFECYCLE, NULL, on_lifecycle, NULL);
    if (r >= 0)
        r = sd_bus_call_method(bus, PLATFORM, PLATFORM_PATH, LIFECYCLE, "Register", &error, &reply, "");
    if (r >= 0)
        r = sd_bus_message_read(reply, "s", &status);
    if (r < 0) {
        if (sd_bus_error_has_name(&error, SD_BUS_ERROR_SERVICE_UNKNOWN))
            printf("no Platform service: running without lifecycle events\n");
        else
            printf("Register failed (%s): running without lifecycle events\n",
                   error.message ? error.message : strerror(-r));
        sd_bus_error_free(&error);
        sd_bus_message_unref(reply);
        sd_bus_flush_close_unref(bus);
        return NULL;
    }
    printf("Register: %s\n", status);
    if (strcmp(status, "ok") != 0) { /* not-allowed: the player turned it off, or not signed in */
        sd_bus_message_unref(reply);
        sd_bus_flush_close_unref(bus);
        return NULL;
    }
    sd_bus_message_unref(reply);
    return bus;
}

/* After the data is on disk: the console's wait ends. */
static void lifecycle_save_done(sd_bus *bus)
{
    sd_bus_message *reply = NULL;
    sd_bus_error error = SD_BUS_ERROR_NULL;
    const char *status = NULL;
    int r = sd_bus_call_method(bus, PLATFORM, PLATFORM_PATH, LIFECYCLE, "SaveDone", &error, &reply, "");
    if (r >= 0 && sd_bus_message_read(reply, "s", &status) >= 0)
        printf("SaveDone: %s\n", status);
    else
        printf("SaveDone failed: %s\n", error.message ? error.message : strerror(-r));
    sd_bus_error_free(&error);
    sd_bus_message_unref(reply);
}

/* Writes the save next to the old one, flushes it, then renames it over (Saves and data). */
static int save_game(unsigned long frames)
{
    const char *base = getenv("XDG_DATA_HOME");
    char path[4096], tmp[4200];
    FILE *f;
    int fd;
    snprintf(path, sizeof path, "%s/platform-demo.save", base && *base ? base : ".");
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    f = fopen(tmp, "w");
    if (!f)
        return -1;
    fprintf(f, "frames=%lu\n", frames);
    if (fflush(f) != 0 || fsync(fileno(f)) != 0) {
        fclose(f);
        return -1;
    }
    if (fclose(f) != 0 || rename(tmp, path) != 0)
        return -1;
    fd = open(base && *base ? base : ".", O_RDONLY | O_DIRECTORY);
    if (fd >= 0) { /* the rename itself is on disk too */
        fsync(fd);
        close(fd);
    }
    printf("saved %s\n", path);
    return 0;
}

int main(int argc, char **argv)
{
    long frames_max = -1;
    unsigned long frame = 0;
    struct sigaction sa;
    sd_bus *bus;
    double last;

    if (argc == 3 && strcmp(argv[1], "--frames") == 0)
        frames_max = atol(argv[2]);
    setvbuf(stdout, NULL, _IOLBF, 0);
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_term;
    sigaction(SIGTERM, &sa, NULL);

    bus = lifecycle_register();
    last = now_s(); /* set just before the loop, so loading is not taken for a pause */
    while (!g_terminate && !g_stopping && (frames_max < 0 || (long)frame < frames_max)) {
        double now = now_s();
        double gap = now - last;
        double dt = gap < MAX_STEP ? gap : MAX_STEP; /* the simulation's step: nothing teleports */
        last = now;
        if (gap > PAUSED_GAP)
            printf("a gap of %.0f ms: we were frozen, pausing the game\n", gap * 1000.0);
        (void)dt;
        frame++;
        if (bus) {
            int r;
            while ((r = sd_bus_process(bus, NULL)) > 0)
                ;
            if (r < 0) {
                printf("lost the bus (%s): running without lifecycle events\n", strerror(-r));
                bus = sd_bus_flush_close_unref(bus);
            }
        }
        if (bus)
            sd_bus_wait(bus, FRAME_US);
        else
            usleep(FRAME_US);
    }

    if (save_game(frame) != 0)
        printf("save failed: %s\n", strerror(errno));
    if (bus && g_stopping)
        lifecycle_save_done(bus);
    sd_bus_flush_close_unref(bus);
    return 0;
}
