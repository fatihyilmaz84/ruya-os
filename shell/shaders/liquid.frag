#version 440
// Liquid pill (04 §3.8, T-205): the blurred crop behind a top-bar pill, bent at the edge like a
// lens (the pixel shows what lies deeper inside, up to `bend` px away, with a smooth falloff), plus
// a slow specular band whose position is the sum of three sines (periods 9, 15 and 23 s). One
// texture, one pass, no loops. Compiled to liquid.frag.qsb by qt_add_shaders (shell/CMakeLists.txt).
// Colours are premultiplied, as Qt passes them.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 pillSize;      // the item's size in px
    float bend;         // refraction depth at the edge, px
    float time;         // seconds; the caller loops it at the common period of the three sines
    vec4 specular;      // peak colour of the specular (premultiplied)
    vec3 periods;       // seconds
};
layout(binding = 1) uniform sampler2D source;

const float TWO_PI = 6.28318530718;

void main()
{
    vec2 p = (qt_TexCoord0 - 0.5) * pillSize;
    float r = pillSize.y * 0.5;
    vec2 q = abs(p) - (pillSize * 0.5 - vec2(r));
    vec2 qo = max(q, vec2(0.0));
    float d = length(qo) + min(max(q.x, q.y), 0.0) - r;          // < 0 inside the pill
    float inside = -d;                                            // distance to the edge, px
    vec2 outward = (qo.x > 0.0 || qo.y > 0.0)
        ? normalize(qo) * sign(p)
        : (q.x > q.y ? vec2(sign(p.x), 0.0) : vec2(0.0, sign(p.y)));

    // Lens: near the edge sample from further in. Quadratic falloff, zero beyond `bend`.
    float k = clamp(1.0 - inside / max(bend, 1.0), 0.0, 1.0);
    vec2 uv = qt_TexCoord0 - outward * (bend * k * k) / pillSize;
    vec4 base = texture(source, clamp(uv, vec2(0.0), vec2(1.0)));

    // Specular: a soft band that drifts along the pill, stronger near the edge and the top.
    float s = (sin(TWO_PI * time / periods.x)
             + sin(TWO_PI * time / periods.y + 1.3)
             + sin(TWO_PI * time / periods.z + 2.7)) / 3.0;
    float centre = 0.5 + 0.42 * s;
    float band = exp(-pow((qt_TexCoord0.x - centre) / 0.14, 2.0));
    float shape = band * mix(0.35, 1.0, k) * (0.55 + 0.45 * (1.0 - qt_TexCoord0.y));

    float coverage = clamp(0.5 - d, 0.0, 1.0);                    // antialiased pill shape
    vec4 col = min(base + specular * shape, vec4(1.0));
    fragColor = col * coverage * qt_Opacity;
}
