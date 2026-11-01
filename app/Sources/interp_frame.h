// One presented game frame's scene for the Neural Engine's frame prediction (VX Mac, docs/DESIGN.md "method 3"):
// what the host already copies or knows at the present (host.m present_hook), handed to the training capture
// (interp_capture.m) and the model (npu_model.m). Both are optional modules; strength_hooks.m has their stand-ins.
#pragma once
#include <stdint.h>

enum {   // (the capture's record flags; tools/interp_model.py F_*)
    VXI_DEPTH = 1 << 0, VXI_VEL = 1 << 1, VXI_VEL_OK = 1 << 2, VXI_VR = 1 << 3, VXI_STICK = 1 << 4, VXI_HUD_SPLIT = 1 << 5,
    VXI_CAM = 1 << 6, VXI_DEPTH16 = 1 << 7, VXI_ZLIB = 1 << 8,
};

typedef struct {
    void *depth_buf;            // id<MTLBuffer>: the scene's depth copied at its pass's end (xros_vr.m), or NULL
    uint32_t depth_w, depth_h, depth_bpp;   // (bpp 4: Depth32Float values, 2: Depth16Unorm)
    void *vel_tex;              // id<MTLTexture>: the game's velocity target's copy (velocity.m, RG16Float), or NULL
    uint32_t vel_w, vel_h;
    float vel_k[2], vel_corr;   // (vel_check's scale and correlation: target value x k = the picture's shift in frame widths)
    uint32_t flags;             // (VXI_VR, VXI_STICK, VXI_HUD_SPLIT, VXI_VEL_OK; DEPTH / VEL / CAM are set from the fields)
    uint64_t seq;               // (the presenter's number for this present: vx_xros_vr_next_seq)
    double t, t_prev;           // (CACurrentMediaTime of this present and the one before)
    float tan[2], nearp;        // (the frame's tangents (x, y) and the reversed depth's near: distance = near / d)
    float sent[2];              // (the yaw and pitch sent to the game, degrees)
    float cam[16]; uint64_t cam_seq;   // (the game's view matrix as libvxmtl read it, 0 when none)
} vxmac_frame_info;

int vxmac_capture_on(void);
void vxmac_capture_frame(void *cb, void *frame_tex, uint32_t w, uint32_t h, const vxmac_frame_info *fi);
void vxmac_capture_stats(char *out, unsigned size);
int vxmac_interp_on(void);
void vxmac_interp_frame(void *cb, void *frame_tex, uint32_t w, uint32_t h, const vxmac_frame_info *fi);
// The model's output for present seq (planar R16Float texture, W x 6H: fill rgb, motion xy, conf), 0 when none
int vxmac_interp_result(uint64_t seq, void **tex, uint32_t *w, uint32_t *h);
void vxmac_interp_stats(char *out, unsigned size);
// The newest checked result's mean conf (-1 before one): the warp ignores a collapsed conf (VXMAC_INTERP_CONF=auto)
float vxmac_interp_conf_mean(void);
