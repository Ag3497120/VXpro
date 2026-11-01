// tests/pipe_archive_mac.m - libvxmtl's pipeline archives (VXMAC_PIPE_ARCHIVE=1, shims/vxpipe.m h64) and the h64 creation
// counters, on the Mac. The game's way: each pipeline from a library made from bytes (newLibraryWithData:), freed after.
//   xcrun -sdk macosx metal -c tests/pipe_archive_mac.metal -o build/pa.air && xcrun -sdk macosx metallib build/pa.air -o build/pa.metallib
//   xcrun clang -fobjc-arc -O1 tests/pipe_archive_mac.m -framework Metal -framework QuartzCore -framework Foundation -o build/pipe_archive_mac
//   rm -rf ~/Library/Caches/vxmac_pipes
//   VXMAC_MAC_TEST=1 VXMAC_PIPE_ARCHIVE=1 DYLD_INSERT_LIBRARIES=build/macshim/libvxmtl.dylib build/pipe_archive_mac build/pa.metallib 1
//   VXMAC_MAC_TEST=1 VXMAC_PIPE_ARCHIVE=1 DYLD_INSERT_LIBRARIES=build/macshim/libvxmtl.dylib build/pipe_archive_mac build/pa.metallib 2
// Run 1 makes 240 pipelines twice (the second pass: repeats), then writes the archive (the app's background path).
// Run 2 makes them with MTLPipelineOptionFailOnBinaryArchiveMiss: each one made is proof it came from our archive.
// Run 3 (VXMAC_PIPE_ARCHIVE unset): an empty archive in each descriptor with the same option: all must fail (the control:
// with no archive at all the option checks nothing); with VXMAC_PIPE_ARCHIVE=1 the same calls all succeed: ours served them.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
static const MTLPixelFormat kFmt[] = { MTLPixelFormatRGBA8Unorm, MTLPixelFormatBGRA8Unorm, MTLPixelFormatRGBA16Float, MTLPixelFormatRG11B10Float,
                                       MTLPixelFormatRGB10A2Unorm, MTLPixelFormatR32Float };
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) return 2;
    int run = atoi(argv[2]);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSData *bytes = [NSData dataWithContentsOfFile:@(argv[1])];
    void (*mem)(char *, unsigned) = dlsym(RTLD_DEFAULT, "vxpipe_mem_stats");
    void (*fg)(int) = dlsym(RTLD_DEFAULT, "vxmtl_set_foreground");
    int made = 0, failed = 0; double tsum[2] = { 0, 0 };
    for (int pass = 0; pass < (run == 1 ? 2 : 1); pass++) {
        double t0 = CACurrentMediaTime();
        for (int f = 0; f < 20; f++) for (int c = 0; c < 6; c++) for (int b = 0; b < 2; b++) @autoreleasepool {
            dispatch_data_t dd = dispatch_data_create(bytes.bytes, bytes.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            NSError *e = nil;
            id<MTLLibrary> lib = [dev newLibraryWithData:dd error:&e];
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = [lib newFunctionWithName:@"vs"];
            d.fragmentFunction = [lib newFunctionWithName:[NSString stringWithFormat:@"ps%d", f]];
            d.colorAttachments[0].pixelFormat = kFmt[c];
            d.colorAttachments[0].blendingEnabled = b;
            d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha; d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            if (run == 3) { static id<MTLBinaryArchive> empty; if (!empty) empty = [dev newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:&e]; d.binaryArchives = @[ empty ]; }
            MTLAutoreleasedRenderPipelineReflection r = nil;
            id p = [dev newRenderPipelineStateWithDescriptor:d options:run >= 2 ? MTLPipelineOptionFailOnBinaryArchiveMiss : MTLPipelineOptionNone reflection:&r error:&e];
            if (p) made++; else failed++;
        }
        tsum[pass] = CACurrentMediaTime() - t0;
    }
    char s[1400] = ""; if (mem) mem(s, sizeof s);
    printf("run %d: made %d, failed %d; pass 1 %.0f ms, pass 2 %.0f ms\n%s\n", run, made, failed, tsum[0] * 1e3, tsum[1] * 1e3, s);
    if (run == 1 && fg) {   // (the archive written as when the app goes to the background)
        fg(0);
        NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"vxmac_pipes"];
        for (int i = 0; i < 600; i++) {
            NSArray *sub = [NSFileManager.defaultManager subpathsAtPath:dir];
            if ([[sub filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF ENDSWITH 'a0.bin'"]] count]) { printf("archive written: %s\n", [[sub componentsJoinedByString:@" "] UTF8String]); break; }
            usleep(100000);
        }
        fg(1);
    }
    if (run == 3 && !getenv("VXMAC_PIPE_ARCHIVE")) printf("%s: %d of 240 failed with an empty archive and FailOnBinaryArchiveMiss (the option does check)\n", failed == 240 ? "PASS" : "FAIL", failed);
    if (run == 3 && getenv("VXMAC_PIPE_ARCHIVE")) printf("%s: %d of 240 made with an empty archive of the game's and FailOnBinaryArchiveMiss: found in ours\n", made == 240 ? "PASS" : "FAIL", made);
    if (run == 2) printf("%s: %d of 240 pipelines made with FailOnBinaryArchiveMiss (from our archive)\n", made == 240 ? "PASS" : "FAIL", made);
    return 0;
} }
