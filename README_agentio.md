# AgentIO

AgentIO builds `llama.cpp`, manages downloaded GGUF models, and runs one selected
model as a user systemd service. Its model and performance settings are
persistent, so normal use is simply:

```bash
agentio start
agentio stop
```

## Install

```bash
chmod +x agentio.sh
./agentio.sh install
```

The installer builds the latest `llama.cpp` (with CUDA when detected) and
installs the command as `/usr/local/bin/agentio`.

## Models

Download a model:

```bash
agentio download \
  https://huggingface.co/example/model/resolve/main/model.Q4_K_M.gguf \
  model.Q4_K_M.gguf
```

Downloads are resumable and use a `.part` file until complete. List every GGUF
file, including models in subdirectories and names containing spaces:

```bash
agentio list
```

Select a model once:

```bash
agentio settings set model model.Q4_K_M.gguf
```

For convenience, `agentio start model.Q4_K_M.gguf` also selects and saves that
model before starting it.

## Persistent settings

Show all current settings and optimization switches:

```bash
agentio settings
```

Settings are stored in `~/.config/agentio/settings.conf`. Changing a setting
automatically regenerates and restarts the service if it is running. If it is
stopped, the change applies on the next start.

Examples:

```bash
agentio settings set ctx_size 32768
agentio settings set gpu_layers 24
agentio settings set flash_attn on
agentio settings set cache_type_k q8_0
agentio settings set cache_type_v q8_0
agentio settings set mlock on
agentio settings set mmap off
agentio settings unset tensor_split
```

Available presets:

```bash
agentio settings preset balanced
agentio settings preset throughput
agentio settings preset low-vram
agentio settings preset cpu
```

The named settings cover model loading, CPU/GPU offload, batching, KV cache,
Flash Attention, memory mapping/locking, NUMA, continuous batching, unified KV,
SWA, operation offload, polling, CPU affinity, priority, and defragmentation.

Because `llama.cpp` adds flags frequently, AgentIO also exposes the complete
installed server help and supports persistent arbitrary arguments:

```bash
agentio settings flags
agentio settings extra set --metrics --no-webui
agentio settings extra add --some-new-llama-flag value
agentio settings extra clear
```

`extra set` replaces the arbitrary argument list; `extra add` appends to it.
Use separate shell arguments exactly as they should be passed to
`llama-server`.

Reset performance settings to defaults while keeping the selected model:

```bash
agentio settings reset
```

## Service commands

```bash
agentio start
agentio status
agentio logs
agentio stop
```

The default endpoint is `http://127.0.0.1:8080`. Change `host`, `port`, or
`api_key` through `agentio settings set` when needed. The API key is stored in a
user-only configuration file and is hidden in `agentio settings` output.
