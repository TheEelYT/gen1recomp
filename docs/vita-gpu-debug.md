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
