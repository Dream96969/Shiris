#version 330 compatibility

/* DRAWBUFFERS:0 */

in vec4 glcolor;

void main() {
	gl_FragData[0] = glcolor;
}
