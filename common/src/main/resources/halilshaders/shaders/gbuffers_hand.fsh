#version 330 compatibility

/* DRAWBUFFERS:0123 */

// The first-person hand (and what it holds) is drawn with its depth squeezed to an eighth, so it
// never clips into blocks. The world's inverse projection then puts every hand pixel about a tenth
// of a block from the camera, which the depth based edge glow in composite reads as a huge
// silhouette and draws a bright rim around the hand. The hand must never glow.
#define HS_NO_EDGE_GLOW
#include "/lib/gbuffer_deferred.glsl"
