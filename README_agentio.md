# AgentIO

AgentIO builds [llama.cpp + TurboQuant](https://github.com/TheTom/llama-cpp-turboquant),
manages local GGUF models, and runs one selected model as a user systemd
service. Configuration is persistent, so normal use is simply:

```bash
agentio start
agentio stop
```

TurboQuant is a work-in-progress llama.cpp fork. It remains compatible with
ordinary GGUF models and adds opt-in TurboQuant KV-cache and weight formats.
AgentIO tracks the fork's `feature/turboquant-kv-cache` branch.

## Install or migrate

```bash
chmod +x agentio.sh
./agentio.sh install
```

This installs `/usr/local/bin/agentio`, clones the TurboQuant fork into
`~/.agentio/llama.cpp`, and builds `llama-server` with CUDA when `nvcc` is
available. Without CUDA it builds the CPU backend.

If an older AgentIO install has upstream llama.cpp in that directory,
`agentio update` changes its origin and cleanly switches it to the TurboQuant
branch. Migration stops instead of overwriting local changes inside the
llama.cpp checkout.

## Quick start

```bash
agentio download \
  https://huggingface.co/example/model/resolve/main/model.Q4_K_M.gguf \
  model.Q4_K_M.gguf

agentio settings set model model.Q4_K_M.gguf
agentio settings preset quality
agentio start
```

Use `quality` for the first run of an unfamiliar model. If its output looks
healthy, `balanced` is the recommended everyday preset.

Downloads are resumable and remain as `.part` files until complete. Models may
be kept in subdirectories and filenames may contain spaces:

```bash
agentio list
agentio start path/to/model.gguf
```

Passing a model to `start` also selects it for future starts.

## Optimization presets

List the presets from the command line:

```bash
agentio settings presets
agentio settings preset balanced
```

| Preset | TurboQuant KV cache (K / V) | Other behavior | Use when |
|---|---|---|---|
| `quality` | `f16` / `turbo4` | Automatic context and GPU fit | Safest first contact with a new or quant-sensitive model |
| `balanced` | `q8_0` / `turbo3` | Automatic context and GPU fit | Recommended general-purpose default; usually 3–4× less total KV memory than `f16` / `f16` |
| `memory` | `q8_0` / `turbo2` | Smaller prompt batches | Long context or memory pressure, after checking model quality |
| `throughput` | `q8_0` / `turbo3` | Four slots, larger physical batch, unified KV | Concurrent server requests on hardware with enough memory |
| `low-vram` | `q8_0` / `turbo2` | Small batches, 512 MiB device fit margin | Squeezing a model onto a small GPU |
| `cpu` | `q8_0` / `turbo3` | No GPU layers, smaller batches | CPU-only inference |

Aliases are `safe` for `quality` and `aggressive` for `memory`.

All presets begin from a complete baseline, so switching presets does not leave
stale tuning from the previous one. They preserve the selected model, listen
address, API key, and arbitrary extra flags. Changing an optimization setting
after applying a preset labels the configuration `custom`.

### Why K and V use different formats

TurboQuant's guidance is to keep the K cache at higher precision than V. K is
more sensitive to compression; symmetric low-bit K/V is not a safe general
default. V compression progresses from least to most aggressive:

| V format | Approximate bits/value | Guidance |
|---|---:|---|
| `turbo4` | 4.5 | Safest TurboQuant starting point |
| `turbo3` | 3.5 | Recommended balance of fidelity and memory |
| `turbo2` | 2.0 | Most aggressive; validate each model |

Selecting `turbo2` for V automatically enables the fork's layer-aware Boundary
V protection. Flash Attention is left on `auto`, allowing the fork to select a
supported TurboQuant kernel. If quality drops, move back one step; there is no
single best compression level for every dense, MoE, or instruction-tuned
model.

### Automatic fit

Presets set `ctx_size=auto`, `gpu_layers=auto`, and `fit=on`. AgentIO omits the
explicit context and GPU-layer arguments in this mode, allowing the fork to:

1. read the model's maximum context;
2. keep the requested free-memory margin on each device;
3. reduce context no lower than `fit_ctx` when necessary; and
4. choose how many model layers fit on the accelerator.

Set a fixed value only when that is intentional:

```bash
agentio settings set ctx_size 32768
agentio settings set gpu_layers all
agentio settings set fit_target 2048
```

## Settings and accepted values

The CLI contains the full reference and can show one setting at a time:

```bash
agentio settings describe
agentio settings describe cache_type_v
agentio settings set cache_type_v turbo4
agentio settings unset cache_type_v
```

`unset` restores that setting's balanced default. `settings reset` restores all
optimization settings to `balanced` while preserving model and server access
configuration.

### Model and HTTP server

| Setting | Accepted values | Description |
|---|---|---|
| `model` | Downloaded `.gguf` name or relative path | Selected model |
| `host` | IP address or hostname | Listen address; `127.0.0.1` is local-only, `0.0.0.0` listens on every interface |
| `port` | `1..65535` | HTTP port |
| `api_key` | Any string; empty disables | Bearer key, stored in a mode-600 file and hidden from settings output |
| `threads_http` | `0` or integer ≥ 1 | HTTP processing threads; `0` uses the fork default |

### Context, batching, and TurboQuant cache

| Setting | Accepted values | Description |
|---|---|---|
| `ctx_size` | `auto` or integer ≥ 1 | Total context; `auto` starts from model metadata and permits fitting |
| `batch_size` | Integer ≥ 1; ≥ 32 recommended | Logical prompt batch; larger can improve prefill at a memory cost |
| `ubatch_size` | `1..batch_size`; ≥ 32 recommended | Physical prompt batch; lower first when compute buffers do not fit |
| `parallel` | `-1` automatic or integer ≥ 1 | Concurrent server slots; more slots consume more KV memory |
| `flash_attn` | `auto`, `on`, `off` | Flash Attention policy; `auto` is recommended for portability |
| `cache_type_k` | `f32`, `f16`, `bf16`, `q8_0`, `q5_0`, `q5_1`, `q4_0`, `q4_1`, `iq4_nl`, `turbo4`, `turbo3`, `turbo2` | K-cache storage; prefer `f16` or `q8_0` without model-specific testing |
| `cache_type_v` | Same values as K | V-cache storage; TurboQuant recommends `turbo4` → `turbo3` → `turbo2` as confidence increases |
| `cont_batching` | `on`, `off` | Insert new requests while others decode |
| `kv_unified` | `on`, `off` | Share one KV buffer across sequences |
| `swa_full` | `on`, `off` | Full-size sliding-window cache; potentially large memory increase |
| `kv_offload` | `on`, `off` | Keep KV on an accelerator when possible; disabling saves VRAM but is slower |

### Model placement and loading

| Setting | Accepted values | Description |
|---|---|---|
| `gpu_layers` | `auto`, `all`, or integer ≥ 0 | Accelerator layer count; `auto` enables fit, `0` is CPU-only |
| `split_mode` | `none`, `layer`, `row`, `tensor` | Multi-GPU split; `tensor` is experimental |
| `tensor_split` | Empty or proportions such as `3,1` | Relative model allocation across GPUs |
| `main_gpu` | Integer ≥ 0 | Primary GPU for `none`, or intermediate/KV work for `row` |
| `device` | Empty or comma-separated device names | Restrict offload devices; list names with `agentio settings devices` |
| `mmap` | `on`, `off` | Memory-map weights for faster loading and shared OS page cache |
| `mlock` | `on`, `off` | Prevent model pages from swapping; needs adequate RAM and process limits |
| `direct_io` | `on`, `off` | Bypass OS file cache where supported; normally leave off |
| `repack` | `on`, `off` | Enable faster backend-specific runtime weight layouts |
| `host_buffer` | `on`, `off` | Normal staging buffer; off is an advanced `--no-host` path |
| `op_offload` | `on`, `off` | Offload eligible host operations to an accelerator |
| `cpu_moe` | `on`, `off` | Keep every MoE expert tensor on CPU to save VRAM |
| `n_cpu_moe` | Integer ≥ 0 | Keep expert tensors for the first N MoE layers on CPU |
| `numa` | `disabled`, `distribute`, `isolate`, `numactl` | NUMA placement; disabled is right for ordinary single-socket systems |

`split_mode=tensor` currently requires both cache types to be `f32`, `f16`, or
`bf16`; quantized KV cache is rejected before restart. The default `layer` mode
supports TurboQuant cache formats.

### Automatic memory fitting and prompt cache

| Setting | Accepted values | Description |
|---|---|---|
| `fit` | `on`, `off` | Adapt automatic context and GPU placement to available memory |
| `fit_target` | MiB, or comma-separated MiB per device | Free-memory margin retained on each accelerator |
| `fit_ctx` | Integer ≥ 0 | Smallest context automatic fitting may choose |
| `cache_ram` | `-1` unlimited, `0` off, or positive MiB | RAM budget for reusable prompt entries, separate from active KV |
| `cache_idle_slots` | `on`, `off` | Move idle slots into prompt cache; requires `cache_ram` |
| `cache_prompt` | `on`, `off` | Reuse matching prompt prefixes |
| `cache_reuse` | `0` off or integer tokens ≥ 1 | Minimum matching chunk for KV-shift reuse; requires prompt caching |

### CPU scheduling and diagnostics

| Setting | Accepted values | Description |
|---|---|---|
| `threads` | `0` or integer ≥ 1 | CPU generation threads; `0` uses automatic hardware detection |
| `threads_batch` | `0` or integer ≥ 1 | Prompt/batch threads; `0` inherits automatic behavior |
| `poll` | `0..100` | Worker polling level; higher reduces wake latency but uses more idle CPU |
| `cpu_mask` | Empty or hexadecimal mask | Generation CPU affinity; alternative to `cpu_range` |
| `cpu_range` | Empty or `lo-hi`, such as `0-7` | Generation CPU affinity range |
| `cpu_strict` | `on`, `off` | Enforce generation affinity strictly |
| `priority` | `-1` low, `0` normal, `1` medium, `2` high, `3` realtime | Generation scheduling priority |
| `cpu_mask_batch` | Empty/inherit or hexadecimal mask | Prompt/batch CPU affinity mask |
| `cpu_range_batch` | Empty/inherit or `lo-hi` | Prompt/batch CPU affinity range |
| `cpu_strict_batch` | `auto`/inherit, `on`, `off` | Prompt/batch strict-affinity policy |
| `priority_batch` | Empty/inherit or `0..3` | Prompt/batch priority |
| `poll_batch` | Empty/inherit, `0`, `1` | Prompt/batch polling policy |
| `perf` | `on`, `off` | Internal libllama timing counters; small measurement overhead |
| `defrag_thold` | Empty recommended or number | Deprecated no-op retained for compatibility with old configs |

High and realtime priorities may require additional privileges and can make the
desktop less responsive.

## Arbitrary llama-server flags

TurboQuant and llama.cpp evolve quickly. AgentIO exposes the installed binary's
authoritative help and preserves arbitrary arguments that do not yet have named
settings:

```bash
agentio settings flags
agentio settings extra set --metrics --no-webui
agentio settings extra add --some-new-flag value
agentio settings extra clear
```

Pass each token as a separate shell argument. Named settings are emitted first,
so extra arguments should not duplicate them.

## TurboQuant weight formats

The fork also adds offline `TQ4_1S` and `TQ3_1S` model weight quantization. This
is separate from the runtime KV-cache presets. AgentIO accepts a model already
in its models directory and writes the result there safely through a `.part`
file:

```bash
agentio quantize model.f16.gguf model.tq4_1s.gguf tq4
agentio quantize model.f16.gguf model.tq3_1s.gguf tq3
```

`TQ4_1S` is the safer weight format and has supported accelerator kernels, with
the strongest documented speedup on CUDA. `TQ3_1S` is smaller with a larger
expected quality loss. Quantize from a high-precision source and test the
converted model; KV presets work with ordinary GGUF weight formats and do not
require conversion.

## Service commands and files

```bash
agentio start
agentio status
agentio logs
agentio stop
```

The default endpoint is `http://127.0.0.1:8080`. Settings live in
`~/.config/agentio/settings.conf`; the generated launcher and user systemd unit
are regenerated whenever configuration changes. A running service is restarted
automatically. Stopped services receive the new settings on the next start.
