// tests/btpool_mac.m - the autorelease pool a GCD worker drains (h66, BTAudioHALPlugin's growth on the headset): a serial
// queue's handler autoreleases with no pool of its own, as the plug-in's XPC event handler does. libdispatch pops the
// worker's last-resort pool when the worker goes idle; a queue that never empties keeps every object.
//   xcrun clang -O2 -fobjc-arc tests/btpool_mac.m -framework Foundation -o build/btpool_mac
//   build/btpool_mac 9000 100 8      (keeps up: the queue empties, nothing kept)
//   build/btpool_mac 9000 125 8      (saturated: the worker never idles, the objects stay: ~+3 MB in 8 s)
//   build/btpool_mac 9000 125 8 1    (the same with DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM: freed per item)
// args: messages a second, microseconds of work each, seconds, [1: a pool per work item]
#import <Foundation/Foundation.h>
#include <malloc/malloc.h>
#include <stdatomic.h>
static atomic_long handled;
@interface Box : NSObject @end
@implementation Box
+ (id)make { return [[Box alloc] init]; }
@end
static void spin_us(double us) { double t = CFAbsoluteTimeGetCurrent(); while ((CFAbsoluteTimeGetCurrent() - t) * 1e6 < us) {} }
int main(int argc, char **argv) {
    int rate = atoi(argv[1]); double work_us = atof(argv[2]); int secs = atoi(argv[3]); int freq = argc > 4 ? atoi(argv[4]) : -1;
    dispatch_queue_attr_t a = DISPATCH_QUEUE_SERIAL;
    if (freq == 1) a = dispatch_queue_attr_make_with_autorelease_frequency(a, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
    dispatch_queue_t q = dispatch_queue_create("bt.like", a);
    malloc_statistics_t s0, s1; malloc_zone_statistics(NULL, &s0);
    double t0 = CFAbsoluteTimeGetCurrent(); long sent = 0;
    while (CFAbsoluteTimeGetCurrent() - t0 < secs) {
        double want = (CFAbsoluteTimeGetCurrent() - t0) * rate;
        while (sent < want) { dispatch_async(q, ^{ spin_us(work_us); for (int i = 0; i < 2; i++) { __autoreleasing id b = [Box make]; (void)b; } atomic_fetch_add(&handled, 1); }); sent++; }
        usleep(1000);
    }
    malloc_zone_statistics(NULL, &s1);
    printf("rate %d/s work %.0f us freq %d, %d s: sent %ld handled %ld backlog %ld, malloc in use %+.1f MB\n", rate, work_us, freq, secs, sent, (long)handled, sent - (long)handled, ((double)s1.size_in_use - s0.size_in_use) / 1048576.0);
    return 0;
}
