#ifndef HS_GLINT_GLSL
#define HS_GLINT_GLSL

// Sun glint for glass, ice and water. Used by the translucent terrain program (gbuffers_water).
//
// Stylized on purpose, not a real reflection:
//  - a soft sheen on every surface that faces the sun, whatever the view angle;
//  - a brighter highlight at the mirror angle (where a real mirror would show the sun);
//  - a few sparkles that twinkle, only inside the lit area.
//
// Declares its own uniforms: shadowLightPosition, frameTimeCounter, cameraPosition,
// gbufferModelViewInverse (through viewmatrix.glsl, which lights.glsl and shadows.glsl share, so the
// three can be included together), plus everything atmosphere.glsl declares.

#include "/lib/settings.glsl"
#include "/lib/atmosphere.glsl"
#include "/lib/viewmatrix.glsl"

uniform vec3 shadowLightPosition;
uniform float frameTimeCounter;
uniform vec3 cameraPosition;

float hsHash13(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

// viewPos: view-space position of the surface. normal: unit view-space normal.
// skyLevel: 0..1 sky exposure. Returns rgb = glint color, a = glint opacity.
vec4 sunGlint(vec3 viewPos, vec3 normal, float skyLevel) {
	vec3 toLight = fastNormalize(shadowLightPosition);
	vec3 toEye = fastNormalize(-viewPos);

	// Sun by day, moon by night, like everywhere else in the pack. shadowLightPosition points at
	// whichever is up; the strength fades from sunlight to moonlight as the sun sets.
	vec3 sunDir = atmosphereSunDir();
	float sunElevation = dot(sunDir, atmosphereUp());

	// Sheen for surfaces facing the light, mirror-angle highlight on top.
	float facing = smoothstep(GLINT_FACING_MIN, 1.0, dot(normal, toLight));
	float nh = max(dot(normal, fastNormalize(toLight + toEye)), 0.0);
	float mirror = fastPow(nh, GLINT_SHARPNESS);
	float base = facing * (GLINT_SHEEN + GLINT_SPECULAR * mirror);

	// Sparkles. The world is cut into small cells; a share of them twinkle. Rounding with + 0.5 puts
	// a flat pane in the middle of a cell, so the pattern does not flicker along block boundaries.
	vec3 world = viewToFeetPosition(viewPos) + cameraPosition;
	vec3 cell = floor(world * GLINT_SPARKLE_DENSITY + 0.5);
	float h = hsHash13(cell);
	float twinkle = step(1.0 - GLINT_SPARKLE_AMOUNT, h) * (0.5 + 0.5 * sin(frameTimeCounter * GLINT_TWINKLE_SPEED + h * 40.0));
	// nh to the 6th power by multiplication: exact, and cheaper than a general pow.
	float nh2 = nh * nh;
	float sparkle = twinkle * facing * smoothstep(0.2, 0.9, nh2 * nh2 * nh2);

	// Needs a light to reflect: open sky and no rain. The light is the sun, or the dimmer moon.
	float exposure = skyLevel * skyLevel * (1.0 - rainStrength);
	float lightPower = mix(GLINT_MOON_FACTOR, 1.0, smoothstep(-0.10, 0.10, sunElevation));

	float intensity = clamp((base + GLINT_SPARKLE * sparkle) * exposure * lightPower, 0.0, 1.0);

	return vec4(sunLightColor(sunElevation), intensity);
}

#endif
