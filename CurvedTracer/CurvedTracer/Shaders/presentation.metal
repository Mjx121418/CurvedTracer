#include <metal_stdlib>

using namespace metal;

struct PresentationVertex {
    float4 position [[position]];
    float2 textureCoordinate;
};

vertex PresentationVertex presentVertex(uint vertexId [[vertex_id]]) {
    constexpr float2 positions[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1),  float2(1, -1), float2(1, 1),
    };
    constexpr float2 textureCoordinates[6] = {
        float2(0, 1), float2(1, 1), float2(0, 0),
        float2(0, 0), float2(1, 1), float2(1, 0),
    };

    PresentationVertex output;
    output.position = float4(positions[vertexId], 0, 1);
    output.textureCoordinate = textureCoordinates[vertexId];
    return output;
}

fragment float4 presentFragment(PresentationVertex input [[stage_in]],
                                texture2d<float> source [[texture(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge,
                                    filter::linear);
    return source.sample(linearSampler, input.textureCoordinate);
}
