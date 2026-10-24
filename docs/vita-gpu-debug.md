# Vita GPU hang diagnostics

The optional GBA renderer trace is enabled by `ux0:/data/vita-gpu-debug.txt`.
It is disabled when that file is absent. Its contents select one mode:

- `trace`: log render passes and flush LOVE's batched draws.
- `sync`: also read one pixel from each completed render target, waiting for its GPU
  work before proceeding. This slows rendering and changes scheduling. It is
  a diagnostic mode, not a permanent rendering fix.

The trace writes `ux0:/data/g1r-render-0.txt` and `g1r-render-1.txt`.
The files alternate in 120-frame chunks, bounding storage while keeping the
current and preceding chunks. They include Emerald's intro scene/frame/counter,
Lua heap size, LOVE's texture memory/count, and checkpoints before/after command
submission and GPU readback, plus layer filenames/sizes when assets load between
frames. These are not measurements of free system memory.
Unsupported readback is logged and switches the session to `trace` mode.
Checkpoints finish at the offscreen GBA composition; they do not prove the final
scaled image reached the physical display.

After a crash, copy both render logs and the usual `g1r-gfx.txt`, `g1r-mem.txt`,
`g1r-frames.txt`, and GPU dump before relaunching. Remove the marker to return
to normal rendering. Updating this Lua code requires repackaging the game,
but does not require a new native runtime or an Emerald re-import.

The October 23 GPU dump was an incomplete gzip containing 19,341 decompressed
bytes. It includes thread records and part of the CPU register records, but
ends before GPU command/state data. No CPU exception was recorded; the main
thread was stopped inside the graphics stack. All three GBA shaders linked
successfully in the accompanying log. The memory log is a startup snapshot,
and the frame log records stalls, not the intro's active scene. Those files
alone do not establish the failing GPU draw or an out-of-memory diagnosis.

The subsequent sync run completed all copyright passes for 59 render frames,
then reported `Out of memory` during composition readback at frame 60. It
downgraded to trace mode; the first scene's `scene1_bg3` PNG then failed decoding
and the error handler's font allocation failed too. That run does not isolate
the earlier GPU hang. Sync probes now request one pixel (four RGBA8 bytes),
instead of a full 240x160 image (150 KiB), and uncached Vita image loads collect
temporary Lua objects first. This bounds the requested readback image size; it
does not prove the native driver has no additional allocations or leaks.

The October 24 sync and trace runs both reached scene 3, counter 6 (render
frame 1139), immediately after loading `scene3_pokeball_idx.png`. Sync reported
no readback failures and completed the affine BG2 read before the last object
checkpoint. Trace completed that frame's offscreen composition before the GPU
abort. Both dumps are complete gzip streams and contain GPU_INFO records;
their TTY output reports `render gpu crash`, with no Lua error. GPU execution is
asynchronous: these checkpoints do not identify the exact faulting command.

The next compatibility candidate removes per-pixel early returns before the
background shader's texture lookups. Non-wrapped affine coordinates are clamped
for sampling, then masked transparent when originally outside the layer. Index
zero and 4-bit palette-bank index zero are also masked instead of returning.
This is a workaround candidate for the rotating background's shader path, not
a confirmed diagnosis of the native driver. The optional Mesa/EGL test compares
all 240x160 output pixels with a CPU sampler for the initial Pokeball matrices,
wrapping/boundary cases, 4-/8-bit transparency, and horizontal/vertical scanline
offsets, with and without vitaGL's swizzle macros. It does not emulate ShaccCg
or Vita GPU execution.

New traces identify this candidate with `bgSampling=bounded-v1` and record
each affine matrix, reference coordinate and wrapping flag before the draw.
Keep the marker on `trace` for the next hardware comparison.

With `bounded-v1` on hardware, Emerald reached its title, completed the Birch
sequence, entered the world and saved. The next native guard/logger build also
allowed continued play. Its compiler log identifies the field-weather failure:
ShaccCg rejects `row` as a keyword at the uniform declaration and its use. The
shader uniform and its Lua upload are now named `weatherRow`; the native guard
remains useful for any future compilation failures.

Returning to the launcher also entered `LauncherWindow.activate`, which applies
desktop window preferences with `love.window.setMode`. Vita reports Linux, so
the OS-name check admitted it to that path. `VideoMode.fixedDisplay` and
`FaithfulRes.fixedDisplay` now honor `POKEPORT_VITA`, preventing launcher window
restoration, fullscreen toggles and desktop resolution changes on the panel.
The exit dump is a CPU data abort in SceLibKernel. The old uploaded ELF predates
the native rebuild, so exact symbolization of that dump still needs the matching
`vendor/love-vita/src/love` if the exit failure persists after this change.

## CPU load pauses

The October 24 frame log records multi-second stalls during gameplay, but lacks
operation labels. They are not established as GC, decoding, uploads or shader
compilation by those timings alone.

Vita now writes `ux0:/data/g1r-loads.txt` for warm-job slices, weather asset/shader
setup, GC steps and asset decode/upload timings of at least 50 ms. Each entry records the key,
phase, elapsed time, route (`worker`, synchronous or warm upload), timestamp and
Lua heap size. Worker decode time is CPU work measured on that worker; it does
not by itself mean the render thread stalled for that duration. A forced
synchronous asset demand is identified separately.

This diagnostic runs independently of the GPU marker, adds no graphics calls,
and performs file IO only after a slow operation. It retains at most 512 entries
in a process and limits key length. The first slow event replaces the preceding
process's log; absent new slow events, an old file can remain. It covers these
load paths, not every possible source of a stalled frame. Keep GPU tracing off
for the next gameplay comparison and copy this log after reproducing a pause.

Returning to the launcher succeeded on hardware after the fixed-display change.
Closing the app's X still faults. The matching `love(3)` ELF resolves its stack
to `lua_close` -> userdata/font destruction -> Image destruction ->
`OpenGL::deleteTexture` -> `gpu_free_texture_data`, then a SceLibKernel data abort.
This identifies the failing cleanup path, not the origin of the invalid memory.
The next candidate calls `love.window.close()` after process shutdown hooks,
before Lua finalization. That invokes LOVE's graphics/volatile unload while
Lua-owned images and fonts still exist. `g1r-shutdown.txt` records completion of
render-state detachment and explicit window closure. It does not bypass saving,
worker shutdown or the normal Lua-state destruction. Hardware validation remains
required; the change is a shutdown-order candidate, not a confirmed allocator fix.

Pauses on every new area and intro/title scene also require timings outside the
asset queue. `VitaLoadTrace.install()` wraps main-state LOVE file reads, image
decodes/uploads and shader creation, preserving argument/result counts. Slow
full GC before PPU images and indexed-PNG preparation are logged separately.
These supplement the earlier queue/GC timings; they do not remove load work or
claim to resolve the pauses. GPU tracing can remain disabled.

## Measured transition stalls and the next close test

The subsequent full-intro/walking run records 42 pre-image full collections,
about 63.6 seconds combined. Most scan the same ~92 MiB live heap for ~1.45 s
without reclaiming appreciable memory. The earlier unconditional allocation
safeguard is therefore itself a source of scene-loading pauses. PPU cache misses
now advance one incremental step, release temporary ImageData handles explicitly,
and perform a full collection only for one allocation-error retry. Corrupt asset
errors still propagate without retry. Indexed-PNG uploads release their temporary
handle on failure as well as success.

The log also records first-use shader compilation (~0.25–5.2 s), including
recompilation of the three PPU programs on a later renderer instance. Vita PPU
instances now share those three programs, with uniforms supplied on each draw;
canvases, palette and scanline data remain instance-owned. This removes repeated
program creation, not the initial compile. The synchronous tileset preparations
(4.38 s and 0.70 s) and other IO/worker timings are separate remaining work; worker
CPU durations alone do not establish a main-thread stall.

The new close dump (`1792880736`, matching `love(3)`) faults in the same native
texture-free path, now through `Window::close` → `Volatile::unloadAll` →
`Font::unloadVolatile`. Explicit window closure is removed. Only after actual
application shutdown hooks, Lua sets `G1R_VITA_SHUTDOWN_READY`; the incremental
native `love-vita-process-exit.patch` in the port repository honors this on real
quit by finishing GPU work, flushing C streams and exiting the process. The OS
reclaims process resources without traversing the failing graphics finalizers.
Returning to launcher and native restarts do not take that exit path. This is a
workaround for process close, not a repair of the invalid free's origin.

**This test requires a native runtime rebuild as well as repackaging.** The port's
existing `scripts/rebuild_shader_diagnostics.sh` now applies both incremental
patches without resetting local source or configure/heap settings. Do not apply
the full LOVE patch again. No cache deletion or ROM re-import is needed. Keep
GPU tracing disabled, repeat the intro/building/save/exit test, and copy
`g1r-loads.txt` and `g1r-shutdown.txt`. Native completion is recorded as
`native GPU finish complete; exiting process`. A new crash also needs the dump
and the newly rebuilt `vendor/love-vita/src/love` symbol file. Host control-flow,
allocation/error-path and Gen3 tests pass; device results remain unverified.

## Rollback after device performance regression

The `cd1bbd3a` optimization candidate regressed Emerald's intro on hardware;
the user could not reach the title because execution was too slow. Host tests
validated control flow and ownership stubs, not device performance. No new timing
log accompanies that report, so it does not identify which change caused the
regression.

Restore `gba_ppu.lua`, `indexed_png.lua` and the image-GC regression test exactly
to the playable `b9eadd02` versions. This restores per-image full collection,
the original image creation/ownership path and per-instance shader programs as
one conservative rollback. The known transition pauses remain; the preceding
optimization description is a failed candidate, not current runtime behavior.
Keep the independent application-close workaround and its native rebuild. The
native process-exit gate only runs after the boot coroutine returns a flagged
real quit, and is not reverted by this Lua-only change.

Repackage with the already rebuilt runtime; no native rebuild or ROM re-import
is needed for this rollback. Confirm the previous playable speed first, keeping
GPU tracing off. Copy `g1r-loads.txt` from the slow build before launching again
if it is still available, since the next run can replace it. That comparison is
needed before attempting another GC/image/shader performance change.
