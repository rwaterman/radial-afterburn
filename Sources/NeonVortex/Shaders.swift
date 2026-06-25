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
"""
