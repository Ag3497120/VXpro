// The foveated SR model's latency and compute devices on this Mac's Neural Engine, the way the app runs it
// (app/Sources/fsr.m): IOSurface BGRA pixel buffers in and out (outputBackings), MLComputeUnitsCPUAndNeuralEngine.
//   clang -fobjc-arc -framework Foundation -framework CoreML -framework CoreVideo -framework ImageIO -framework CoreGraphics \
//         tests/fsr_bench.m -o build/fsr_bench
//   build/fsr_bench build/fsr/vxfsr_512x288.mlmodelc [frame.png [out.png]]   (a frame: its centre crop is the input)
#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <mach/mach_time.h>

static CVPixelBufferRef pb(size_t w, size_t h) {
    CVPixelBufferRef p = NULL;
    NSDictionary *a = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES };
    CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)a, &p);
    return p;
}
static double now_ms(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * (double)tb.numer / tb.denom / 1e6; }

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: fsr_bench model.mlmodelc [frame.png [out.png]]\n"); return 2; }
        NSURL *url = [NSURL fileURLWithPath:@(argv[1])];
        MLModelConfiguration *cfg = [MLModelConfiguration new];
        cfg.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
        NSError *err = nil;
        double t0 = now_ms();
        MLModel *m = [MLModel modelWithContentsOfURL:url configuration:cfg error:&err];
        if (!m) { fprintf(stderr, "load: %s\n", err.description.UTF8String); return 1; }
        printf("load %.1f ms\n", now_ms() - t0);
        MLImageConstraint *ic = m.modelDescription.inputDescriptionsByName[@"image"].imageConstraint;
        MLImageConstraint *oc = m.modelDescription.outputDescriptionsByName[@"detail"].imageConstraint;
        size_t W = ic.pixelsWide, H = ic.pixelsHigh, OW = oc.pixelsWide, OH = oc.pixelsHigh;
        printf("in %zux%zu out %zux%zu\n", W, H, OW, OH);
        CVPixelBufferRef in = pb(W, H), out = pb(OW, OH);
        CVPixelBufferLockBaseAddress(in, 0);
        uint8_t *ib = CVPixelBufferGetBaseAddress(in); size_t ibr = CVPixelBufferGetBytesPerRow(in);
        if (argc > 2) {   // (the frame's centre crop, drawn into the input)
            CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[2])], NULL);
            CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
            if (!img) { fprintf(stderr, "no image\n"); return 1; }
            size_t fw = CGImageGetWidth(img), fh = CGImageGetHeight(img);
            CGContextRef c = CGBitmapContextCreate(ib, W, H, 8, ibr, CGColorSpaceCreateDeviceRGB(), kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            // (frame pixels 1:1 when the frame is 1280 wide: the crop is W x H of its centre, scaled to the frame's size otherwise)
            double s = 1280.0 / fw;
            CGContextDrawImage(c, CGRectMake(-(fw * s - W) / 2, -(fh * s - H) / 2, fw * s, fh * s), img);
            CGContextRelease(c);
        } else for (size_t y = 0; y < H; y++) for (size_t x = 0; x < W * 4; x++) ib[y * ibr + x] = (uint8_t)((x * 7 + y * 13) & 255);
        CVPixelBufferUnlockBaseAddress(in, 0);
        MLFeatureValue *fv = [MLFeatureValue featureValueWithPixelBuffer:in];
        MLDictionaryFeatureProvider *fp = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{ @"image": fv } error:&err];
        MLPredictionOptions *po = [MLPredictionOptions new];
        po.outputBackings = @{ @"detail": (__bridge id)out };
        double first = 0, sum = 0, mx = 0; int n = 100;
        for (int i = 0; i <= n; i++) {
            double a = now_ms();
            id<MLFeatureProvider> r = [m predictionFromFeatures:fp options:po error:&err];
            double d = now_ms() - a;
            if (!r) { fprintf(stderr, "predict: %s\n", err.description.UTF8String); return 1; }
            if (!i) first = d; else { sum += d; if (d > mx) mx = d; }
        }
        printf("first %.2f ms, then mean %.2f ms, worst %.2f ms over %d\n", first, sum / n, mx, n);
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
        if (argc > 3) {
            CVPixelBufferLockBaseAddress(out, 0);
            CGContextRef c = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(out), OW, OH, 8, CVPixelBufferGetBytesPerRow(out), CGColorSpaceCreateDeviceRGB(),
                                                   kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
            CGImageRef img = CGBitmapContextCreateImage(c);
            CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[3])], CFSTR("public.png"), 1, NULL);
            CGImageDestinationAddImage(d, img, NULL); CGImageDestinationFinalize(d);
            CVPixelBufferUnlockBaseAddress(out, 0);
            printf("wrote %s\n", argv[3]);
        }
    }
    return 0;
}
