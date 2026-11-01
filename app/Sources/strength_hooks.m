// Optional modules (VX Mac): weak stand-ins for the Neural Engine modules below. Each is a weak definition: the
// module's file is in the default build and its strong definitions win at link time; a build without it
// (EXCLUDED_SOURCE_FILE_NAMES="npu_flow.m fsr.m") runs these and the feature is simply off.
//   app/Sources/npu_flow.m  the Neural Engine / Vision optical flow (frame prediction from the picture)
//   app/Sources/fsr.m       the Neural Engine foveated super-resolution (with tools/fsr_model.py, tests/fsr_bench.m)
//   app/Sources/interp_capture.m, npu_model.m   method 3: the frame-prediction model's training capture and the model
//                           on the Neural Engine (with tools/interp_model.py, tests/interp_bench.m, interp_capture_mac.m,
//                           interp_warp_mac.m); the warp's use of its layers (warp_core.m vxw_set_interp) is public
// (The game's own velocity buffer, velocity.m, and the warp have no stand-ins: they are always built.)
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include "interp_frame.h"

#define WEAK __attribute__((weak))
WEAK int vxmac_npu_on(void) { return 0; }
WEAK void vxmac_npu_frame(void *cb, void *tex, uint32_t w, uint32_t h) { (void)cb; (void)tex; (void)w; (void)h; }
WEAK void vxmac_npu_stats(char *out, unsigned size) { snprintf(out, size, "\"npu\":0"); }
WEAK int vxmac_npu_take(void **mv, uint32_t *w, uint32_t *h) { (void)mv; (void)w; (void)h; return 0; }
WEAK float vxmac_npu_sign(void) { return 0; }
WEAK int vxmac_fsr_on(void) { return 0; }
WEAK void vxmac_fsr_frame(void *cb, void *tex, uint32_t w, uint32_t h, uint64_t seq) { (void)cb; (void)tex; (void)w; (void)h; (void)seq; }
WEAK int vxmac_fsr_detail(uint64_t seq, void **tex, float rect[4]) { (void)seq; (void)tex; (void)rect; return 0; }
WEAK void vxmac_fsr_stats(char *out, unsigned size) { snprintf(out, size, "\"fsr\":0"); }
WEAK uint64_t vxmac_fsr_result_seq(void) { return 0; }
WEAK int vxmac_capture_on(void) { return 0; }
WEAK void vxmac_capture_frame(void *cb, void *tex, uint32_t w, uint32_t h, const vxmac_frame_info *fi) { (void)cb; (void)tex; (void)w; (void)h; (void)fi; }
WEAK void vxmac_capture_stats(char *out, unsigned size) { snprintf(out, size, "\"cap\":0"); }
WEAK int vxmac_interp_on(void) { return 0; }
WEAK void vxmac_interp_frame(void *cb, void *tex, uint32_t w, uint32_t h, const vxmac_frame_info *fi) { (void)cb; (void)tex; (void)w; (void)h; (void)fi; }
WEAK int vxmac_interp_result(uint64_t seq, void **tex, uint32_t *w, uint32_t *h) { (void)seq; (void)tex; (void)w; (void)h; return 0; }
WEAK void vxmac_interp_stats(char *out, unsigned size) { snprintf(out, size, "\"interp\":0"); }
WEAK float vxmac_interp_conf_mean(void) { return -1; }
