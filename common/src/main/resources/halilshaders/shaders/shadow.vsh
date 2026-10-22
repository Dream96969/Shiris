#version 330 compatibility

// Shadow pass: the scene drawn from the sun (or moon) into the shadow map. Terrain, entities and
// block entities all use this one program, so it declares only what exists on every one of those
// vertex paths (no mc_Entity, which only terrain has).
//
// The only job here is to place each vertex in the map and pass the texture on for the alpha test.
// shadowDistort() must be the same function the lookup in lib/shadows.glsl uses.

#include "/lib/shadow_distort.glsl"

out vec2 texcoord;
out vec4 glcolor;

void main() {
	gl_Position = ftransform();
	gl_Position.xy = shadowDistort(gl_Position.xy);

	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
	glcolor = gl_Color;
}
