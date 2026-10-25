#version 430 compatibility

/* DRAWBUFFERS:4 */

// Light halos, drawn at half size.
//
// A halo is a soft glow around a torch, lava, glowstone and the like. Finding it costs a loop over
// up to 64 lights for every pixel, which is the most expensive thing the pack does per pixel. A soft
// glow does not need full resolution, so this pass draws it into colortex4 at half the width and
// height (scale.composite in shaders.properties, a quarter of the pixels), already multiplied by its
// strength for the time of day. composite1.fsh reads it back with bilinear filtering and adds it to
// the scene before fog, exactly where the full-size loop used to be.
//
// The half-size picture sits in the lower left quarter of colortex4. Texture coordinates here still
// run 0..1 over that quarter, which is the whole screen.
//
// Each half-size pixel covers four full-size pixels. Their nearest depth decides what hides the
// halo, so a halo never shows through the edge of something in front of it. The halo around a
// silhouette is therefore trimmed by up to a pixel, which is not noticeable in a glow.

#include "/lib/settings.glsl"
#include "/lib/fastmath.glsl"
// The light list needs version 430. It also declares gbufferModelViewInverse.
#include "/lib/lights.glsl"

uniform sampler2D depthtex0;
uniform mat4 gbufferProjectionInverse;
uniform float viewWidth;
uniform float viewHeight;

in vec2 texcoord;
flat in float haloScale;

vec3 viewPosAt(vec2 uv, float depth) {
	vec4 p = gbufferProjectionInverse * vec4(vec3(uv, depth) * 2.0 - 1.0, 1.0);
	return p.xyz * rcp(p.w);
}

void main() {
	vec3 halo = vec3(0.0);

	// By day the halos are almost gone: when the strength is below what an 8 bit color can show (the
	// halo sum is at most 1), the whole light loop is skipped. This stays a branch because it skips up
	// to 64 lights per pixel.
	if (HALO_ENABLED && haloScale > 0.002 && hsLightHeader.x > 0) {
		// Nearest depth of the four full-size pixels under this half-size pixel. Their centers are
		// half a full-size pixel from this pixel's center in each direction.
		vec2 halfTexel = 0.5 * rcp(vec2(viewWidth, viewHeight));
		float depth = min(min(texture(depthtex0, texcoord + vec2(-halfTexel.x, -halfTexel.y)).r,
		                      texture(depthtex0, texcoord + vec2( halfTexel.x, -halfTexel.y)).r),
		                  min(texture(depthtex0, texcoord + vec2(-halfTexel.x,  halfTexel.y)).r,
		                      texture(depthtex0, texcoord + vec2( halfTexel.x,  halfTexel.y)).r));

		// For sky pixels this is a point on the far plane, which still gives the right direction.
		vec3 viewPos = viewPosAt(texcoord, depth);
		float dist = fastLength(viewPos);
		vec3 viewDir = viewPos * rcp(dist);

		float sceneDist = mix(dist, 1.0e6, step(1.0, depth));
		halo = lightHalos(viewDir, sceneDist) * haloScale;
	}

	gl_FragData[0] = vec4(halo, 0.0);
}
