#version 430 compatibility

/* DRAWBUFFERS:03 */

// Shader storage buffers (the light list) need version 430. lights.glsl brings in settings.glsl and
// atmosphere.glsl, which declares sunPosition, upPosition and rainStrength.
#include "/lib/fastmath.glsl"
#include "/lib/lighting.glsl"
#include "/lib/lights.glsl"
// Keeps the lit color inside 0..1 without changing its hue.
#include "/lib/range.glsl"
// Level of detail: far surfaces use fewer colored lights.
#include "/lib/lod.glsl"

uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D colortex3;
uniform sampler2D depthtex0;
uniform mat4 gbufferProjectionInverse;
uniform float viewHeight;

in vec2 texcoord;
// From deferred.vsh: the shadow light's direction and per-frame values (see the notes there).
flat in vec3 lightDir;
flat in vec3 lightParams;

// How much surfaces facing the sun (or moon at night) are brightened.
const float LIGHT_STRENGTH = 0.25;

void main() {
	vec4 scene = texture(colortex0, texcoord);
	vec4 aux = texture(colortex3, texcoord);
	vec4 lightmapData = texture(colortex2, texcoord);
	float depth = texture(depthtex0, texcoord).r;

	// Nothing to light here in two cases:
	//  - sky pixels (no geometry);
	//  - pixels no opaque gbuffer program wrote to. colortex2 clears to alpha 0 and opaque
	//    programs write alpha 1, so alpha 0 means self-lit geometry such as translucent
	//    entities drawn before this pass. Over the sky their lightmap would read as 0 (black).
	// colortex3 is read and written by this pass, so it is copied through unchanged here.
	// This stays a branch: it skips the whole lighting below.
	if (depth >= 1.0 || lightmapData.a < 0.5) {
		gl_FragData[0] = scene;
		gl_FragData[1] = aux;
		return;
	}

	vec4 normalData = texture(colortex1, texcoord);
	vec3 normal = fastNormalize(normalData.rgb * 2.0 - 1.0);
	float skyLevel = normalData.a;
	vec3 lightmapColor = lightmapData.rgb;

	vec4 p = gbufferProjectionInverse * vec4(vec3(texcoord, depth) * 2.0 - 1.0, 1.0);
	vec3 viewPos = p.xyz * rcp(p.w);

	// Shadow fade: shadows die out as the shadow-casting light (the sun by day, the moon by night)
	// sinks to the horizon, where they would be endless. Worked out in deferred.vsh.
	float shadowFade = lightParams.x;
	float nDotL = dot(normal, lightDir);

	// Light visibility (shadows) lives in these two functions and is stored for later passes. The sun
	// lookup is skipped where it could not change anything: shadows switched off, the light at the
	// horizon, or a surface that gets no sky light (caves, interiors). This stays a branch: it skips
	// all the shadow map reads of the pixel.
	float sunVis = 1.0;
	if (SHADOW_ENABLED && shadowFade > 0.0 && skyLevel > 0.02) {
		sunVis = mix(1.0, sunVisibility(viewPos, normal, nDotL), shadowFade);
	}
	aux.b = sunVis;
	aux.a = blockLightVisibility(viewPos, normal, aux.r);

	// Only surfaces that can see the sky get the directional term, and shadows remove it.
	float facing = max(nDotL, 0.0);
	float direct = facing * skyLevel * skyLevel * sunVis * (1.0 - 0.8 * rainStrength);

	// How much of this surface's light is block light rather than sky light. By day the sky dominates;
	// at night even a fully sky-exposed surface is dim, so block light takes over. The colored light
	// below and the sun shadow both use it: block light is not shadowed by the sun.
	float daylight = lightParams.y;
	float skyBrightness = skyLevel * mix(0.15, 1.0, daylight);
	float blockShare = aux.r * rcp(max(aux.r + skyBrightness, 0.001));

	// Colored block light from the fork's light list. A surface with no block light at all (aux.r is
	// 0) would not show any colored light: it is scaled by blockShare, which is 0 there. Skipping it
	// changes nothing and saves the whole light loop for every sunlit or dark pixel, so this stays a
	// branch.
	vec3 lm = lightmapColor;
	vec3 coloredLight = vec3(0.0);

	if (COLORED_LIGHT_ENABLED && aux.r > 0.002) {
		// Level of detail: far surfaces, where a block covers only a few pixels, use fewer lights.
		float lightDetail = lodLightDetail(lodPixelsPerBlock(fastLength(viewPos), viewHeight, gbufferProjectionInverse[1][1]));
		vec4 colored = coloredLightAt(viewPos, normal, aux.r, lightDetail);
		coloredLight = colored.rgb;

		// Replace the hue of vanilla's fixed warm block light with the lights' own colors. The new
		// light color is scaled so that its BRIGHTEST channel equals the brightest channel of the
		// vanilla light: the surface can then be filtered but never pushed above 1.0 by this step.
		// (Scaling by luma instead gave a red channel of 2 or more for lava, which fitToRange then
		// divided away, so a white block and a stone block ended up the same flat orange.)
		// Weighted by how much of the light the list explains.
		float lightPeak = max(max(colored.r, colored.g), colored.b);
		vec3 hue = colored.rgb * rcp(max(lightPeak, 0.0001));
		float vanillaPeak = max(max(lm.r, lm.g), lm.b);
		float tint = colored.a * blockShare * COLORED_LIGHT_TINT;
		lm = mix(lm, hue * vanillaPeak, tint);
	}

	// Sun shadow. It takes away the part of the light that comes from the sun or moon, so it is
	// weighted by sky exposure (a cave wall under a roof is already dark; shadowing it again would
	// double it) and by the share of the light that is sky light (a torch's light is not shadowed by
	// the sun). Moonlight shadows are weaker, and rain washes them out (both already in lightParams.z).
	// The tint only removes light.
	float shadowAmount = (1.0 - sunVis) * skyLevel * skyLevel * (1.0 - blockShare) * lightParams.z;
	vec3 shadowTint = mix(vec3(1.0), SHADOW_COLOR, shadowAmount);

	// The sun boost is scaled by how much headroom the surface has left. A dark surface gets the
	// full boost; one that is already near white (snow, quartz, white wool) gets almost none.
	// Without this, a white top face under a high sun reached 1.25, was cut off at 1.0 and lost
	// its texture. At peak 0.5 and below this is the same boost as before, and a surface can
	// never be pushed above 1.0 by it.
	vec3 base = scene.rgb * lm * shadowTint;
	float peak = max(max(base.r, base.g), base.b);
	float headroom = clamp(2.0 * (1.0 - peak), 0.0, 1.0);
	vec3 lit = base * (1.0 + LIGHT_STRENGTH * direct * headroom);
	lit += scene.rgb * coloredLight * blockShare * COLORED_LIGHT_EXTRA;

	// Colored light can still push a channel past 1.0 (the extra glow is added on top of the lit
	// color). Scale by the brightest channel instead of letting each channel clip on its own.
	lit = fitToRange(lit);

	gl_FragData[0] = vec4(lit, scene.a);
	gl_FragData[1] = aux;
}
