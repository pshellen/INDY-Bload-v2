precision mediump float;
// Rounded outline only (transparent inside). Draw with any 1x1 texture.
varying vec2 TexCoord;
uniform sampler2D Tex0;
uniform vec2 size;
uniform float radius;
uniform float border;
uniform vec4 color;
float box(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return length(max(q, 0.0)) - r;
}
void main() {
    vec2 p = TexCoord * size - size * 0.5;
    float outer = 1.0 - smoothstep(0.0, 1.0, box(p, size * 0.5, radius));
    float inner = 1.0 - smoothstep(0.0, 1.0, box(p, size * 0.5 - vec2(border), radius - border));
    float a = clamp(outer - inner, 0.0, 1.0) * color.a;
    gl_FragColor = vec4(color.rgb, a);
}
