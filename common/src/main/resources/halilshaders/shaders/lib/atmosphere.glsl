#ifndef HS_ATMOSPHERE_GLSL
#define HS_ATMOSPHERE_GLSL

// Shared atmosphere: the one place that decides the color of the sky and of distant fog.
//
// The sky dome (gbuffers_skybasic) and the fog on terrain (composite) both call atmosphereColor()
// with the view direction, so far terrain fades into exactly the sky behind it, with no seam.
// Never write a second fog or sky color anywhere else (see docs/shader-pipeline.md).
//
// This file declares the uniforms it uses. Programs that include it must not declare them again.
// Colors stay in the pipeline's native (gamma-encoded) space, like the rest of the pack.

#include "/lib/settings.glsl"
#include "/lib/fastmath.glsl"

uniform vec3 fogColor;
uniform vec3 skyColor;
uniform vec3 upPosition;
uniform vec3 sunPosition;
uniform float rainStrength;
uniform int isEyeInWater;
uniform float blindness;
uniform float darknessFactor;

// Smoothed biome climate, from custom uniforms in shaders.properties. Both are 0 for a
// temperate biome (and when the uniforms are missing), so a failure leaves the haze untinted.
uniform float hsWarmth;   // biome temperature - 0.8
uniform float hsHumidity; // biome rainfall - 0.4

// Color of the sun's light for a given sun elevation e (-1..1, 0 = on the horizon):
// near white at noon, orange when low, cool blue by moonlight.
vec3 sunLightColor(float e) {
	vec3 noon = vec3(1.00, 0.97, 0.90);
	vec3 low = vec3(1.00, 0.70, 0.45);
	vec3 moon = vec3(0.65, 0.78, 1.00);
	return mix(moon, mix(low, noon, smoothstep(0.05, 0.50, e)), smoothstep(-0.12, 0.05, e));
}

// RGB shift for the biome's climate. Plains (temperature 0.8, rainfall 0.4) give zero.
vec3 biomeShift() {
	float warm = clamp(hsWarmth / 1.2, -1.0, 1.0); // desert is +1, snowy plains about -0.7
	float wet = clamp(hsHumidity / 0.5, 0.0, 1.0);
	float hot = max(warm, 0.0);
	float cold = max(-warm, 0.0);

	vec3 shift = hot * mix(FOG_BIOME_HOT_DRY, FOG_BIOME_HOT_WET, wet)
		+ cold * FOG_BIOME_COLD
		+ wet * (1.0 - hot) * (1.0 - cold) * FOG_BIOME_WET;
	return shift * FOG_BIOME_STRENGTH;
}

// The atmosphere is split in two so that a full-screen pass does not repeat per pixel what only
// depends on the frame. The functions below that read uniforms only (atmosphereUp, atmosphereSunDir,
// atmosphereBiome, atmosphereGlow, fogSpecialAmount) give the per-frame values, and
// atmosphereColorFrom() is the per-pixel part. composite.vsh computes the frame values once per
// frame and passes them on as flat varyings; atmosphereColor() below does both steps for callers
// that run per vertex or have no vertex stage of their own (the sky dome). Both paths run the same
// per-pixel function, so sky and fog can never differ.

// Unit view-space direction of the sky's up.
vec3 atmosphereUp() {
	return fastNormalize(upPosition);
}

// Unit view-space direction of the sun.
vec3 atmosphereSunDir() {
	return fastNormalize(sunPosition);
}

// Biome tint before the horizon weighting. Rain washes it out.
vec3 atmosphereBiome() {
	return biomeShift() * (1.0 - 0.5 * rainStrength);
}

// Color and strength of the sun glow, before the angle to the sun and the horizon weighting. The
// haze lights up toward the sun in the sun's color; day only, and not in rain. up and sunDir are
// the unit vectors from the two functions above.
vec3 atmosphereGlow(vec3 up, vec3 sunDir) {
	float e = dot(sunDir, up);
	float daylight = smoothstep(-0.10, 0.10, e);
	return sunLightColor(e) * (daylight * FOG_SUN_STRENGTH * (1.0 - rainStrength));
}

// How far the game's own fog replaces the atmosphere: underwater, in lava or powder snow, and under
// blindness or darkness the game's fog color is used unchanged, because there the fog IS the
// environment.
float fogSpecialAmount() {
	return max(float(isEyeInWater != 0), max(blindness, darknessFactor));
}

// Color of the sky, and of the haze that distant things fade into, in a view-space direction.
// viewDir must be a unit vector. The other four arguments are the per-frame values above.
vec3 atmosphereColorFrom(vec3 viewDir, vec3 up, vec3 sunDir, vec3 biome, vec3 glow) {
	float height = dot(viewDir, up);

	// Horizon fog color blending up into the sky color.
	vec3 color = mix(fogColor, skyColor, smoothstep(0.0, 0.45, height));

	// Haze lives near the horizon.
	float horizon = 1.0 - smoothstep(0.0, 0.6, height);

	// Biome tint: strongest at the horizon, a little overhead.
	color += biome * mix(0.4, 1.0, horizon);

	// Sun glow toward the sun.
	float towardSun = fastPow(max(dot(viewDir, sunDir), 0.0), FOG_SUN_POWER);
	color += glow * (towardSun * horizon);

	return clamp(color, 0.0, 1.0);
}

// Same, working out the per-frame values itself.
vec3 atmosphereColor(vec3 viewDir) {
	vec3 up = atmosphereUp();
	vec3 sunDir = atmosphereSunDir();
	return atmosphereColorFrom(viewDir, up, sunDir, atmosphereBiome(), atmosphereGlow(up, sunDir));
}

// Fog color for terrain, from the per-frame values (and special = fogSpecialAmount()).
vec3 fogColorFrom(vec3 viewDir, vec3 up, vec3 sunDir, vec3 biome, vec3 glow, float special) {
	return mix(atmosphereColorFrom(viewDir, up, sunDir, biome, glow), fogColor, special);
}

// Same, working out the per-frame values itself.
vec3 fogColorAt(vec3 viewDir) {
	return mix(atmosphereColor(viewDir), fogColor, fogSpecialAmount());
}

#endif
