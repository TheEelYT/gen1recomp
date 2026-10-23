"""Compile the GBA renderer shaders with vitaGL's swizzle macro aliases.

Run from the repo root:
  python -m pip install moderngl glcontext
  python tests/vita_ppu_shader_compile_test.py

Uses Mesa/EGL on Linux; no ROM or VitaSDK required. This checks shader language
compatibility, not the Vita's native shader compiler or hardware rendering.
"""
import pathlib
import re
import unittest

try:
    import moderngl
except ImportError:
    moderngl = None


# vitaGL/source/shaders/glsl_translator_hdr.h defines these before compiling
# the translated shader. Test the same token substitutions using a real GLSL
# compiler so parameter/local name collisions are diagnosed semantically.
ALIASES = """\
#define s x
#define t y
#define st xy
#define ts yx
#define ss xx
#define tt yy
"""
VERTEX = """\
#version 330
in vec2 position;
void main() { gl_Position = vec4(position, 0.0, 1.0); }
"""
PRELUDE = """\
#version 330
#define extern uniform
#define Image sampler2D
#define Texel texture
out vec4 fragmentColor;
"""
FOOTER = """\
uniform sampler2D MainTex;
void main() {
  fragmentColor = effect(vec4(1.0), MainTex, vec2(0.0), gl_FragCoord.xy);
}
"""


@unittest.skipUnless(moderngl, "requires moderngl and glcontext")
class VitaPpuShaders(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ctx = moderngl.create_standalone_context(backend="egl")
        root = pathlib.Path(__file__).resolve().parents[1]
        source = (root / "src/core/game3/gba_ppu.lua").read_text()
        cls.shaders = dict(re.findall(
            r"local (\w+_SHADER) = \[\[(.*?)\]\]", source, re.S))

    @classmethod
    def tearDownClass(cls):
        cls.ctx.release()

    def compile(self, source, aliases=""):
        return self.ctx.program(
            vertex_shader=VERTEX,
            fragment_shader=PRELUDE + aliases + source + FOOTER)

    def test_all_ppu_stages_compile(self):
        self.assertEqual(set(self.shaders),
                         {"BG_SHADER", "OBJ_SHADER", "COMPOSE_SHADER"})
        for name, source in self.shaders.items():
            for aliases in ("", ALIASES):
                with self.subTest(stage=name, vita=bool(aliases)):
                    self.compile(source, aliases).release()

    def test_original_texture_parameter_collision_is_reproduced(self):
        source = """\
vec4 effect(vec4 color, Image t, vec2 tc, vec2 sc) {
  float y = floor(sc.y);
  return vec4(y / 160.0);
}
"""
        self.compile(source).release()
        with self.assertRaises(moderngl.Error):
            self.compile(source, ALIASES)


if __name__ == "__main__":
    unittest.main(verbosity=2)
