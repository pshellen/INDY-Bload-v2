precision mediump float;
// Soft colored glow from the title art: low mipmap levels, five taps, dimmed.
// The texture must be loaded with mipmap = true.
varying vec2 TexCoord;
uniform sampler2D Tex0;
uniform float dim;
uniform vec2 spread;
void main() {
    vec2 uv = TexCoord;
    const float bias = 5.0;
    vec3 c = texture2D(Tex0, uv, bias).rgb * 0.36;
    c += texture2D(Tex0, uv + vec2( spread.x,  spread.y), bias).rgb * 0.16;
    c += texture2D(Tex0, uv + vec2(-spread.x,  spread.y), bias).rgb * 0.16;
    c += texture2D(Tex0, uv + vec2( spread.x, -spread.y), bias).rgb * 0.16;
    c += texture2D(Tex0, uv + vec2(-spread.x, -spread.y), bias).rgb * 0.16;
    vec2 d = uv - 0.5;
    float v = clamp(1.0 - dot(d, d) * 2.2, 0.0, 1.0);
    float a = v * dim;
    gl_FragColor = vec4(c, a);
}
