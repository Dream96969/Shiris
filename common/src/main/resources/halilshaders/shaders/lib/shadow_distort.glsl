#ifndef HS_SHADOW_DISTORT_GLSL
#define HS_SHADOW_DISTORT_GLSL

// Shadow map distortion. Declares no uniforms.
//
// The shadow map covers a large square around the player, so with an even spread every texel would be
// large. The distortion stretches the middle of the map: texels near the player get smaller and far
// ones larger, which is where nobody looks closely. It acts on the x and y of the map's clip space
// only, so depth is untouched.
//
// shadow.vsh draws the map through shadowDistort(), and lib/shadows.glsl looks it up through the
// same function. They must never differ, so both include this file.

#include "/lib/settings.glsl"
#include "/lib/fastmath.glsl"

// Radial scale at a clip-space xy: 1 at the very edge, SHADOW_DISTORTION's complement in the middle.
float shadowDistortFactor(vec2 clipXY) {
	return fastLength(clipXY) * SHADOW_DISTORTION + (1.0 - SHADOW_DISTORTION);
}

vec2 shadowDistort(vec2 clipXY) {
	return clipXY * rcp(shadowDistortFactor(clipXY));
}

#endif
