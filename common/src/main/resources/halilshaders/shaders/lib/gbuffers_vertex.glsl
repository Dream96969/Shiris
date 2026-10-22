// Shared vertex stage for every gbuffers_* program.
//
// Terrain programs define HS_TERRAIN before including this file. Only they get block IDs
// (mc_Entity), and they pass edgeMask to the fragment stage: 0.0 for foliage, 1.0 otherwise.
// Entity programs must not declare mc_Entity (it does not exist on that vertex path).
//
// The translucent terrain program (gbuffers_water) defines HS_GLINT instead. It also reads
// mc_Entity, and passes the fragment stage what the sun glint needs: the surface position in view
// space and whether the surface is water.
#if defined(HS_TERRAIN) || defined(HS_GLINT)
in vec4 mc_Entity;
#endif

#ifdef HS_TERRAIN
out float edgeMask;

// Must match the foliage line in block.properties.
const float HS_FOLIAGE_ID = 10001.0;
#endif

#ifdef HS_GLINT
out vec3 viewPosition;
out float isWaterSurface;

// Must match the water line in block.properties.
const float HS_WATER_ID = 10002.0;
#endif

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;
out vec3 viewNormal;

void main() {
	gl_Position = ftransform();
	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
	// Raw lightmap coordinates: usable directly to sample the vanilla lightmap texture.
	lmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
	glcolor = gl_Color;

	vec3 n = gl_NormalMatrix * gl_Normal;
	viewNormal = dot(n, n) > 0.0001 ? normalize(n) : vec3(0.0, 0.0, 1.0);

#ifdef HS_TERRAIN
	edgeMask = abs(mc_Entity.x - HS_FOLIAGE_ID) < 0.5 ? 0.0 : 1.0;
#endif

#ifdef HS_GLINT
	viewPosition = (gl_ModelViewMatrix * gl_Vertex).xyz;
	isWaterSurface = abs(mc_Entity.x - HS_WATER_ID) < 0.5 ? 1.0 : 0.0;
#endif
}
