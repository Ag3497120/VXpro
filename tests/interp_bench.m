// The frame-prediction model's latency, memory and compute devices on this Mac's Neural Engine, the way the app runs
// it (app/Sources/npu_model.m): input and output fp16 MLMultiArrays backed by IOSurface pixel buffers
// (OneComponent16Half, W x C*H planar; the output through outputBackings), MLComputeUnitsCPUAndNeuralEngine.
// Optional file. The Mac's Neural Engine is a proxy for the headset's M2 (see docs/DESIGN.md).
//   clang -fobjc-arc -O2 -framework Foundation -framework CoreML -framework CoreVideo tests/interp_bench.m -o build/interp_bench
//   build/interp_bench build/interp/vxinterp_416x240.mlmodelc [iterations] [gap_ms]
//   (gap_ms: a pause between predictions, as at the game's frame rate: the Neural Engine's clock may drop when idle)
#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#import <CoreVideo/CoreVideo.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <unistd.h>

static CVPixelBufferRef pb16(size_t w, size_t h) {
    CVPixelBufferRef p = NULL;
    NSDictionary *a = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES };
    CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_OneComponent16Half, (__bridge CFDictionaryRef)a, &p);
    return p;
}
static double now_ms(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * (double)tb.numer / tb.denom / 1e6; }
static double footprint_mb(void) {
    task_vm_info_data_t v; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&v, &n) == KERN_SUCCESS ? v.phys_footprint / 1048576.0 : -1;
}
static int cmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: interp_bench model.mlmodelc [iterations] [gap_ms]\n"); return 2; }
        int n = argc > 2 ? atoi(argv[2]) : 200; double gap = argc > 3 ? atof(argv[3]) : 0;
        NSURL *url = [NSURL fileURLWithPath:@(argv[1])];
        MLModelConfiguration *cfg = [MLModelConfiguration new];
        cfg.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
        NSError *err = nil;
        double m0 = footprint_mb(), t0 = now_ms();
        MLModel *m = [MLModel modelWithContentsOfURL:url configuration:cfg error:&err];
        if (!m) { fprintf(stderr, "load: %s\n", err.description.UTF8String); return 1; }
        double load = now_ms() - t0;
        NSArray<NSNumber *> *ish = m.modelDescription.inputDescriptionsByName[@"x"].multiArrayConstraint.shape;
        NSArray<NSNumber *> *osh = m.modelDescription.outputDescriptionsByName[@"y"].multiArrayConstraint.shape;
        if (ish.count != 4 || osh.count != 4) { fprintf(stderr, "the model's x / y are not (1, C, H, W)\n"); return 1; }
        size_t C = ish[1].unsignedLongValue, H = ish[2].unsignedLongValue, W = ish[3].unsignedLongValue, OC = osh[1].unsignedLongValue;
        printf("in (1,%zu,%zu,%zu) out (1,%zu,%zu,%zu), load %.0f ms\n", C, H, W, OC, osh[2].unsignedLongValue, osh[3].unsignedLongValue, load);
        CVPixelBufferRef in = pb16(W, C * H), out = pb16(W, OC * H);
        CVPixelBufferLockBaseAddress(in, 0);
        uint16_t *ib = CVPixelBufferGetBaseAddress(in); size_t ibr = CVPixelBufferGetBytesPerRow(in) / 2;
        for (size_t y = 0; y < C * H; y++) for (size_t x = 0; x < W; x++) { __fp16 v = (__fp16)(((x * 7 + y * 13) & 255) / 255.0); ib[y * ibr + x] = *(uint16_t *)&v; }
        CVPixelBufferUnlockBaseAddress(in, 0);
        printf("row bytes: in %zu (W*2 = %zu), out %zu\n", CVPixelBufferGetBytesPerRow(in), W * 2, CVPixelBufferGetBytesPerRow(out));
        MLMultiArray *xa = [[MLMultiArray alloc] initWithPixelBuffer:in shape:@[ @1, @(C), @(H), @(W) ]];
        MLMultiArray *ya = [[MLMultiArray alloc] initWithPixelBuffer:out shape:@[ @1, @(OC), @(H), @(W) ]];
        MLDictionaryFeatureProvider *fp = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{ @"x": [MLFeatureValue featureValueWithMultiArray:xa] } error:&err];
        MLPredictionOptions *po = [MLPredictionOptions new];
        po.outputBackings = @{ @"y": ya };
        double *ms = calloc((size_t)n, sizeof *ms), first = 0;
        for (int i = 0; i <= n; i++) {
            @autoreleasepool {
                double a = now_ms();
                id<MLFeatureProvider> r = [m predictionFromFeatures:fp options:po error:&err];
                double d = now_ms() - a;
                if (!r) { fprintf(stderr, "predict: %s\n", err.description.UTF8String); return 1; }
                if (!i) {
                    first = d;
                    MLMultiArray *got = [r featureValueForName:@"y"].multiArrayValue;
                    printf("output %s the backing (%s)\n", got.pixelBuffer == out ? "in" : "NOT in", got.pixelBuffer == out ? "no copy" : "a copy per frame");
                } else ms[i - 1] = d;
            }
            if (gap > 0) usleep((useconds_t)(gap * 1000));
        }
        qsort(ms, (size_t)n, sizeof *ms, cmp);
        double sum = 0; for (int i = 0; i < n; i++) sum += ms[i];
        printf("first %.2f ms; then mean %.2f, median %.2f, p95 %.2f, worst %.2f ms over %d (gap %.0f ms)\n", first, sum / n, ms[n / 2], ms[n * 95 / 100], ms[n - 1], n, gap);
        printf("footprint: %.0f MB before load, %.0f MB after the runs (+%.0f MB)\n", m0, footprint_mb(), footprint_mb() - m0);
        if (@available(macOS 14.4, *)) {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [MLComputePlan loadContentsOfURL:url configuration:cfg completionHandler:^(MLComputePlan *plan, NSError *e) {
                if (!plan) { printf("plan: %s\n", e.description.UTF8String); dispatch_semaphore_signal(sem); return; }
                MLModelStructureProgramFunction *f = plan.modelStructure.program.functions[@"main"];
                NSMutableDictionary<NSString *, NSNumber *> *by = [NSMutableDictionary dictionary];
                double cost = 0, ane = 0;
                for (MLModelStructureProgramOperation *op in f.block.operations) {
                    MLComputePlanDeviceUsage *u = [plan computeDeviceUsageForMLProgramOperation:op];
                    MLComputePlanCost *c = [plan estimatedCostOfMLProgramOperation:op];
                    NSString *dev = !u ? @"-" : [u.preferredComputeDevice isKindOfClass:[MLNeuralEngineComputeDevice class]] ? @"ANE" :
                                    [u.preferredComputeDevice isKindOfClass:[MLCPUComputeDevice class]] ? @"CPU" : @"GPU";
                    NSString *k = [NSString stringWithFormat:@"%@ %@", dev, op.operatorName];
                    by[k] = @(by[k].intValue + 1);
                    cost += c.weight; if ([dev isEqual:@"ANE"]) ane += c.weight;
                }
                for (NSString *k in [by.allKeys sortedArrayUsingSelector:@selector(compare:)]) printf("  %-28s x%d\n", k.UTF8String, by[k].intValue);
                printf("ANE share of estimated cost %.0f %%\n", cost > 0 ? 100 * ane / cost : 0);
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        }
    }
    return 0;
}
