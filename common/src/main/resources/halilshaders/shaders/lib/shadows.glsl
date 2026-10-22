#ifndef HS_SHADOWS_GLSL
#define HS_SHADOWS_GLSL

// Sun and moon shadow lookup. Fragment shaders only (it reads gl_FragCoord). Only the deferred pass
// includes this, through lib/lighting.glsl.
//
// Declares its own uniforms: shadowtex1, shadowModelView, shadowProjection, and
// gbufferModelViewInverse through viewmatrix.glsl.
//
// How it works:
//  1. The surface position (view space) is turned into the shadow camera's clip space.
//  2. The position is first moved a little along the surface normal. This is the main cure for
//     "shadow acne" (a surface shadowing itself because the map is too coarse to tell where the
//     surface is). The step is measured in map texels, so it stays right while the map is distorted.
//  3. The map's depth is compared with the surface's depth at several points on a small disk, and the
//     share of points that are lit is the result. The disk is turned a different amount in every
//     pixel (interleaved gradient noise), which trades banding for fine grain. The disk is a
//     fraction of a block wide, so shadow edges are soft but close to the object that casts them.
//  4. Near the edge of the map, and beyond its depth range, the result fades to 1 (no shadow).
//
// shadowtex1 holds the depth of opaque geometry only. Glass and water therefore do not cast shadows
// yet, and sunlight passes through them (colored shadows would come from shadowtex0 and shadowcolor0).
//
// The map's settings (size, distance) are the constants at the top of lib/settings.glsl. The depth
// range below must match the shadow camera's near and far planes (Iris default: -100.05 and 156).

#include "/lib/settings.glsl"
#include "/lib/fastmath.glsl"
#include "/lib/viewmatrix.glsl"
#include "/lib/shadow_distort.glsl"

uniform sampler2D shadowtex1;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;

// Near to far distance of the shadow camera, in blocks.
const float HS_SHADOW_DEPTH_RANGE = 256.05;

// World size of one map texel before distortion.
const float HS_SHADOW_TEXEL_BLOCKS = 2.0 * shadowDistance / float(shadowMapResolution);

// The distortion's scale in the very middle of the map (kept above zero so the divide is safe).
const float HS_SHADOW_CENTER_SCALE = max(1.0 - SHADOW_DISTORTION, 0.02);

const float HS_SHADOW_INV_SAMPLES = 1.0 / float(SHADOW_SAMPLES);

// cos and sin of the golden angle (2.39996 rad). Turning by it after every sample spreads the
// samples evenly over the disk.
const vec2 HS_GOLDEN_ROTATION = vec2(-0.7373688, 0.6754903);

float hsInterleavedGradientNoise(vec2 pixel) {
	return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
}

// Share of the sun's (or moon's) light that reaches the surface, from the shadow map alone.
// 1.0 = fully lit, 0.0 = fully shadowed, continuous in between. The result does not include a smooth
// N.L term and does not know about the horizon fade or sky exposure: deferred.fsh applies those.
//   viewPos: view-space position of the surface. viewNormal: unit view-space normal.
//   nDotL: dot(viewNormal, direction to the light). A surface turned clearly away from the light is
//   always in shadow (the map would say the same), so those pixels skip all map reads.
float sunShadowVisibility(vec3 viewPos, vec3 viewNormal, float nDotL) {
	if (nDotL < -0.02) {
		return 0.0;
	}

	// View space to "feet space" (world axes, camera at the origin), which is what the shadow camera's
	// matrices expect. The position needs the full matrix: see viewmatrix.glsl for why.
	vec3 feetPos = viewToFeetPosition(viewPos);
	vec3 feetNormal = viewToFeetDirection(viewNormal);

	// Where the surface is in the shadow camera's clip space. The projection is orthographic, so w is
	// 1 and xyz can be used as they are.
	vec3 clip = (shadowProjection * (shadowModelView * vec4(feetPos, 1.0))).xyz;

	// Size of one map texel in blocks at this spot. Where the distortion has stretched the map
	// (near the player) texels are small; the local stretch is HS_SHADOW_CENTER_SCALE / f^2.
	float f = shadowDistortFactor(clip.xy);
	float texelBlocks = HS_SHADOW_TEXEL_BLOCKS * f * f * rcp(HS_SHADOW_CENTER_SCALE);

	// Move along the normal, then look the moved position up.
	vec3 movedFeet = feetPos + feetNormal * (texelBlocks * SHADOW_NORMAL_OFFSET);
	vec3 movedClip = (shadowProjection * (shadowModelView * vec4(movedFeet, 1.0))).xyz;
	vec2 uv = shadowDistort(movedClip.xy) * 0.5 + 0.5;

	// Depth in the map is 0..1 over the camera's depth range. The bias is given in blocks.
	float bias = (SHADOW_BIAS_BLOCKS + texelBlocks * SHADOW_BIAS_TEXELS) * rcp(HS_SHADOW_DEPTH_RANGE);
	float depth = movedClip.z * 0.5 + 0.5 - bias;

	// Fade out toward the edge of the map, and give up beyond its far plane. This stays a branch: a
	// pixel outside the map needs none of the map reads below.
	float edge = max(abs(movedClip.x), abs(movedClip.y));
	float fade = (1.0 - smoothstep(SHADOW_EDGE_FADE_START, 1.0, edge)) * step(depth, 1.0);
	if (fade <= 0.0) {
		return 1.0;
	}

	// Width of the filter disk in map texels: a fixed width in blocks, but never less than one texel
	// and never more than SHADOW_BLUR_MAX_TEXELS (far shadows get coarse because their texels are big).
	float radiusTexels = clamp(SHADOW_SOFTNESS * rcp(texelBlocks), 1.0, SHADOW_BLUR_MAX_TEXELS);
	float radiusUV = radiusTexels * rcp(float(shadowMapResolution));

	// Rotate the disk differently in every pixel.
	float angle = hsInterleavedGradientNoise(gl_FragCoord.xy) * 6.2831853;
	vec2 dir = vec2(cos(angle), sin(angle));

	float lit = 0.0;
	for (int i = 0; i < SHADOW_SAMPLES; i++) {
		// Sample i sits at radius sqrt(t) so that the samples cover the disk evenly.
		float t = (float(i) + 0.5) * HS_SHADOW_INV_SAMPLES;
		float r = t * inversesqrt(t);
		// Lit when the surface is not farther from the sun than the nearest thing the map saw there.
		lit += step(depth, textureLod(shadowtex1, uv + dir * (r * radiusUV), 0.0).r);
		dir = vec2(dir.x * HS_GOLDEN_ROTATION.x - dir.y * HS_GOLDEN_ROTATION.y,
		           dir.x * HS_GOLDEN_ROTATION.y + dir.y * HS_GOLDEN_ROTATION.x);
	}
	lit *= HS_SHADOW_INV_SAMPLES;

	return mix(1.0, lit, fade);
}

#endif
