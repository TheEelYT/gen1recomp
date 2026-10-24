"""Compile the GBA renderer shaders with vitaGL's swizzle macro aliases.

Run from the repo root:
  python -m pip install moderngl glcontext
  python tests/vita_ppu_shader_compile_test.py

Uses Mesa/EGL on Linux; no ROM or VitaSDK required. This checks shader language
compatibility, not the Vita's native shader compiler or hardware rendering.
"""
import pathlib
import re
import math
import struct
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

    def test_weather_stages_compile_with_vita_aliases(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        source = (root / "src/core/game3/field_weather_rse.lua").read_text()
        stages = re.findall(r"local (\w+_SHADER) = \[\[(.*?)\]\]", source, re.S)
        self.assertEqual(len(stages), 3)
        for name, shader in stages:
            # Unlike desktop GLSL, the device's ShaccCg rejects this keyword
            # (captured g1r-shaders.txt, line 234, during world entry).
            self.assertNotRegex(shader, r"\brow\b")
            for aliases in ("", ALIASES):
                with self.subTest(stage=name, vita=bool(aliases)):
                    self.compile(shader, aliases).release()

    def test_background_pixels_match_fixed_point_sampler(self):
        # Exercise actual GPU shader output, including the Emerald Pokeball's
        # first eight affine matrices. No ROM assets or native Vita SDK needed.
        matrices = [
            (0, 0, 0, 0, 32768, 32768),
            (-32138, 6392, -6392, -32138, 3377955, 3370964),
            (10451, -3170, 3170, 10451, -967797, -1183826),
            (5045, -2089, 2089, 5045, -405482, -621636),
            (2889, -1544, 1544, 2889, -190389, -383681),
            (1815, -1213, 1213, 1815, -88074, -258110),
            (1205, -989, 989, 1205, -32767, -182462),
            (827, -827, 827, 827, -324, -132695),
        ]
        w = h = 256
        width, height = 240, 160
        indices = bytes((x * 3 + y * 17) % 256
                        for y in range(h) for x in range(w))
        palette = [bytes((i, (i * 7) % 256, 255 - i, 255))
                   for i in range(256)]
        index_tex = self.ctx.texture((w, h), 4,
            b"".join(bytes((i, i, i, 255)) for i in indices))
        pal_tex = self.ctx.texture((256, 2), 4, b"".join(palette) * 2)
        line_tex = self.ctx.texture((160, 1), 4,
            b"".join(bytes((y * 3 % 256, y * 3 // 256, 0, 255))
                     for y in range(160)))
        output = self.ctx.texture((width, height), 4)
        fbo = self.ctx.framebuffer([output])
        vertices = self.ctx.buffer(struct.pack("8f", -1, -1, 1, -1, -1, 1, 1, 1))
        resources = [index_tex, pal_tex, line_tex, output, fbo, vertices]
        try:
            for unit, texture in enumerate((index_tex, pal_tex, line_tex)):
                texture.filter = (moderngl.NEAREST, moderngl.NEAREST)
                texture.repeat_x = texture.repeat_y = False
                texture.use(unit)
            fbo.use()
            self.ctx.viewport = (0, 0, width, height)
            self.ctx.disable(moderngl.BLEND)
            for aliases in ("", ALIASES):
                program = self.compile(self.shaders["BG_SHADER"], aliases)
                vao = self.ctx.simple_vertex_array(program, vertices, "position")
                try:
                    for uniform, value in {
                        "idxTex": 0, "palTex": 1, "lineTex": 2,
                        "texSize": (w, h), "ofs": (253, 251),
                    }.items():
                        program[uniform].value = value
                    cases = [(True, False, 0, matrix) for matrix in matrices]
                    cases += [(True, wrap, 0, (256, 0, 0, 256, -512, -256))
                              for wrap in (False, True)]
                    cases += [(False, True, mode, (256, 0, 0, 256, 0, 0))
                              for mode in (0, 1, 2)]
                    for affine, wrap, mode, matrix in cases:
                        for bpp8 in (False, True):
                            with self.subTest(vita=bool(aliases), affine=affine,
                                              wrap=wrap, lineMode=mode,
                                              matrix=matrix, bpp8=bpp8):
                                a, b, c, d, rx, ry = matrix
                                for uniform, value in {
                                    "affine": float(affine), "wrap": float(wrap),
                                    "bpp8": float(bpp8), "lineMode": float(mode),
                                    "mat": (a, b, c, d), "ref": (rx, ry),
                                }.items():
                                    program[uniform].value = value
                                vao.render(moderngl.TRIANGLE_STRIP)
                                actual = fbo.read(components=4, alignment=1)
                                expected = bytearray()
                                for y in range(height):
                                    for x in range(width):
                                        if affine:
                                            tx = math.floor((rx + a*x + b*y) / 256)
                                            ty = math.floor((ry + c*x + d*y) / 256)
                                        else:
                                            tx = x + (y*3 if mode == 1 else 253)
                                            ty = y + (y*3 if mode == 2 else 251)
                                        visible = wrap or (0 <= tx < w and 0 <= ty < h)
                                        idx = indices[(ty % h)*w + tx % w]
                                        opaque = idx != 0 if bpp8 else idx % 16 != 0
                                        expected.extend(palette[idx] if visible and opaque
                                                        else b"\0\0\0\0")
                                self.assertEqual(actual, expected)
                finally:
                    vao.release()
                    program.release()
        finally:
            for resource in reversed(resources):
                resource.release()


if __name__ == "__main__":
    unittest.main(verbosity=2)
