# Optional Local AI setup

`Setup-T26-LocalAI.ps1` is an optional, local-only assistant for choosing an Ollama model for this T26 package.

It detects CPU, architecture, RAM, discovered GPU vendor/model, confirmed NVIDIA VRAM when `nvidia-smi` is available, and free space on the package drive. AMD and Intel GPU memory is reported as `UNKNOWN` unless a reliable value is available; the assistant does not guess.

The assistant first reuses an installed compatible model. If a download is needed, it shows the model tag, the current Ollama catalog listing size, a disk-space safety check, and asks for an explicit `YES` before running `ollama pull`. It never downloads during packaging and never changes T26 provider configuration.

Run from this package directory in PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup-T26-LocalAI.ps1
```

Supported T26 local-model tags in this assistant are `qwen3:1.7b`, `qwen3:4b`, `qwen3:8b`, `qwen3:14b`, and `qwen3:32b`. The catalog and displayed sizes are based on the official Ollama Qwen3 page: <https://ollama.com/library/qwen3>.

The assistant presents LIGHT, BALANCED, and ADVANCED choices using conservative RAM/VRAM thresholds. Larger models can still be slow, especially with CPU/offload. A tester may skip setup. A local inference probe is optional and requires a second explicit `YES`.

The assistant reports `READY`, `PARTIAL`, `UNAVAILABLE`, `BLOCKED`, or `SKIPPED` truthfully. It does not claim that T26 chat or governed tools work merely because Ollama is reachable.
