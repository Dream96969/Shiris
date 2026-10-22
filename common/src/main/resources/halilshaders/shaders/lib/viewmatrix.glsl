#ifndef HS_VIEWMATRIX_GLSL
#define HS_VIEWMATRIX_GLSL

// The one place that declares gbufferModelViewInverse. lights.glsl, glint.glsl and shadows.glsl all
// need it, and a uniform declared twice in one program is a compile error (which makes the whole
// pack fall back to vanilla). Include this file instead of declaring the uniform yourself.
//
// "Feet space" is world axes with the camera as the origin, which is what the shadow camera's
// matrices expect. Going from view space to feet space needs the WHOLE inverse matrix, translation
// included: while the player walks, the game's view bobbing moves the view by a few tenths of a
// block, and that offset lives in the translation. Using only the 3x3 part drops it, and every
// surface then lands up to a few tenths of a block off, which put whole scenes into shadow while
// walking. Directions (normals) have no position, so for them the 3x3 part is the right one.

uniform mat4 gbufferModelViewInverse;

vec3 viewToFeetPosition(vec3 viewPos) {
	return (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
}

vec3 viewToFeetDirection(vec3 viewDir) {
	return mat3(gbufferModelViewInverse) * viewDir;
}

#endif
