#ifndef HS_LOD_GLSL
#define HS_LOD_GLSL

// Level of detail: work that nobody can see is skipped or done more cheaply.
//
// "Can anybody see it" is judged by how many screen pixels one block covers at a given distance.
// That depends on the window height and the field of view, so the same scene gets full detail
// farther away in a tall window and loses it sooner in a small one.
//
// No uniforms are declared here: the caller passes its own viewHeight and projection values, so
// this file can be included in any program.

#include "/lib/settings.glsl"

// Screen pixels covered by one block, seen straight on at view distance dist.
//   viewHeightPixels: the viewHeight uniform.
//   tanHalfFov: gbufferProjectionInverse[1][1], which is tan(vertical field of view / 2).
float lodPixelsPerBlock(float dist, float viewHeightPixels, float tanHalfFov) {
	return viewHeightPixels / (2.0 * max(dist, 0.001) * tanHalfFov);
}

// 0..1: how much of the edge glow to keep. 0 means "do not even compute it".
float lodEdgeDetail(float pixelsPerBlock) {
	if (!LOD_ENABLED) return 1.0;
	return smoothstep(LOD_EDGE_MIN_PIXELS_PER_BLOCK, LOD_EDGE_FULL_PIXELS_PER_BLOCK, pixelsPerBlock);
}

// 0..1: how many of a cell's colored lights to use. 1 = all of them, 0 = only LOD_COLORED_LIGHTS_MIN.
float lodLightDetail(float pixelsPerBlock) {
	if (!LOD_ENABLED) return 1.0;
	return smoothstep(LOD_LIGHT_MIN_PIXELS_PER_BLOCK, LOD_LIGHT_FULL_PIXELS_PER_BLOCK, pixelsPerBlock);
}

#endif
