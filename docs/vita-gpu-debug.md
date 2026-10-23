# Vita GPU hang diagnostics

The optional GBA renderer trace is enabled by `ux0:/data/vita-gpu-debug.txt`.
It is disabled when that file is absent. Its contents select one mode:

- `trace`: log render passes and flush LOVE's batched draws.
- `sync`: also read back each completed render target, waiting for its GPU
  work before proceeding. This slows rendering and changes scheduling. It is
  a diagnostic mode, not a permanent rendering fix.

The trace writes `ux0:/data/g1r-render-0.txt` and `g1r-render-1.txt`.
The files alternate in 120-frame chunks, bounding storage while keeping the
current and preceding chunks. They include Emerald's intro scene/frame/counter,
Lua heap size, LOVE's texture memory/count, and checkpoints before/after command
submission and GPU readback. These are not measurements of free system memory.
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
