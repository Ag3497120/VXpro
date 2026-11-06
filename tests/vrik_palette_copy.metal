// SPDX-License-Identifier: MIT
#include <metal_stdlib>
using namespace metal;
struct PoseMatrix { float4 row[3]; };
struct PoseTable { ulong unused[6]; device PoseMatrix *bones; };
struct PoseRoot { ulong unused[6]; device PoseTable *table; };
struct PoseInput { uint4 skin [[attribute(0)]]; };
struct PoseOutput { float4 position [[position]]; float4 color; };
vertex PoseOutput pose_copy_vertex(PoseInput input [[stage_in]], uint vertex_index [[vertex_id]],
                                  const device PoseRoot &root [[buffer(2)]]) {
    const float2 triangle[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
    device PoseMatrix *bones = root.table->bones + input.skin.x / 48;
    PoseOutput output;
    output.position = float4(triangle[vertex_index], 0, 1);
    device PoseMatrix *history = root.table->bones + input.skin.z / 48;
    output.color = float4(bones[0].row[0].w, input.skin.y / 48.f, history[255].row[0].w, 1);
    return output;
}
fragment float4 pose_copy_color(PoseOutput input [[stage_in]]) { return input.color; }
