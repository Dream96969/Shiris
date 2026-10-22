// Self-lit / sky geometry (sun, moon, clouds, beams, glints, cracks): texture * vertex color, no lightmap.
uniform sampler2D gtexture;

in vec2 texcoord;
in vec4 glcolor;

void main() {
	vec4 color = texture(gtexture, texcoord) * glcolor;
	if (color.a < 0.01) discard;
	gl_FragData[0] = color;
}
