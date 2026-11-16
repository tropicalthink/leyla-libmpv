/*
 * Plays a file through the built libmpv and reports what the desktop app
 * depends on (build.sh check). No window and no sound device: vo=null and
 * ao=null, at full speed against the audio clock.
 *
 *   check <file> [seek-seconds [option=value...]]
 *
 * Prints the versions, the decoders picked, the audio decoder's output
 * format (a DTS-HD MA track gives floatp when only its lossy core is
 * decoded, s16p or s32p when its lossless layer is), the A/V offset mpv
 * measures after the start and after an absolute seek, and every log line
 * at warning level or worse. Exits non-zero on an error-level line.
 */
#include <mpv/client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static mpv_handle *mpv;
static int errors;

static void check(int status, const char *what)
{
    if (status < 0) {
        fprintf(stderr, "%s: %s\n", what, mpv_error_string(status));
        exit(2);
    }
}

static void show(const char *property)
{
    char *value = mpv_get_property_string(mpv, property);
    printf("  %-28s %s\n", property, value ? value : "(unavailable)");
    mpv_free(value);
}

/* Waits for the playback position to pass `until` seconds, logging. */
static void play_until(double until)
{
    for (int waited = 0;; waited++) {
        if (waited > 600) { /* 60 s */
            fprintf(stderr, "still not at %.1f s after a minute\n", until);
            exit(3);
        }
        mpv_event *event = mpv_wait_event(mpv, 0.1);
        if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *log = event->data;
            printf("  log %-5s [%s] %s", log->level, log->prefix, log->text);
            if (log->log_level <= MPV_LOG_LEVEL_ERROR)
                errors++;
        }
        if (event->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = event->data;
            printf("  end of file: reason %d, error %s\n", end->reason,
                   mpv_error_string(end->error));
            if (end->reason == MPV_END_FILE_REASON_ERROR)
                exit(4);
            return;
        }
        double position = 0;
        if (mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &position) >= 0 &&
            position >= until)
            return;
    }
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <file> [seek-seconds]\n", argv[0]);
        return 2;
    }
    double seek = argc > 2 ? atof(argv[2]) : 600;

    mpv = mpv_create();
    if (!mpv)
        return 2;
    check(mpv_set_option_string(mpv, "vo", "null"), "vo");
    check(mpv_set_option_string(mpv, "ao", "null"), "ao");
    check(mpv_set_option_string(mpv, "sid", "no"), "sid");
    check(mpv_set_option_string(mpv, "hr-seek", "yes"), "hr-seek");
    for (int i = 3; i < argc; i++) {
        char *name = strdup(argv[i]), *value = strchr(name, '=');
        if (!value) {
            fprintf(stderr, "%s: not option=value\n", argv[i]);
            return 2;
        }
        *value++ = '\0';
        check(mpv_set_option_string(mpv, name, value), argv[i]);
        free(name);
    }
    check(mpv_initialize(mpv), "initialize");
    check(mpv_request_log_messages(mpv, "warn"), "log");

    show("mpv-version");
    show("ffmpeg-version");

    /* The codecs lib/playback/libmpv_capabilities.dart may claim, each
     * with the decoders this build has for it. */
    mpv_node list;
    check(mpv_get_property(mpv, "decoder-list", MPV_FORMAT_NODE, &list), "decoder-list");
    const char *wanted[] = {"h264", "hevc", "av1", "vp9", "vp8", "mpeg2video", "mpeg4",
                            "vc1", "aac", "mp3", "opus", "flac", "vorbis", "ac3", "eac3",
                            "dts", "truehd", "alac", "mp2", "pcm_s16le", "pcm_s24le",
                            "pcm_s16be", "pcm_bluray", "pcm_dvd", NULL};
    for (int w = 0; wanted[w]; w++) {
        char drivers[256] = "";
        for (int i = 0; list.format == MPV_FORMAT_NODE_ARRAY && i < list.u.list->num; i++) {
            mpv_node_list *entry = list.u.list->values[i].u.list;
            const char *codec = NULL, *driver = NULL;
            for (int k = 0; k < entry->num; k++) {
                if (!strcmp(entry->keys[k], "codec"))
                    codec = entry->values[k].u.string;
                if (!strcmp(entry->keys[k], "driver"))
                    driver = entry->values[k].u.string;
            }
            if (codec && driver && !strcmp(codec, wanted[w]) &&
                strlen(drivers) + strlen(driver) + 2 < sizeof drivers) {
                if (drivers[0])
                    strcat(drivers, ",");
                strcat(drivers, driver);
            }
        }
        printf("  decoder %-20s %s\n", wanted[w], drivers[0] ? drivers : "NONE");
    }
    mpv_free_node_contents(&list);

    const char *load[] = {"loadfile", argv[1], NULL};
    check(mpv_command(mpv, load), "loadfile");
    play_until(5);
    printf("after the start:\n");
    show("current-vo");
    show("video-codec");
    show("video-params/pixelformat");
    show("audio-codec");
    show("audio-codec-name");
    show("audio-params/format");
    show("audio-params/channel-count");
    show("audio-params/samplerate");
    show("avsync");
    show("total-avsync-change");
    show("frame-drop-count");
    show("decoder-frame-drop-count");

    char target[32];
    snprintf(target, sizeof target, "%.3f", seek);
    const char *seek_command[] = {"seek", target, "absolute", NULL};
    check(mpv_command(mpv, seek_command), "seek");
    play_until(seek + 5);
    printf("5 s after a seek to %s:\n", target);
    show("time-pos");
    show("audio-pts");
    show("avsync");
    show("total-avsync-change");
    show("frame-drop-count");
    show("decoder-frame-drop-count");

    mpv_terminate_destroy(mpv);
    printf("error-level log lines: %d\n", errors);
    return errors ? 1 : 0;
}
