// SPDX-License-Identifier: MIT
// Synthetic GPU work plus a matched implementation of fsr_model.py's fixed
// filter. Not game code, a neural quality model, or a game FPS benchmark.
#include <metal_stdlib>
using namespace metal;

struct Job { uint frame, work, pattern, reserved; };

kernel void offload_scene(texture2d<half, access::write> image [[texture(0)]],
                          constant Job &job [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= image.get_width() || p.y >= image.get_height()) return;
    float2 uv=(float2(p)+.5f)/float2(image.get_width(),image.get_height());
    float3 c;
    if (job.pattern==1) c=float3(uv, .5f+.5f*sin(uv.x*24));
    else if (job.pattern==2) c=float3(((p.x/7+p.y/5)&1), ((p.x/13)&1), ((p.y/11)&1));
    else {
        float t=job.frame*.007f;
        float3 q=float3(uv*3,t+.1f);
        for (uint i=0;i<job.work;++i) {
            q=sin(q.yzx*1.13f+q*.73f+float(i)*.011f);
        }
        c=.5f+.24f*q+.15f*sin(float3(uv.x*31+t,uv.y*23-t,(uv.x+uv.y)*17));
    }
    if(p.x<128 && p.y<128) c=float3(float((job.frame*7)&255)/255.f);
    image.write(half4(half3(clamp(c,0.f,1.f)),1),p);
}

kernel void offload_input(texture2d<half, access::sample> scene [[texture(0)]],
                          texture2d<half, access::write> image [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x>=image.get_width() || p.y>=image.get_height()) return;
    constexpr sampler s(coord::normalized,filter::linear,address::clamp_to_edge);
    image.write(scene.sample(s,(float2(p)+.5f)/float2(image.get_width(),image.get_height())),p);
}

kernel void offload_cubic(texture2d<half, access::read> source [[texture(0)]],
                          texture2d<half, access::write> up [[texture(1)]],
                          constant float *weights [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x>=up.get_width() || p.y>=up.get_height()) return;
    int2 base=int2(p/2);
    uint phase=(p.y&1)*2+(p.x&1);
    float3 sum=0;
    for (int y=-2;y<=2;++y) for(int x=-2;x<=2;++x) {
        int2 q=base+int2(x,y);
        if (q.x>=0 && q.y>=0 && q.x<int(source.get_width()) && q.y<int(source.get_height()))
            sum+=float3(source.read(uint2(q)).rgb)*255.f*weights[phase*25+(y+2)*5+x+2];
    }
    up.write(half4(half3(sum),1),p);
}

kernel void offload_finish(texture2d<half, access::read> up [[texture(0)]],
                           texture2d<half, access::write> output [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x>=output.get_width() || p.y>=output.get_height()) return;
    float3 blur=0;
    half3 lo=half3(INFINITY),hi=half3(-INFINITY);
    for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) {
        int2 q=int2(p)+int2(x,y);
        if(q.x>=0 && q.y>=0 && q.x<int(up.get_width()) && q.y<int(up.get_height())) {
            half3 c=up.read(uint2(q)).rgb;
            blur+=float3(c)*float((x==0?2:1)*(y==0?2:1))/16.f;
            lo=min(lo,c);hi=max(hi,c);
        }
    }
    half3 value=up.read(p).rgb;
    half3 difference=value-half3(blur);
    half3 sharpened=value+half(.8f)*difference;
    output.write(half4(clamp(clamp(sharpened,lo,hi),half3(0),half3(255))/half(255),1),p);
}

kernel void offload_compose(texture2d<half, access::read> source [[texture(0)]],
                            texture2d<half, access::write> output [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
    if(p.x<output.get_width() && p.y<output.get_height()) output.write(source.read(p),p);
}

kernel void offload_validate(texture2d<half, access::read> image [[texture(0)]],
                             device uint *result [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    if(i==0) result[0]=uint(round(float(image.read(uint2(32,32)).r)*255.f));
}
