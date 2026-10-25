#version 430 compatibility

// The halo's per-frame strength. The halo pass runs at half size (see composite.fsh), so its vertex
// stage only has to work out how strong halos are at this time of day: by day they are almost gone.

#include "/lib/settings.glsl"
#include "/lib/fastmath.glsl"

uniform vec3 sunPosition;
uniform vec3 upPosition;

out vec2 texcoord;

// HALO_STRENGTH scaled for the time of day. composite1.vsh works out the same value for its own use.
flat out float haloScale;

void main() {
	gl_Position = ftransform();
	texcoord = gl_MultiTexCoord0.xy;

	float daylight = smoothstep(-0.10, 0.30, fastCosAngle(sunPosition, upPosition));
	haloScale = HALO_STRENGTH * mix(1.0, HALO_DAY_FACTOR, daylight);
}
