let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float2 position;
    float4 color;
};

struct RasterData {
    float4 position [[position]];
    float4 color;
};

vertex RasterData vectorVertex(
    uint vertexID [[vertex_id]],
    const device Vertex *vertices [[buffer(0)]]
) {
    RasterData out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.color = vertices[vertexID].color;
    return out;
}

fragment float4 vectorFragment(RasterData in [[stage_in]]) {
    return in.color;
}
"""
