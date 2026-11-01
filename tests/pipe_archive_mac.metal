// (tests/pipe_archive_mac.m's shaders: one vertex function, 20 fragment variants)
#include <metal_stdlib>
using namespace metal;
struct VO { float4 p [[position]]; float2 uv; };
vertex VO vs(uint i [[vertex_id]]) { VO o; o.uv = float2((i << 1) & 2, i & 2); o.p = float4(o.uv * 2 - 1, 0, 1); return o; }
#define PS(n) fragment float4 ps##n(VO i [[stage_in]]) { float4 c = float4(i.uv, 0.1 * n, 1); for (int k = 0; k < n + 2; k++) c = sin(c * 1.7 + k) * 0.5 + 0.5; return c; }
PS(0) PS(1) PS(2) PS(3) PS(4) PS(5) PS(6) PS(7) PS(8) PS(9) PS(10) PS(11) PS(12) PS(13) PS(14) PS(15) PS(16) PS(17) PS(18) PS(19)
