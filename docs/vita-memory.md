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

## First device result and image collection policy

The uploaded `g1r-audio.txt` confirms the shared path for one Emerald install:
`bankBytes=3900201`, `shared=true` in both main and worker reports. That is about
3.72 MiB of bank storage shared across the two states, not the synthetic 16 MiB
bank used by the host ownership test. The worker reports about 11.5 MiB of Lua
memory after install. These two entries do not establish cartridge-switch or
battle-audio behavior, nor total process RAM.

The same run logs 28 full pre-image collections totaling 42.36 seconds. The
median is 1452 ms. The first collection is needed: it takes 2448 ms and leaves
about 86 MiB of main Lua heap, down from about 134 MiB during game-data loading.
Later collections repeatedly scan essentially the same live heap.

The next candidate changes only PPU image collection frequency. A new PPU or
cleared image cache retains a full collection before its first uncached image.
Afterward, another full scan is triggered by either 4 MiB of Lua growth above
the observed low-water mark or 4 MiB of image activity (width × height × 8,
conservatively allowing RGBA CPU and GPU traffic). This activity budget is a
trigger between image loads, not a measurement of garbage/free memory or a hard
cap on one decoder's peak allocation. Normal/field incremental GC remains active.
An allocation error gets one full collection and one retry; other errors still
propagate immediately. Cache hits do not perform collection work.

Image construction, ownership and shader lifetime remain at the playable
rollback versions. The earlier failed candidate removed the startup full scan
as well as changing image and shader lifetime; those changes are not reinstated.
The audio sharing and native application-close workaround are retained.

`vita_image_budget_test.lua` checks startup cleanup, both thresholds, lowered
heap baselines, cache resets/hits, one-shot recovery and unchanged desktop
behavior. Indexed-sheet timings still exclude GC so diagnostic totals are not
counted twice. The original weak-reference startup-reclamation test still passes.

A host experiment (`luajit tests/vita_image_budget_benchmark.lua baseline|budget`)
keeps about 74 MiB of live Lua data and creates native temporary buffers across
40 image loads. Both policies reclaim 50 MiB of startup garbage before decoding.
The original policy runs 40 full collections; the candidate runs 5. Measured GC
CPU time is 6.49 s versus 0.63 s on this host. Peak native temporaries rise from
0.25 MiB to 2 MiB, and peak Lua heap rises from 73.66 MiB to 74.10 MiB. All native
temporaries are freed at the end. This measures a synthetic host workload, not
Vita frame times, decoder peaks or an actual Emerald asset sequence.

For the next device comparison, repackage the engine with the existing runtime.
No native rebuild or ROM re-import is needed. Keep GPU tracing off and repeat
Emerald's intro/title and a short field session. Copy `g1r-loads.txt` and
`g1r-audio.txt`. Full scans now have routes `full/startup`, `full/lua-growth`,
`full/image-budget` or `full/allocation-retry`. Startup shader compilation and
synchronous tileset decoding remain separate sources of pauses.
