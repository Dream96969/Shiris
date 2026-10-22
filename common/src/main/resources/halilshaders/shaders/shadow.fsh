#version 330 compatibility

/* DRAWBUFFERS:0 */

// Shadow pass fragment stage. The map's depth is written automatically; this only throws away the
// see-through texels (leaves, flowers, fences, entity cut-outs) so that they do not cast a solid
// shadow, and writes the color to shadowcolor0 (not used yet: it is for colored shadows later).

uniform sampler2D gtexture;

in vec2 texcoord;
in vec4 glcolor;

void main() {
	vec4 color = texture(gtexture, texcoord) * glcolor;
	if (color.a < 0.1) discard;
	gl_FragData[0] = color;
}
