// pass_profile_mac.metal: the workload of tests/pass_profile_mac.m (a heavy and a light fragment shader, two kernels)
#include <metal_stdlib>
using namespace metal;
struct VO { float4 p [[position]]; float2 uv; };
vertex VO vs_full(uint v [[vertex_id]]) {
    float2 uv = float2((v << 1) & 2, v & 2);
    VO o; o.p = float4(uv * 2 - 1, 0, 1); o.uv = uv; return o;
}
static half4 work(float2 uv, int n) {
    float a = uv.x, b = uv.y;
    for (int i = 0; i < n; i++) { a = fract(sin(a * 12.9898 + b * 78.233 + i) * 43758.5453); b = fract(b * 1.37 + a); }
    return half4(a, b, 0, 1);
}
fragment half4 ps_heavy(VO i [[stage_in]]) { return work(i.uv, 240); }
fragment half4 ps_light(VO i [[stage_in]]) { return work(i.uv, 10); }
kernel void cs_a(texture2d<half> t [[texture(0)]], device uint *o [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {
    half4 c = t.read(g * 2); o[g.y * 1024 + g.x] = as_type<uint>(half2(c.xy));
}
kernel void cs_b(texture2d<half> t [[texture(0)]], device uint *o [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {
    half4 c = t.read(g * 2); o[g.y * 1024 + g.x] ^= as_type<uint>(half2(c.yx));
}
