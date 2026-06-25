let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProjection;
    float time;
    float fogStart;
    float fogEnd;
    float pad;
};

struct LineVertex {
    float3 position;
    float4 color;
};

struct LineRaster {
    float4 position [[position]];
    float4 color;
};

static float fogFactor(float viewZ, float fogStart, float fogEnd) {
    // viewZ is negative going into the screen; use distance = -viewZ.
    float d = -viewZ;
    return clamp((d - fogStart) / max(fogEnd - fogStart, 0.0001), 0.0, 1.0);
}

vertex LineRaster neonLineVertex(
    uint vertexID [[vertex_id]],
    const device LineVertex *vertices [[buffer(0)]],
    constant Uniforms &u [[buffer(1)]]
) {
    LineRaster out;
    float4 world = float4(vertices[vertexID].position, 1.0);
    out.position = u.viewProjection * world;
    float fog = fogFactor(world.z, u.fogStart, u.fogEnd);
    out.color = vertices[vertexID].color * float4(1.0, 1.0, 1.0, 1.0 - fog);
    return out;
}

fragment float4 neonLineFragment(LineRaster in [[stage_in]]) {
    return in.color;
}

struct TexVertex {
    float3 position;
    float2 uv;
    float4 color;
};

struct TexRaster {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float viewZ;
};

vertex TexRaster texturedVertex(
    uint vertexID [[vertex_id]],
    const device TexVertex *vertices [[buffer(0)]],
    constant Uniforms &u [[buffer(1)]]
) {
    TexRaster out;
    float4 world = float4(vertices[vertexID].position, 1.0);
    out.position = u.viewProjection * world;
    out.uv = vertices[vertexID].uv;
    out.color = vertices[vertexID].color;
    out.viewZ = world.z;
    return out;
}

fragment float4 texturedFragment(
    TexRaster in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant Uniforms &u [[buffer(1)]]
) {
    constexpr sampler s(address::repeat, filter::linear, mip_filter::linear);
    float4 sampled = tex.sample(s, in.uv);
    float4 lit = sampled * in.color;
    float fog = fogFactor(in.viewZ, u.fogStart, u.fogEnd);
    lit.rgb *= (1.0 - fog);
    lit.a *= (1.0 - fog);
    return lit;
}

struct FSOut { float4 position [[position]]; float2 uv; };

vertex FSOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 pos[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    float2 uv[3]  = { float2(0, 1),  float2(2, 1),  float2(0, -1) };
    FSOut o;
    o.position = float4(pos[vid], 0, 1);
    o.uv = uv[vid];
    return o;
}

fragment float4 brightPassFragment(FSOut in [[stage_in]], texture2d<float> scene [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float4 c = scene.sample(s, in.uv);
    float luma = dot(c.rgb, float3(0.299, 0.587, 0.114));
    float t = 0.9;
    return luma > t ? c : float4(0, 0, 0, 1);
}

struct BlurParams { float2 direction; };

fragment float4 blurFragment(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant BlurParams &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear);
    float2 texSize = float2(src.get_width(), src.get_height());
    float2 off = p.direction / texSize;
    float w[5] = { 0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216 };
    float3 sum = src.sample(s, in.uv).rgb * w[0];
    for (int i = 1; i < 5; i++) {
        sum += src.sample(s, in.uv + off * float(i)).rgb * w[i];
        sum += src.sample(s, in.uv - off * float(i)).rgb * w[i];
    }
    return float4(sum, 1);
}

fragment float4 compositeFragment(FSOut in [[stage_in]], texture2d<float> scene [[texture(0)]], texture2d<float> bloom [[texture(1)]]) {
    constexpr sampler s(filter::linear);
    float3 c = scene.sample(s, in.uv).rgb + bloom.sample(s, in.uv).rgb * 1.2;
    c = c / (c + 1.0); // Reinhard tonemap
    return float4(c, 1);
}
"""
