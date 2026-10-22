// Light visibility seams. Only the deferred pass calls these.
//
// sunVisibility is the sun/moon shadow map lookup (Phase 7, lib/shadows.glsl). blockLightVisibility
// still returns 1.0 (nothing blocks block light); Phase 8 puts the block-light occlusion inside it.
// Nothing else in the pack needs to change when that happens, because every consumer reads the
// result from colortex3 (see docs/shader-pipeline.md for the contract):
//   colortex3.b = sunVisibility        (deferred writes it)
//   colortex3.a = blockLightVisibility (gbuffers write 1.0, deferred overwrites it)
//
// Rules for the implementations:
//   - Return a continuous 0..1 value (1 = fully lit, 0 = fully shadowed). Soft shadow edges then
//     fade the edge glow smoothly instead of cutting it.
//   - Do not include the N.L term. Surface orientation is applied separately by the consumers.
//   - Do not read the shadow map anywhere else. Consumers must use the stored value.
//
// Declares its own uniforms through lib/shadows.glsl (shadowtex1, shadowModelView,
// shadowProjection, gbufferModelViewInverse).

#include "/lib/shadows.glsl"

// viewPos: view-space position of the surface. viewNormal: unit view-space normal. nDotL: dot of the
// normal with the direction to the shadow-casting light (negative = turned away; those pixels are
// answered without reading the map).
// This is the map's answer only. deferred.fsh fades it out near the horizon and where the surface
// cannot see the sky, and stores the faded value.
float sunVisibility(vec3 viewPos, vec3 viewNormal, float nDotL) {
	return sunShadowVisibility(viewPos, viewNormal, nDotL);
}

// blockLevel: 0..1 vanilla block light level of the surface.
float blockLightVisibility(vec3 viewPos, vec3 viewNormal, float blockLevel) {
	return 1.0;
}
