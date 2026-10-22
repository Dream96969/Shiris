#ifndef HS_RANGE_GLSL
#define HS_RANGE_GLSL

// Keeps a color inside 0..1 without changing its hue.
//
// The color buffers are 8 bit, so anything above 1.0 is cut off per channel. Cutting a bright warm
// color per channel pulls it toward yellow-white and flattens the texture. Dividing all three
// channels by the largest one keeps the hue. Colors that already fit are returned unchanged, so
// calling this never darkens a normal pixel.
//
// No uniforms are declared here, so it can be included anywhere.
#include "/lib/fastmath.glsl"

vec3 fitToRange(vec3 c) {
	float peak = max(max(c.r, c.g), c.b);
	// max(peak, 1.0) is 1.0 for a color that already fits, so there is nothing to branch on.
	return c * rcp(max(peak, 1.0));
}

#endif
