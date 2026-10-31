// VX Mac's stand-in for VXRuntime's npu_interp.h, the two calls the immersive presenter (xros_vr.m, copied from
// avp-port) makes to get a frame's scene: here the MetalFX temporal scaler's inputs (libvxmtlfx, vxmac_vr_glue.m)
// instead of the D3D12 layer's FSR2 capture.
//   npu_interp_take_scene: 1 when a new frame's motion vectors and depth were taken (retained: the caller transfers
//   them), 0 otherwise; consts stays empty (2 would mean FSR2's constants: MetalFX gives no projection).
//   npu_fsr2_parse: 0 (no FSR2 constants with MetalFX).
#pragma once
#include <stdint.h>
int npu_interp_take_scene(void **mv, void **depth, uint32_t consts[32]);
int npu_fsr2_parse(const uint32_t *consts, float *tan_half_fov_y, float d2v[4], float mvs[2], uint32_t disp[2]);
