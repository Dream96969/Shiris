#version 430 compatibility

// The shadow light's direction and a few values that depend only on the time of day and the weather
// are the same for every pixel of this full-screen pass, so they are worked out here once per vertex
// (four per frame) and handed to the fragment stage as flat values instead of once per pixel.

#include "/lib/settings.glsl"
#include "/lib/fastmath.glsl"

uniform vec3 sunPosition;
uniform vec3 upPosition;
uniform vec3 shadowLightPosition;
uniform float rainStrength;

out vec2 texcoord;

// Unit view-space direction to the shadow-casting light (the sun by day, the moon by night).
flat out vec3 lightDir;
// x: shadow fade (0 with the light at the horizon, 1 once it is high enough).
// y: daylight (0 at night, 1 by day).
// z: shadow strength for the time of day and weather (moon and rain already applied).
flat out vec3 lightParams;

void main() {
	gl_Position = ftransform();
	texcoord = gl_MultiTexCoord0.xy;

	lightDir = fastNormalize(shadowLightPosition);

	// Sine of the shadow light's height, then how far into the fade range it is.
	float lightHeight = fastCosAngle(shadowLightPosition, upPosition);
	float shadowFade = smoothstep(SHADOW_HORIZON_START, SHADOW_HORIZON_END, lightHeight);

	float sunElevation = fastCosAngle(sunPosition, upPosition);
	float daylight = smoothstep(-0.10, 0.30, sunElevation);

	// The shadow light is the sun when it points the same way as the sun, otherwise the moon.
	float lightIsSun = step(0.0, dot(shadowLightPosition, sunPosition));
	float shadowStrength = SHADOW_STRENGTH * mix(SHADOW_MOON_FACTOR, 1.0, lightIsSun) * (1.0 - SHADOW_RAIN_REDUCTION * rainStrength);

	lightParams = vec3(shadowFade, daylight, shadowStrength);
}
