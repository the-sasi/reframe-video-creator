#include <metal_stdlib>
using namespace metal;

// Reframe's entire shading model.
//
// Every layer — image, video frame, text, logo — is a textured quad with a transform, so there
// is one vertex function and one content fragment function. Transitions are a mix of two
// fully-composited sub-scenes, so there is one more fragment function for those. That
// uniformity is why adding an effect is a case rather than a subsystem.
//
// This file lives in the app target, not the package, so Xcode compiles and validates it at
// build time. See docs/07-roadmap.md, first-build checklist item 5.

// MARK: - Types

struct LayerUniforms {
    // Destination rect on the canvas, normalised 0...1, origin top-left.
    float4 destination;
    // Region of the source texture to sample, normalised.
    float4 sourceCrop;
    // exposure, contrast, saturation, temperature
    float4 grade;
    // vignette, grain, time, canvas aspect (width/height)
    float4 effects;
    // Upright-UV -> texture-UV, as (a, b, c, d). Identity for photos and text; a rotation for
    // video decoded in its natural orientation. Translation is `sourceOffset`.
    float4 sourceTransform;
    // Canvas-space point the rotation is about. The destination centre for a clip; the text
    // block's centre for a word, so a rotated caption turns as one piece.
    float2 pivot;
    float2 sourceOffset;
    float  opacity;
    float  rotation;
    float  scale;
    float  _pad0;
};

struct TransitionUniforms {
    float progress;   // 0...1
    int   kind;       // TransitionShaderKind, mirrored in TransitionLibrary.swift
    int   direction;  // 0 left, 1 right, 2 up, 3 down
    float _pad;
};

struct VertexOut {
    float4 position [[position]];
    // Texture sampling coordinates, after the source transform.
    float2 uv;
    // 0...1 across the quad — where in the *frame* this fragment is, for vignette and grain.
    float2 frameUV;
};

// MARK: - Colour

// Grading in linear-ish space. Four scalars, matching what ColorAnalyzer can honestly infer —
// no LUT textures, because there is no honest way to derive one from a reference.
static inline float3 applyGrade(float3 color, float4 grade) {
    // Exposure, as stops.
    color *= pow(2.0, grade.x);
    // Contrast about mid-grey.
    color = (color - 0.5) * grade.y + 0.5;
    // Saturation toward Rec. 709 luma.
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(float3(luma), color, grade.z);
    // Temperature: push red up and blue down together, so the shift reads as warmth rather
    // than a red cast.
    color.r += grade.w * 0.06;
    color.b -= grade.w * 0.06;
    return clamp(color, 0.0, 1.0);
}

// Cheap hash noise. Fed the frame time so grain moves between frames — a static pattern reads
// as a dirty lens rather than as film.
static inline float hashNoise(float2 uv, float time) {
    float3 p = float3(uv, time);
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

// effects = (vignette, grain, time, unused)
static inline float3 applyEffects(float3 color, float2 uv, float4 effects) {
    if (effects.x > 0.001) {
        // Distance from centre, aspect-agnostic. smoothstep keeps the falloff soft enough
        // that it reads as lighting rather than as a drawn oval.
        float2 offset = uv - 0.5;
        float d = length(offset) * 1.4142;
        float darkening = smoothstep(0.35, 1.0, d) * effects.x;
        color *= (1.0 - darkening);
    }

    if (effects.y > 0.001) {
        float n = hashNoise(uv * 512.0, effects.z);
        // Signed, and scaled down in the shadows where real grain is least visible.
        float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
        float strength = effects.y * 0.12 * mix(0.4, 1.0, luminance);
        color += (n - 0.5) * strength;
    }

    return clamp(color, 0.0, 1.0);
}

// MARK: - Layer pass

vertex VertexOut layer_vertex(
    uint vertexID [[vertex_id]],
    constant LayerUniforms &uniforms [[buffer(0)]]
) {
    // Unit quad, triangle strip order.
    float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    float2 local = corners[vertexID];

    // Scale about the quad's own centre (pop-in animation).
    float2 scaled = (local - 0.5) * uniforms.scale + 0.5;

    // Map into the destination rect, in canvas space.
    float2 canvasPoint = uniforms.destination.xy + scaled * uniforms.destination.zw;

    // Rotate about the pivot. Canvas space is not square, so rotate in pixel-proportional
    // space and map back — otherwise a 45° rotation on a 9:16 canvas comes out sheared.
    if (uniforms.rotation != 0.0) {
        float aspect = uniforms.effects.w > 0.0 ? uniforms.effects.w : 1.0;
        float2 offset = (canvasPoint - uniforms.pivot) * float2(aspect, 1.0);
        float s = sin(uniforms.rotation);
        float c = cos(uniforms.rotation);
        float2 rotated = float2(offset.x * c - offset.y * s,
                                offset.x * s + offset.y * c);
        canvasPoint = uniforms.pivot + rotated / float2(aspect, 1.0);
    }

    VertexOut out;
    // Canvas space (top-left origin, y down) to NDC (centre origin, y up).
    out.position = float4(canvasPoint.x * 2.0 - 1.0,
                          1.0 - canvasPoint.y * 2.0,
                          0.0, 1.0);
    // Upright source coordinates, then through the orientation transform into texture space.
    float2 upright = uniforms.sourceCrop.xy + local * uniforms.sourceCrop.zw;
    float4 m = uniforms.sourceTransform;
    out.uv = float2(m.x * upright.x + m.z * upright.y + uniforms.sourceOffset.x,
                    m.y * upright.x + m.w * upright.y + uniforms.sourceOffset.y);
    out.frameUV = local;
    return out;
}

fragment float4 layer_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    sampler textureSampler [[sampler(0)]],
    constant LayerUniforms &uniforms [[buffer(0)]]
) {
    float4 color = source.sample(textureSampler, in.uv);
    color.rgb = applyGrade(color.rgb, uniforms.grade);
    // Effects use the *frame* position, not the source crop — a vignette belongs to the
    // frame, not to whatever region of the photo happens to be showing through it.
    color.rgb = applyEffects(color.rgb, in.frameUV, uniforms.effects);
    color *= uniforms.opacity;   // premultiplied: scale rgb and a together
    return color;
}

// Text and logo quads carry their own alpha and are already the right colour, so they skip
// grading entirely. Grading text would tint it away from the colour the user picked.
fragment float4 overlay_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    sampler textureSampler [[sampler(0)]],
    constant LayerUniforms &uniforms [[buffer(0)]]
) {
    float4 color = source.sample(textureSampler, in.uv);
    return color * uniforms.opacity;
}

// MARK: - Transition pass

vertex VertexOut fullscreen_vertex(uint vertexID [[vertex_id]]) {
    float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    float2 local = corners[vertexID];
    VertexOut out;
    out.position = float4(local.x * 2.0 - 1.0, 1.0 - local.y * 2.0, 0.0, 1.0);
    out.uv = local;
    return out;
}

static inline float2 directionVector(int direction) {
    switch (direction) {
        case 0:  return float2(-1.0, 0.0);  // left
        case 1:  return float2( 1.0, 0.0);  // right
        case 2:  return float2( 0.0, -1.0); // up
        default: return float2( 0.0, 1.0);  // down
    }
}

// Sampling outside 0...1 returns transparent with a clamp-to-zero sampler, which is what we
// want for slide and push — the incoming frame arrives from off-canvas, not from a smeared edge.
static inline float4 sampleBounded(texture2d<float> tex, sampler s, float2 uv) {
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return float4(0.0);
    }
    return tex.sample(s, uv);
}

fragment float4 transition_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> fromTexture [[texture(0)]],
    texture2d<float> toTexture [[texture(1)]],
    sampler textureSampler [[sampler(0)]],
    constant TransitionUniforms &uniforms [[buffer(0)]]
) {
    float t = clamp(uniforms.progress, 0.0, 1.0);
    float2 uv = in.uv;

    switch (uniforms.kind) {

        // Dissolve — also the fallback for anything we could not classify.
        case 0: {
            float4 a = fromTexture.sample(textureSampler, uv);
            float4 b = toTexture.sample(textureSampler, uv);
            return mix(a, b, t);
        }

        // Fade through black, then in. Two phases rather than a straight mix, so the midpoint
        // is genuinely black instead of a 50% blend of two images.
        case 1: {
            if (t < 0.5) {
                float4 a = fromTexture.sample(textureSampler, uv);
                return mix(a, float4(0.0, 0.0, 0.0, 1.0), t * 2.0);
            }
            float4 b = toTexture.sample(textureSampler, uv);
            return mix(float4(0.0, 0.0, 0.0, 1.0), b, (t - 0.5) * 2.0);
        }

        // Fade through white.
        case 2: {
            if (t < 0.5) {
                float4 a = fromTexture.sample(textureSampler, uv);
                return mix(a, float4(1.0), t * 2.0);
            }
            float4 b = toTexture.sample(textureSampler, uv);
            return mix(float4(1.0), b, (t - 0.5) * 2.0);
        }

        // Slide: both frames move together.
        case 3: {
            float2 d = directionVector(uniforms.direction);
            float4 a = sampleBounded(fromTexture, textureSampler, uv + d * t);
            float4 b = sampleBounded(toTexture, textureSampler, uv + d * (t - 1.0));
            return a + b * (1.0 - a.a);
        }

        // Push: only the incoming frame moves, over a stationary outgoing one.
        case 4: {
            float2 d = directionVector(uniforms.direction);
            float4 a = fromTexture.sample(textureSampler, uv);
            float4 b = sampleBounded(toTexture, textureSampler, uv + d * (t - 1.0));
            return a * (1.0 - b.a) + b;
        }

        // Zoom in: outgoing frame magnifies away as the incoming one arrives.
        case 5: {
            float zoom = 1.0 + t * 0.6;
            float2 zoomedUV = (uv - 0.5) / zoom + 0.5;
            float4 a = fromTexture.sample(textureSampler, zoomedUV);
            float4 b = toTexture.sample(textureSampler, uv);
            return mix(a, b, smoothstep(0.25, 1.0, t));
        }

        // Zoom out: incoming frame arrives magnified and settles.
        case 6: {
            float zoom = 1.6 - t * 0.6;
            float2 zoomedUV = (uv - 0.5) / zoom + 0.5;
            float4 a = fromTexture.sample(textureSampler, uv);
            float4 b = toTexture.sample(textureSampler, zoomedUV);
            return mix(a, b, smoothstep(0.0, 0.75, t));
        }

        // Whip: directional smear peaking mid-transition. Ten taps is enough to read as motion
        // blur at 30 fps and cheap enough not to matter.
        case 7: {
            float2 d = directionVector(uniforms.direction);
            float strength = sin(t * M_PI_F) * 0.14;
            float4 a = float4(0.0);
            float4 b = float4(0.0);
            const int taps = 10;
            for (int i = 0; i < taps; ++i) {
                float offset = (float(i) / float(taps - 1) - 0.5) * strength;
                a += fromTexture.sample(textureSampler, uv + d * (offset + t * 0.35));
                b += toTexture.sample(textureSampler, uv + d * (offset + (t - 1.0) * 0.35));
            }
            a /= float(taps);
            b /= float(taps);
            return mix(a, b, smoothstep(0.35, 0.65, t));
        }

        // Blur: the textures arrive pre-blurred from MPS, so this is just the crossfade.
        case 8: {
            float4 a = fromTexture.sample(textureSampler, uv);
            float4 b = toTexture.sample(textureSampler, uv);
            return mix(a, b, t);
        }

        default: {
            float4 a = fromTexture.sample(textureSampler, uv);
            float4 b = toTexture.sample(textureSampler, uv);
            return mix(a, b, t);
        }
    }
}
