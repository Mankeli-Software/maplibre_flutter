// Shim for Emscripten, which ships <GLES2/gl2ext.h> + <GLES3/gl3.h> but not
// <GLES3/gl3ext.h> (the Khronos gl3ext.h is just a placeholder that pulls in the
// ES2 extension interfaces). mbgl's gl_functions.cpp includes <GLES3/gl3ext.h>;
// this redirect lets it compile under the Emscripten sysroot. Placed on a private
// include path ahead of the sysroot in the web CMake build.
#ifndef MBL_WEB_GLES3_GL3EXT_H
#define MBL_WEB_GLES3_GL3EXT_H
#include <GLES2/gl2ext.h>
#endif
