# ROCm backalley — Release v4.1

**v4.1 is the v4 stack moved onto current llama.cpp, plus one new fix.** Same RX 9070 (gfx1201)
speed-ups, rebased from `73a43d1` (6 Sep) onto **b11325** (`def4d406a`, 1 Oct). There are no new
speed-ups of our own in it: where v4.1 is faster than v4, that is upstream's work since September.

| | v4 | v4.1 |
|---|---|---|
| llama.cpp base | `73a43d1`, 2026-09-06 | **b11325, `def4d406a`, 2026-10-01** |
| patches | 18 | **15** — upstream absorbed 2, and 2 more are no longer needed |
| new | — | a fix for upstream's head-size-192/128 flash-attention errors (from #28102); the MMVQ switch point retuned |

**Who should take it:** anyone on v4 who wants current llama.cpp — newer models, MTP speculative
decoding, upstream's own speed-ups — without losing the RDNA4 gains. And anyone running a
DeepSeek-style model (key head 192, value head 128) on RDNA4: see *The #28102 bug*.

---

## Speed

### Writing speed, one chat

`llama-bench -fa on -p 512 -n 128`, tokens/s, all three builds in one session (2 Oct).

| model | v4 | llama.cpp b11325 | **v4.1** | v4.1 vs v4 | v4.1 vs b11325 |
|---|---|---|---|---|---|
| Qwen3.8-27B IQ4_XS | 31.6 | 34.5 | **35.3** | **+11.8%** | +2.4% |
| Qwen3-Coder-30B-A3B Q3_K_XL | 150.5 | 143.6 | **161.9** | **+7.5%** | +12.7% |
| Qwen3.8-4B-Distill Q4_K_M | 143.3 | 125.1 | **143.7** | +0.3% | +14.9% |
| Qwen3.8-9B-Distill Q4_K_M | 91.3 | 89.9 | **91.6** | +0.3% | +1.9% |
| Qwen3-4B Q4_K_M | 169.0 | 142.4 | **168.8** | −0.2% | +18.5% |
| Qwen3-4B Q4_0 | 168.4 | 164.7 | **167.9** | −0.3% | +1.9% |
| Qwen3-4B IQ4_XS | 175.0 | 157.7 | **175.1** | +0.1% | +11.0% |
| Qwen3-4B Q1_0 | 265.0 | 144.8 | **263.6** | −0.5% | **+82.0%** |
| OLMoE-1B-7B Q4_K_M (MoE) | 379.4 | 287.3 | **377.1** | −0.6% | **+31.2%** |
| gemma-26B IQ4_XS (MoE) | 113.3 | 103.6 | **113.4** | +0.1% | +9.5% |
| RWKV7-1.5B Q4_K_M | 232.7 | 195.4 | **234.2** | +0.6% | +19.8% |

- **v4.1 is never slower than v4** beyond run-to-run noise (worst −0.6%).
- **It is faster than v4 where upstream improved** since September: the 27B +11.8%, Coder-30B +7.5%.
- **Against plain current upstream the stack is still worth +2% to +82%** in writing speed.

Prompt reading (pp512), same session: v4.1 is −0.4% to +7.6% against v4 and +0.3% to +11.9% against
b11325.

**Which build these numbers come from.** v4.1 was settled in two steps: a 17-patch candidate was
measured first, then two head-size-256 patches turned out to add nothing and were dropped (see
*Why the head-size-256 patches went*). The 27B row comes from the 15-patch v4.1 build; the other rows
come from the 17-patch candidate. The two dropped patches only touch the flash-attention kernel that
processes many tokens at once at head size 256, which writing one token at a time never uses. The
27B, measured both ways in the same session, shows it: writing 35.4 vs 35.3 t/s, prompt reading
1,130 vs 1,128 t/s. The two Qwen3.8 Distills share the 27B's architecture and kernel; gemma-26B (head
size 256 on its sliding-window layers) was not measured both ways.

### Several chats at once

From the release gate (5 Oct): Qwen3-4B Q4_K_M, `llama-batched-bench -npp 128 -ntg 64`, writing
speed in tokens/s, summed over all chats.

| chats at once | b11325 | **v4.1** | v4.1 vs b11325 |
|---|---|---|---|
| 1 | 140.5 | **166.1** | +18.2% |
| 2 | 276.1 | **274.3** | −0.6% |
| 3 | 367.1 | **365.2** | −0.5% |
| 4 | 422.1 | **405.4** | −4.0% — noise, see below |
| 5 | 452.7 | **457.5** | +1.1% |
| 6 | 477.4 | **543.4** | +13.8% |
| 8 | 516.4 | **707.3** | **+37.0%** |

The 4-chat cell is noise: one of its three repeats ran slow (11% spread, the most of any cell).
Re-measured 8 times per build, alternating: **420.1 vs 420.5 t/s (−0.1%)** on Qwen3-4B, and **+6.5%**
on Qwen3.8-4B-Distill (359.1 vs 337.1). Prompt reading at 2–8 chats: +7.1% to +9.0%.

### Long context

v4's head-size-128 spill fix carries over and is still needed upstream. The compiler reports
**209 spilled registers** in that flash-attention kernel on b11325, **33 on v4.1** (37 on v4). In v4
this fix was worth +14% prompt reading at 8k of context and +22% at 16k on Qwen3-4B. Long-context
speed was not re-measured for this release.

---

## Quality gate — PASS

Against llama.cpp b11325, same machine, same session (5 Oct), with `scripts/gate3.ps1`, the gate v3
and v4 shipped through.

```
ops         16886 / 16886 passed, 0 failing   (two full runs; b11325 has 16851 - v4.1 supports 35 more cases)
perplexity  9.1132     (b11325: 9.1135)
mean KLD    0.002785   top-1 agreement 97.647%
winogrande  66.67%     (b11325: 67.33% - one task of 150)
batched     npl 1,2,3,4,5,6,8 - no cell below -5% vs b11325
```

| further check | result |
|---|---|
| flash attention only, 12 full runs | **12 / 12 clean**; b11325 fails 4–5 of 12 (see below) |
| Qwen3.8-27B perplexity (± 0.147) | v4 5.6003, b11325 5.6053, **v4.1 5.6064** |

Like v4, v4.1 is **not bit-identical to upstream**: about 2.4% of tokens pick a different top token
(top-1 agreement 97.6%), because the flash-attention changes alter the order of additions.

---

## The #28102 bug, now in upstream

v2 dropped #28102 because it broke flash attention for head sizes 192/128 — key head 192, value head
128, as in DeepSeek-style MLA attention. Upstream merged #28102 on 11 Sep, so b11325 contains it,
and on gfx1201 the bug is still there:

- `FLASH_ATTN_EXT` with `hsk=192, hsv=128, kv_view=1` (shapes `nr23=[16,1]` and `[8,1]`, `kv=512`)
  fails in **4–5 of 12** full `test-backend-ops` runs, with errors of 0.0063–0.0319 against a 0.0005
  limit: 13–64x over. It is intermittent because every run uses fresh random inputs.
- **Cause:** #28102 lets the AMD WMMA flash-attention kernel take head sizes up to 256, including the
  mixed 192/128 case.
- **Fix** (`fix_amd_wmma_dkq_ne_dv.diff`, one condition in `ggml_cuda_get_best_fattn_kernel`): above
  head size 128, the AMD WMMA kernel only takes cases where key and value head sizes match. 192/128
  goes back to the tile kernel, as before #28102. **0 failures in 12 runs.**
- None of our benchmark models use 192/128, so the fix costs nothing we can measure.

---

## What changed in the stack

**Carried over unchanged (10):** #26301, #24386, #25940, #27248, #27269 (with its HIP fix), #23685
(our port), #28398, the Q6_K-always-MMQ fix (v3), and v4's head-size-128 spill fix and IQ
packed-activation layout.

**Adapted to the new base (4):**

| patch | change |
|---|---|
| #25206 (RWKV7) | CUDA/HIP part only; the Vulkan part no longer applies, and Vulkan is out of scope here |
| #26504 (CEIL) | merged with upstream's new BF16 support |
| #28477 (ABS) | keeps upstream's BF16 rule; applied as written it would silently drop BF16 ABS support |
| RDNA4-MMVQ-XOVER (ours) | switch point moved from 3 to 4 tokens; see below |

**New (1):** the #28102 fix above.

**Dropped (4):**

| patch | why |
|---|---|
| #28079, #28552 | merged upstream |
| #26419 + our head-size-256 retune | upstream now has its own head-size-256 kernel on RDNA4, and it is as fast |

### Why the head-size-256 patches went

In v4 these two gave the 27B its long-context gain (+20% prompt reading at 16k over v3). Since then
upstream switched on its own head-size-256 flash-attention kernel for RDNA4 (#28102). On b11325 we
built v4.1 with and without them and measured the 27B in the same session:

| Qwen3.8-27B IQ4_XS | with the two patches | without (v4.1) |
|---|---|---|
| prompt reading (pp512) | 1,130 t/s | 1,128 t/s |
| writing (tg128) | 35.4 t/s | 35.3 t/s |

**Dropping them costs nothing**, and against v4 the 27B is still faster (+3.0% prompt reading, +11.8%
writing) through upstream's own kernel. v4.1 also carries less of its own code in an output-critical
kernel: #26419 would have needed a new guard to stay correct with upstream's new sparse attention.

The spill counts repeat v4's lesson: upstream's head-size-256 kernel spills more than our retune did
(98–234 vs 108–170 across tile shapes) and runs as fast. Spill count is a hint; the benchmark decides.

### The MMVQ switch point, retuned

`RDNA4-MMVQ-XOVER` (ours, since v2) sets the batch width at which matrix-vector kernels (MMVQ) hand
over to matrix-matrix kernels (MMQ) on RDNA4. On the new base the release gate failed the first port
candidate with **−11% writing at 4 chats at once**, using the old switch point of 3. Re-measured at
width 4:

| writing, 4 chats at once | MMQ (switch at 3) | MMVQ (switch at 4) |
|---|---|---|
| Qwen3-4B Q4_K_M | 372 t/s | **417 t/s** |
| Qwen3.8-4B-Distill Q4_K_M | 333 t/s | **361 t/s** |

v4.1 switches at 4.

---

## Known issue, not fixed: MTP with `--spec-draft-n-max 3` on head-size-256 models

Upstream issue [#28867](https://github.com/ggml-org/llama.cpp/issues/28867) (open) reports that since
#28102, speculative decoding with `--spec-draft-n-max 3` loses about 20% on gfx1201 for head-size-256
models such as Qwen3.8-27B: the new dispatch threshold sends small multi-token batches to a kernel
tuned for wide ones. v4.1 uses upstream's head-size-256 path, so it most likely has the same problem.
**Use `--spec-draft-n-max 2`.**

---

## VRAM on a 16 GB card

Qwen3.8-27B stores 260 KB of KV cache per token. When free VRAM runs out, the driver spills the KV
cache to system RAM and writing speed drops by more than 10x. Use `-ctk q8_0 -ctv q8_0` to halve the
cache before that happens.

---

## Required environment (unchanged from v4)

```
set GGML_CUDA_DQ_MMV=1
set GGML_CUDA_DQ_Q6K=1
set HIP_VISIBLE_DEVICES=0
set ROCR_VISIBLE_DEVICES=0
```

Every number above was measured with these set.

## Reproduce

> **AMD only.** These patches are for HIP (ROCm) builds. Built for NVIDIA (CUDA), the patched tree
> aborts in `test-backend-ops` with `CUDA error: misaligned address` in a matrix-multiply kernel
> (RTX 5060 Ti, CUDA 13.3, 6 Oct). Plain upstream b11325 passes the same test (16,875 / 16,875).
> For an NVIDIA card, use upstream llama.cpp.

```bash
git clone https://github.com/Tudor-projs/ROCm-backalley-release
cd ROCm-backalley-release
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp && git checkout def4d406ae2c2f39573120d68730fbb7760b24bf   # b11325

for p in stack_26301 stack_24386 stack_25940 rel_25206 rel_27248 rel_26504 rel_28477 \
         rel_27269_new pr23685_ported cand_RDNA4_MMVQ_XOVER pr28398 fix_Q6K_always_mmq \
         v4_fa_spill v4_packed_q8_1_layout fix_amd_wmma_dkq_ne_dv; do
  git apply ../patches/v4.1/$p.diff || { echo "FAILED: $p"; break; }
done

cmake -S . -B build-hip -G Ninja -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1201 \
  -DCMAKE_C_COMPILER="C:/Program Files/AMD/ROCm/7.2/bin/clang.exe" \
  -DCMAKE_CXX_COMPILER="C:/Program Files/AMD/ROCm/7.2/bin/clang++.exe" \
  -DCMAKE_BUILD_TYPE=Release -DLLAMA_OPENSSL=OFF -DLLAMA_CURL=OFF
cmake --build build-hip --target llama-server llama-bench
```

Applied in this order to a clean b11325 checkout, the 15 patches reproduce the tested source tree
byte for byte (same git tree hash). The order is also in `patches/v4.1/ORDER.txt`. The v1–v4 patches
in `patches/` are unchanged and still target `73a43d1`.

## In the archive

`rocm-backalley-v4.1-gfx1201-win64.zip` is self-contained; no ROCm install is needed. Same layout as
v4: the llama.cpp binaries, the ROCm 7.2 runtime (rocBLAS and hipBLASLt, Tensile libraries filtered to
gfx1201) and the MSVC runtime. New in this archive: `llama-server.exe` and `llama-cli.exe`.

Tested on one machine only: RX 9070, Windows 11, Adrenalin 32.0.31041.1004, ROCm 7.2. Not tested on
9070 XT, 9060, R9700, or Linux. gfx1201 only.
