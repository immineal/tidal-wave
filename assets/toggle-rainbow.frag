#version 440
// The colour switch's glass rainbow in motion (qml/components/Toggle.qml).
// It bends tools/make-rainbow.py's picture; at reveal 1 with idle 0 it draws
// that picture unchanged. Baked by tools/make-rainbow-shader.sh.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    // 0 off, 1 on; the flip runs it either way.
    float reveal;
    // The idle motion's strength, 0 to 1, and its clock in seconds.
    float idle;
    float phase;
    // The effect's size in logical pixels: the track and PAD on every side.
    vec2 box;
};

layout(binding = 1) uniform sampler2D source;

const float PAD = 4.0;
const float PI = 3.14159265;
const float TAU = 6.28318531;
// One idle cycle; every idle term is periodic in it so the loop has no seam.
const float PERIOD = 12.0;
const float W = TAU / PERIOD;

// pow() is undefined for a negative base, so squares are spelled out.
float sq(float x) { return x * x; }

vec4 pick(vec2 p) {
    return texture(source, (p + PAD) / box);
}

void main() {
    vec2 p = qt_TexCoord0 * box - PAD;
    float tw = box.x - 2.0 * PAD;
    float th = box.y - 2.0 * PAD;
    float rad = th * 0.5;

    // Nearest point on the pill's spine and the way out from it, as
    // make-rainbow.py's shade() finds them.
    float qx = clamp(p.x, rad, tw - rad);
    vec2 v = vec2(p.x - qx, p.y - rad);
    float s = length(v);
    vec2 n = s > 1e-4 ? v / s : vec2(0.0);
    float rho = clamp(s / rad, 0.0, 1.0);
    float inside = rad - s;

    // ── idle: the rim breathes in a slow wave and a glint slides along the
    // upper rim. Only the light moves; the hues stay where they are.
    float still = idle * smoothstep(0.85, 1.0, reveal);
    vec2 d = vec2(0.0);
    float lift = 0.0;
    if (still > 0.0) {
        float bend = rho * rho * rho;
        float wave = sin(0.23 * p.x - 2.0 * W * phase)
                   + 0.5 * sin(0.41 * p.x + 3.0 * W * phase + 1.7);
        d += n * (0.7 * bend * wave * still);
        // The sheen band of make-rainbow.py, lit a little more where the
        // glint passes; a fainter one runs the other way along the lower rim.
        float sheen = exp(-sq((inside - 3.0) / 1.7)) * pow(max(-n.y, 0.0), 3.0);
        float caustic = exp(-sq((inside - 2.3) / 1.3)) * sq(max(n.y, 0.0));
        float gx = mod(W * phase, TAU) / TAU * (tw + 24.0) - 12.0;
        float hx = (1.0 - mod(W * phase + PI, TAU) / TAU) * (tw + 24.0) - 12.0;
        float glint = exp(-sq((p.x - gx) / 5.0));
        float glow2 = exp(-sq((p.x - hx) / 6.0));
        lift += still * (0.22 * sheen * glint + 0.08 * caustic * glow2);
    }

    // ── the flip: the colour comes in behind a front that moves with the
    // knob. `swell` is 0 at both ends, so at rest nothing bends.
    float r = clamp(reveal, 0.0, 1.0);
    float swell = sin(PI * r);
    float mask = 1.0;
    vec4 c;
    if (r >= 1.0) {
        c = pick(p + d);
    } else {
        // A thick glass bead rides the front, magnifies the colour under it
        // and catches the light; small rings run out behind it.
        float bead = 6.0;
        float xf = mix(-PAD - 1.0, tw + PAD + bead, r);
        float bow = 2.5 * sq((p.y - rad) / rad);
        float lc = xf - 0.6 * bead;
        float v = (p.x + bow - lc) / bead;
        float lens = exp(-1.5 * v * v);
        d.x -= 5.0 * swell * v * lens;
        d.y -= 3.0 * swell * (p.y - rad) / rad * lens;
        float behind = max(lc - p.x, 0.0);
        d.x += 1.0 * swell * sin(1.2 * behind - 20.0 * r) * exp(-behind / 8.0);
        mask = smoothstep(1.0, -1.0, (p.x + bow - xf) / 2.5);
        lift += swell * lens * (0.18 + 0.22 * max(-n.y, 0.0));
        c = pick(p + d);
    }
    c *= mask;
    // Lift towards white within the colour's own alpha (premultiplied).
    c.rgb += (vec3(c.a) - c.rgb) * clamp(lift, 0.0, 1.0);
    fragColor = c * qt_Opacity;
}
