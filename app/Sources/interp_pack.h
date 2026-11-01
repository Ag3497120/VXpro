// The pack kernels of method 3 (VX Mac, optional file), shared by the training capture (interp_capture.m:
// raw planes) and the model (npu_model.m: its encoded input), so both sample the frame, the depth and the velocity the
// same way; tools/interp_model.py encode_input is the Python side of nn_pack (checked by tests/interp_capture_mac.m).
#pragma once
#include <stdint.h>

// The pack kernels (shared: the capture's raw planes and the model's encoded input are sampled the same way)
#define VXI_PACK_MSL \
    "#include <metal_stdlib>\nusing namespace metal;\n" \
    "struct P { uint ow, oh, dw, dh, dbpp, has_d, has_v; float kx, ky; };\n" \
    "static float3 col(texture2d<float> f, float2 uv, float2 o) {\n" \
    "  constexpr sampler s(filter::linear, address::clamp_to_edge);\n" \
    "  return 0.25f * (f.sample(s, uv + float2(-o.x, -o.y), level(0)).rgb + f.sample(s, uv + float2(o.x, -o.y), level(0)).rgb +\n" \
    "                  f.sample(s, uv + float2(-o.x, o.y), level(0)).rgb + f.sample(s, uv + float2(o.x, o.y), level(0)).rgb); }\n" \
    "static float dep(device const uchar *db, constant P &p, float2 uv) {\n" \
    "  if (!p.has_d) return 0; uint2 i = min(uint2(uv * float2(p.dw, p.dh)), uint2(p.dw - 1, p.dh - 1)); uint k = i.y * p.dw + i.x;\n" \
    "  return p.dbpp == 2 ? float(((device const ushort *)db)[k]) / 65535.0f : ((device const float *)db)[k]; }\n" \
    "static float2 vel(texture2d<float> v, constant P &p, float2 uv) {\n" \
    "  if (!p.has_v) return 0; uint2 n = uint2(v.get_width(), v.get_height()); float2 m = v.read(min(uint2(uv * float2(n)), n - 1)).xy;\n" \
    "  return all(isfinite(m)) ? m : float2(0); }\n" \
    "kernel void cap_pack(texture2d<float> f [[texture(0)]], texture2d<float> v [[texture(1)]], device const uchar *db [[buffer(0)]],\n" \
    "                     constant P &p [[buffer(1)]], device half *o [[buffer(2)]], uint2 g [[thread_position_in_grid]]) {\n" \
    "  if (g.x >= p.ow || g.y >= p.oh) return; float2 uv = (float2(g) + 0.5f) / float2(p.ow, p.oh);\n" \
    "  float3 c = col(f, uv, 0.25f / float2(p.ow, p.oh)); float d = dep(db, p, uv); float2 m = vel(v, p, uv);\n" \
    "  uint n = p.ow * p.oh, k = g.y * p.ow + g.x;\n" \
    "  o[k] = half(c.r); o[n + k] = half(c.g); o[2 * n + k] = half(c.b); o[3 * n + k] = half(d); o[4 * n + k] = half(m.x); o[5 * n + k] = half(m.y); }\n" \
    "kernel void nn_pack(texture2d<float> f [[texture(0)]], texture2d<float> v [[texture(1)]], device const uchar *db [[buffer(0)]],\n" \
    "                    constant P &p [[buffer(1)]], texture2d<half, access::write> o [[texture(2)]], uint2 g [[thread_position_in_grid]]) {\n" \
    "  if (g.x >= p.ow || g.y >= p.oh) return; float2 uv = (float2(g) + 0.5f) / float2(p.ow, p.oh);\n" \
    "  float3 c = saturate(col(f, uv, 0.25f / float2(p.ow, p.oh))); float d = dep(db, p, uv); float2 m = vel(v, p, uv);\n" \
    "  float de = p.has_d ? saturate(log2(1.0f / max(d, 1e-6f)) / 12.0f) : 1.0f;\n" \
    "  float2 mo = m * float2(p.kx, p.ky) * float2(p.ow, p.oh) / 16.0f;\n" \
    "  uint h = p.oh; o.write(half(c.r), uint2(g.x, g.y)); o.write(half(c.g), uint2(g.x, g.y + h)); o.write(half(c.b), uint2(g.x, g.y + 2 * h));\n" \
    "  o.write(half(de), uint2(g.x, g.y + 3 * h)); o.write(half(mo.x), uint2(g.x, g.y + 4 * h)); o.write(half(mo.y), uint2(g.x, g.y + 5 * h)); }\n"
typedef struct { uint32_t ow, oh, dw, dh, dbpp, has_d, has_v; float kx, ky; } vxi_pack_params;
