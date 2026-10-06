precision mediump float;
// Draws title art with its black background keyed out, so logos saved as
// JPG on black can float over a colored or glowing card.
varying vec2 TexCoord;
uniform sampler2D Tex0;
uniform float alpha;
void main() {
    vec4 c = texture2D(Tex0, TexCoord);
    float lum = max(c.r, max(c.g, c.b));
    float a = smoothstep(0.04, 0.16, lum) * c.a * alpha;
    gl_FragColor = vec4(c.rgb, a);
}
