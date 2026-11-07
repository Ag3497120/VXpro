// SPDX-License-Identifier: MIT
#include <metal_stdlib>
using namespace metal;
struct TestVertex { float4 position; float4 color; float2 uv; };
struct TestVarying { float4 position [[position]]; float4 color; float2 uv; };
vertex TestVarying test_vertex(uint id [[vertex_id]], constant TestVertex *v [[buffer(0)]],
                              constant float4x4 &mvp [[buffer(1)]]) {
    return {mvp * v[id].position, v[id].color, v[id].uv};
}
fragment float4 test_fragment(TestVarying in [[stage_in]], texture2d<float> label [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return in.uv.x < 0 ? in.color : label.sample(s, in.uv) * in.color;
}
