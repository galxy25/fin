---
id: P003
date: 2026-09-06
occurred: 2026-09-05
kind: PROCESS
title: Local training on Apple Silicon — the serialization rule and the memory contract
status: active
tags: [training, memory, machine-safety, mlx]
sources:
  - 10f00fe — "scripts/dev: one-at-a-time build guard + workflow exhaustion watchdog" (2026-09-06 01:16)
  - scripts/dev/one-at-a-time.sh:6-18
  - "sysctl -n hw.memsize → 34359738368 (32 GB); hw.model → Mac16,3; machdep.cpu.brand_string → Apple M4"
  - "sysctl -n kern.boottime → sec = 1788662156 = 2026-09-05 19:35:56 PDT (the crash reboot)"
  - "local-artifact: models/candidates/fin-foreman-e4b-mlx/launch-train.sh (header: the memory contract)"
  - "memory note machine-safety-serialized-builds (Levi's directive, verbatim)"
related: [E003, E004]
corrects: []
superseded-by: null
---

## Why this protocol exists

On **2026-09-05 at 19:35:56 PDT** the 32 GB M4 iMac hard-crashed and rebooted.
The boot time is the artifact: `sysctl -n kern.boottime` returns
`{ sec = 1788662156 }`, which is that instant.

What was running: parallel `xcodebuild test` runs, an mlx LoRA smoke-train, and
LM Studio serving a 12B model. The header of `scripts/dev/one-at-a-time.sh`
(lines 6-9) records it in the code that came out of it:

> `# Why: 2026-09-05 the iMac (32 GB) hard-crashed under parallel xcodebuild runs`
> `# + an mlx fine-tune + LM Studio serving a 12B model. Levi's standing rule since:`
> `# heavily serialize Xcode/Swift testing, and never let it pile onto training.`

Levi's words at the time, from the memory note `machine-safety-serialized-builds`:
*"for the training run make sure we shut down lm studio ... so we don't have
memory contention and make heavily serialized any xcode testing so we don't
have the computer crashout."*

Collateral damage worth recording: the reboot wiped `/tmp/fin-wt-*` and with it
the smoke-run logs. That loss is why E003's key numbers are UNSOURCED to this
day.

## The hardware, and the number the contract turns on

| fact | value | source |
| --- | --- | --- |
| chip | Apple M4 | `sysctl -n machdep.cpu.brand_string` |
| model | `Mac16,3` (iMac) | `sysctl -n hw.model` |
| unified memory | 34,359,738,368 B = **32 GB** | `sysctl -n hw.memsize` |
| cores | 10 (4 efficiency + 6 performance) | `hw.ncpu`, `hw.perflevel{0,1}.logicalcpu` |
| **Metal max recommended working set** | **24 GB** | device probe, below |
| max Metal buffer length | 18 GB | same probe |
| GPU architecture | `applegpu_g16g` | same probe |

The probe, captured 2026-09-05 19:50:52 PDT (units GB):

```
{'device_name': 'Apple M4', 'max_recommended_working_set_size': 24, 'memory_size': 32,
 'architecture': 'applegpu_g16g', 'max_buffer_length': 18, 'resource_limit': 499000}
```

**24 GB, not 32, is the ceiling.** Everything else in this entry follows from
that: the OS, the window server, LM Studio's resident weights and every Xcode
toolchain process are all drawing on the same pool, and Metal will only
*recommend* 24 GB of it to one process.

## Protocol

1. **Before a training run:** `lms unload --all` and quit LM Studio. Confirm
   with `pgrep -fl "LM Studio|lms"`. Cloud Fin has no brain while this holds;
   reload `google/gemma-4-12b-qat` when the run ends.
2. **Train with the memory contract:**
   `--grad-checkpoint --batch-size 1 --grad-accumulation-steps 2`. Sequence
   length 3072 (2048 would truncate 38% of the corpus; 3072 keeps 100%). The
   measured effect of these flags is E003.
3. **Detach the run** so no session owns it: `nohup sh launch-train.sh &`, with
   `caffeinate -i` inside so the machine does not idle-sleep, and the log
   appended beside the adapter.
4. **Serialize every heavy build** through `scripts/dev/one-at-a-time.sh`
   (`10f00fe`). Never invoke `xcodebuild` directly while a run is live. Before
   `exec`ing its command it, in order (script header, lines 11-18):
   1. takes a machine-wide lock — `$FIN_BUILD_LOCK`, default
      `~/.fin-build.lock`, a `mkdir` lock with a `pid` file, stale locks
      reclaimed via `kill -0` — so two never run at once across sessions and
      worktrees;
   2. waits until no *other* `xcodebuild` / `swift-build` / `swift-test` /
      `swift-package` process is running — "another session's build counts; we
      don't kill it, we wait";
   3. waits until free memory ≥ `$FIN_MIN_FREE_GB` (default **8**), computed
      from free + inactive + speculative pages.

   `FIN_MAX_WAIT_S` defaults to 7200 and it exits 75 if it gives up.
5. **Nothing under `/tmp`.** Worktrees, venvs and training artifacts live under
   the repo or `~/forges`. The reboot is the reason.
6. **Check before starting anything heavy:** `uptime` load and
   `pgrep -f xcodebuild`. Sibling projects run their own tests on this box.

## Measured outcome of following it

The live E4B run (E004) has held **Peak mem 14.978 GB** flat since iteration
375 — 62% of the 24 GB ceiling — for a model 1.87× larger than the one that
OOM'd without the contract. No crash, no thermal stop, 15+ hours in.

## What this does not cover

- **GPU scoring.** `score_bits.py` and `gate_sweep.sh` are also GPU work and
  must not run beside a training run. `gate_sweep.sh` refuses on its own
  (`pgrep -f "mlx_lm lora"`); `score_bits.py` carries the same guard.
- **Disk.** Fused models are ~4-6 GB each. 109 GiB free at last check, and a
  sweep that fused twelve checkpoints without deleting as it goes would eat
  most of it.
- **Thermals and sustained clocks.** Nothing here measures throttling. The
  run's It/sec varies 0.055-0.118 across reports and no entry explains the
  spread.
