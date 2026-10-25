# Vita audio memory reduction

This follows the playable `a96fc6cb` rollback. The per-image full collection,
original image ownership and per-instance shader lifetime remain exactly at
that baseline. The native process-exit workaround also remains unchanged.

## Changes

- A newly started M4A worker previously received two identical install commands:
  one from `ensure_worker` and one from `Audio.install`. It now receives one.
  Explicit reinstalls on an existing worker still send one install each.
- On Vita, the standard Dataset cache reads the raw `samples.bin` directly as
  LOVE FileData using the exact active cartridge prefix. This avoids first
  copying the full native file buffer into a Lua string.
- The install message passes that same reference-counted Data object to the
  audio worker. LOVE Variant/Channel object messages retain the object rather
  than cloning its payload. The worker loads its own metadata but does not read
  another complete sample bank.
- `Sample.loadPcm` uses a DataView to copy only the requested instrument's PCM
  string. It never calls `getString` on the full bank. The mixer, sample rate,
  buffer sizes and sample bytes are unchanged.
- Vita session end sends `uninstall` so the worker drops its pack, voices,
  snapshots, pending fanfare bake and queued outputs. It collects retired
  objects before loading the next pack, and loader temporaries once after each
  install. These collections run in the worker, not on every game image load.

Custom caches, explicit cache roots, portable roots and runtimes without the
required Data API use the existing string-backed reader. Desktop packs keep
that representation by default. There is no extraction format change.

## Validation

`tests/engine/vita_audio_bank_test.lua` checks byte-equivalent PCM slices,
bounds, temporary DataView release, identical stereo mixing, one shared bank
per pair of packs, string fallbacks and Emerald/FireRed cache namespaces.
`game3_m4a_worker_prefix_test.lua` checks one install per request, shared-bank
messages, worker replacement across cartridges, release on uninstall and the
existing missing-pack/synchronous fallback paths.

The optional native host check compiles LOVE's actual FileData, DataView,
Variant and reference-counted Object implementations, then uses a real host
thread to read sample slices after the sender releases its bank:

```sh
python tests/vita_audio_bank_native_test.py
# To check the source tree matching the Vita runtime:
python tests/vita_audio_bank_native_test.py --love-src /path/to/love-vita/src
```

On this Linux host, both bundled LOVE and the Vita LOVE base sources passed.
For a **synthetic 16 MiB bank**, two copied banks occupy 32 MiB; the shared bank
occupies 16 MiB. Process peak RSS was approximately 33.5 MiB versus 17.6 MiB in those runs.
These are host measurements of the native ownership path, not Emerald's bank
size, the complete Channel/Lua runtime, or Vita performance. The complete Gen3
test group also passes; ROM/cache-dependent cases skip without those inputs.

## Device check

Update the engine standard checkout and repackage with the already rebuilt
runtime. No native rebuild, cache deletion or ROM re-import is required.
Keep GPU tracing disabled. From a fresh G1R launch, play Emerald through the
intro, continue the save, enter buildings, play a short battle with sound and
return to the launcher. Also switch between FireRed and Emerald to check pack
replacement. The original transition pauses are still expected at this stage.

Copy `ux0:/data/g1r-audio.txt` and `g1r-loads.txt`. The audio report's first
successful main install replaces the previous log; worker acknowledgments are
appended when the main loop pumps them. Look for `shared=true` in both
`main-installed` and `worker-installed`, and `bankBytes` for the actual bank
size. `mainLuaKiB` and `workerLuaKiB` are per-state Lua counts; the native shared
bank and other native allocations are excluded. A lower Lua count alone is
not a measurement of lower total process RAM.

Hardware memory pressure, audio continuity and performance still require the
device test. Metadata tables, pixel tables, shader startup and transition GC
remain separate optimization targets.

## Image collection experiment withdrawn after device crash

Engine `3565d7f6` retained the first pre-image full collection but delayed later
collections until 4 MiB of Lua growth or estimated image activity. The device's
`g1r-loads(4).txt` confirms that policy ran: `full/startup` takes 2402.5 ms and
`full/image-budget` takes 1474.9 ms. Those are the only logged pre-image scans
before the log ends at 109.672 s. This is a shorter session than the previous
log, so the totals are not a like-for-like performance comparison.

The run loads the player's house tileset, weather shaders, fonts and field
prewarm jobs. The final logged job is `data:mon_anim`; a slow-call log records
completed operations, so this does not identify the crashing operation or
establish how much later the crash happened. The audio report again confirms
one shared 3,900,201-byte bank and a worker acknowledgment. It contains no
reported allocation failure.

Dump `1792898060` records a main-thread CPU data abort (`0x30004`), PC
`0xe0011a8c` in SceLibKernel, fault address `0x4`. The audio worker is not the
faulting thread. The app RX mapping is `0x8100c000` with size `0x6bb378`.
Stack evidence is consistent with texture deletion from an Image released by
a Shader finalizer during ordinary Lua garbage collection, rather than native
`lua_close`. This resembles the earlier graphics allocator fault, but its
origin (including possible prior corruption) is not established. The existing
`love(3)` ELF predates the native process-exit patch and has a different code
size; its addresses must not be treated as exact symbols for this dump. The
rebuilt runtime's `vendor/love-vita/src/love` ELF is needed for an exact trace.

Withdraw the collection-frequency experiment as a precaution. Restore
`gba_ppu.lua` byte-for-byte to the playable `f831c196` version: full cleanup
before every uncached layer or sheet, no cleanup on image cache hits. Remove
the unused budget module, its policy tests and synthetic benchmark. Extend the
existing weak-reference test to cover subsequent uncached images as well as
the first one. Audio sharing, shaders, image ownership and the native app-close
workaround are unchanged. This rollback does not fix the allocator's underlying
fault or establish that collection frequency caused it. Loading pauses remain
an open issue; retain the conservative policy while investigating native frees.

Repackage with the existing runtime; no native rebuild or ROM re-import is
needed for this rollback. Preserve the current dump and send the matching
`B:\gen1recomp-vita\vendor\love-vita\src\love` file for native analysis. A
new crash reproduction is not required just to obtain that file.
