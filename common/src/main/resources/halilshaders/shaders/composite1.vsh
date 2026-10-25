#version 430 compatibility

// Everything below depends only on the frame (time of day, weather, the game's fog settings), not on
// the pixel, and the fragment stage of this full-screen pass would otherwise work it out again for
// every pixel. It is worked out here, once per vertex (four per frame), and handed over as flat
// values. The fragment stage runs the same atmosphere function as the sky dome on them, see
// lib/atmosphere.glsl.

#include "/lib/settings.glsl"
#include "/lib/fastmath.glsl"
// The atmosphere include also declares fogColor, skyColor, sunPosition, upPosition and rainStrength.
#include "/lib/atmosphere.glsl"

uniform vec3 shadowLightPosition;
uniform float fogStart;
uniform float fogEnd;
uniform float far;

out vec2 texcoord;

// Atmosphere per-frame values (see atmosphereColorFrom in lib/atmosphere.glsl).
flat out vec3 atmoUp;
flat out vec3 atmoSunDir;
flat out vec3 atmoBiome;
flat out vec3 atmoGlow;

// Unit view-space direction to the shadow-casting light (the sun by day, the moon by night).
flat out vec3 toLightDir;

// x: edge glow strength of the light (the moon's is weaker). y: halo strength for the time of day.
// z: where render-distance fog starts. w: one over its length.
flat out vec4 frameA;

// x: one over the length of the game's own fog range, 0 when it reports none (so the fog amount is 0).
// y: how much the game's own fog color replaces the atmosphere (underwater, blindness, ...).
flat out vec2 frameB;

void main() {
	gl_Position = ftransform();
	texcoord = gl_MultiTexCoord0.xy;

	atmoUp = atmosphereUp();
	atmoSunDir = atmosphereSunDir();
	atmoBiome = atmosphereBiome();
	atmoGlow = atmosphereGlow(atmoUp, atmoSunDir);

	toLightDir = fastNormalize(shadowLightPosition);

	// The shadow light is the sun when it points the same way as the sun, otherwise the moon.
	float lightPower = mix(EDGE_MOON_FACTOR, 1.0, step(0.0, dot(shadowLightPosition, sunPosition)));

	// By day the halos are almost gone.
	float daylight = smoothstep(-0.10, 0.30, dot(atmoSunDir, atmoUp));
	float haloScale = HALO_STRENGTH * mix(1.0, HALO_DAY_FACTOR, daylight);

	// Render distance fog hides the edge of the loaded world.
	float rdStart = far - clamp(far * 0.1, 4.0, 64.0);
	float rdInvSpan = rcp(max(far - rdStart, 1.0e-5));

	frameA = vec4(lightPower, haloScale, rdStart, rdInvSpan);

	// Environmental fog (haze, underwater, lava, blindness) as reported by the game. Nothing when the
	// game reports no fog range (fogEnd not above fogStart).
	float fogSpan = fogEnd - fogStart;
	frameB = vec2(step(1.0e-5, fogSpan) * rcp(max(fogSpan, 1.0e-5)), fogSpecialAmount());
}
