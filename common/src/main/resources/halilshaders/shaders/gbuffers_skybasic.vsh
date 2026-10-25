#version 330 compatibility

// Sky color depends only on frame uniforms. Calculate those values once per vertex instead of once
// per sky pixel; the fragment stage still computes the direction-dependent part per pixel.
#include "/lib/atmosphere.glsl"

out vec4 glcolor;

flat out vec3 atmoUp;
flat out vec3 atmoSunDir;
flat out vec3 atmoBiome;
flat out vec3 atmoGlow;

void main() {
	gl_Position = ftransform();
	glcolor = gl_Color;
	atmoUp = atmosphereUp();
	atmoSunDir = atmosphereSunDir();
	atmoBiome = atmosphereBiome();
	atmoGlow = atmosphereGlow(atmoUp, atmoSunDir);
}
