// tests/audio_hal_mac.m - shims/vxaudio.m on the Mac: do a program image's HAL calls go through the counters (its GOT
// slots), pass through unchanged (VXMAC_AUDIO_HAL unset) or get VX Mac's answers (VXMAC_AUDIO_HAL=0), does the busiest
// thread show in thr_top, and is any HAL plug-in in this process (on macOS they live in coreaudiod)?
//   xcrun clang -O1 -dynamiclib -DVX_PROG tests/audio_hal_mac.m -framework CoreAudio -framework AudioToolbox -o build/audio_prog_mac.dylib
//   xcrun clang -O1 -fobjc-arc -fno-omit-frame-pointer tests/audio_hal_mac.m shims/vxaudio.m shims/vxlog_mac.c -Ishims \
//       -framework Foundation -o build/audio_hal_mac
//   build/audio_hal_mac build/audio_prog_mac.dylib [calls_per_s seconds]      (VXMAC_AUDIO_HAL=0 build/audio_hal_mac ...)
// With calls_per_s / seconds: the same calls at that rate, coreaudiod's resident size before / after (does the Mac's
// HAL - BTAudioHALPlugin among its plug-ins - grow with a program's query rate?).
#ifdef VX_PROG
#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
// (the program: Wwise's macOS sink queries, as Cyberpunk 2077's image makes them)
int prog_query(unsigned *dev, unsigned *ndev, unsigned *ch) {
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, 0 };
    UInt32 sz = 4; AudioObjectID d = 0;
    OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, &d);
    if (st) return (int)st;
    *dev = d;
    a.mSelector = kAudioHardwarePropertyDevices; sz = 0;
    st = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz); if (st) return (int)st;
    *ndev = sz / 4;
    a = (AudioObjectPropertyAddress){ kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput, 0 };
    UInt32 bs = 0; st = AudioObjectGetPropertyDataSize(d, &a, 0, NULL, &bs); if (st) return (int)st;
    AudioBufferList *bl = malloc(bs); st = AudioObjectGetPropertyData(d, &a, 0, NULL, &bs, bl); if (st) { free(bl); return (int)st; }
    *ch = 0; for (UInt32 i = 0; i < bl->mNumberBuffers; i++) *ch += bl->mBuffers[i].mNumberChannels;
    free(bl);
    return 0;
}
int prog_set_runloop(void) {
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyRunLoop, kAudioObjectPropertyScopeGlobal, 0 };
    CFRunLoopRef rl = NULL;
    return (int)AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, sizeof rl, &rl);
}
#else
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
void vxaudio_stats(char *out, unsigned size, int slot);
void vxaudio_hook_image(const void *mh);
static volatile int g_stop;
static void *spin(void *p) { pthread_setname_np("vx-spin"); volatile double x = 0; while (!g_stop) x += 1; return p; }
static long coreaudiod_rss_kb(void) {
    FILE *f = popen("ps -axo rss=,comm= | grep coreaudiod$ | head -1", "r"); long kb = -1;
    if (f) { if (fscanf(f, "%ld", &kb) != 1) kb = -1; pclose(f); }
    return kb;
}
static int plugins_here(void) {
    int n = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) { const char *p = _dyld_get_image_name(i); if (p && strstr(p, "/Audio/Plug-Ins/")) { printf("  in this process: %s\n", p); n++; } }
    return n;
}
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s audio_prog_mac.dylib [calls_per_s seconds]\n", argv[0]); return 2; }
    const char *h = getenv("VXMAC_AUDIO_HAL"); int synth = h && !strcmp(h, "0");
    pthread_t sp; pthread_create(&sp, NULL, spin, NULL);
    char s[3000]; vxaudio_stats(s, sizeof s, 0);   // (the first sample: the threads' baseline)
    void *prog = dlopen(argv[1], RTLD_NOW); if (!prog) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
    int (*q)(unsigned *, unsigned *, unsigned *) = dlsym(prog, "prog_query"); int (*rl)(void) = dlsym(prog, "prog_set_runloop");
    unsigned dev = 0, ndev = 0, ch = 0;
    int st = q(&dev, &ndev, &ch), st2 = rl();
    printf("prog_query -> %d: default output %u, %u device(s), %u output channel(s); run loop set -> %d\n", st, dev, ndev, ch, st2);
    for (int i = 0; i < 999; i++) q(&dev, &ndev, &ch);
    usleep(500000);
    vxaudio_stats(s, sizeof s, 0); printf("%s\n", s);
    int pass = st == 0 && st2 == 0 && strstr(s, "\"get\":2000,") && strstr(s, "\"size\":2000,") && strstr(s, "\"set\":1,") && strstr(s, "vx-spin");
    if (synth) pass = pass && dev == 0x7678 && ndev == 1 && ch >= 1 && strstr(s, "\"answered\":4001,");
    else pass = pass && dev != 0x7678 && strstr(s, "\"answered\":0,");
    int np = plugins_here();
    printf("HAL plug-ins in this process: %d (macOS: they are coreaudiod's)\n", np);
    if (argc >= 4) {   // (the rate test against the Mac's HAL)
        int rate = atoi(argv[2]), secs = atoi(argv[3]);
        long kb0 = coreaudiod_rss_kb(); double t0 = CFAbsoluteTimeGetCurrent(); long n = 0;
        while (CFAbsoluteTimeGetCurrent() - t0 < secs) {
            double want = (CFAbsoluteTimeGetCurrent() - t0) * rate / 5;   // (prog_query: 5 HAL calls)
            while (n < want) { q(&dev, &ndev, &ch); n++; }
            usleep(2000);
        }
        long kb1 = coreaudiod_rss_kb();
        printf("rate test: %ld HAL calls in %d s (%.0f a second); coreaudiod resident %ld -> %ld KB (%+ld)\n", n * 5, secs, n * 5.0 / secs, kb0, kb1, kb1 - kb0);
    }
    g_stop = 1; pthread_join(sp, NULL);
    printf("%s\n", pass ? "PASS: the program's HAL calls counted through its GOT, answers as expected, the busy thread named" : "FAIL");
    return pass ? 0 : 1;
}
#endif
