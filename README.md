# TchouTchou 🚂

**A local LLM switchyard for macOS.** One native app to see every model on your Mac
(Ollama, LM Studio, MLX), and one OpenAI-compatible endpoint that routes each request
to the right engine.

[Français](README.fr.md) · [Project page](https://hugo291.github.io/TchouTchou/)

![TchouTchou — model library](docs/screenshot.jpg)

## What it does

- **Library** — every model from Ollama and LM Studio in one table: source, parameters,
  quantization, size, capabilities. Group, sort, search, copy a model id with one click.
- **In memory** — what is loaded right now (including direct MLX servers), with RAM use,
  activity state and, when the engine exposes it, prompt-processing progress.
- **Discover** — search the Ollama, Hugging Face (GGUF/MLX) and LM Studio catalogs,
  filter by capability, sort by popularity, newest or name, then download.
- **Endpoint** — a background service on `http://127.0.0.1:41235/v1` that speaks the
  OpenAI API and routes by the `model` field:
  - Ollama (`11434`), LM Studio (`1234`), a running MLX server (`8090`)
  - Ollama cloud models, and free [OpenRouter](https://openrouter.ai) models (`:free`)
  - `/v1/models`, `/v1/chat/completions`, `/v1/responses`, `/v1/embeddings`, `/health`, `/telemetry`

The endpoint listens on loopback only and keeps running after the window is closed
(user LaunchAgent `local.TchouTchou.gateway`).

## Requirements

- macOS 14 or later, Swift 5.9+ toolchain (Xcode or Command Line Tools)
- At least one of: Ollama, LM Studio, an MLX server

## Build and install

```sh
make test      # built-in test harness, no model is loaded
make install   # builds, signs ad-hoc, copies to /Applications
open /Applications/TchouTchou.app
```

## Using the endpoint

```sh
curl http://127.0.0.1:41235/v1/models
curl http://127.0.0.1:41235/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<an id from /v1/models>","messages":[{"role":"user","content":"Hello"}]}'
```

Point any OpenAI-compatible client (Codex, scripts, editors) at
`http://127.0.0.1:41235/v1`.

**OpenRouter free models** need an OpenRouter key, read from `OPENROUTER_API_KEY` or the
auth file used by opencode; the client's own `Authorization` header is never forwarded.

## Limits worth knowing

- Counters come from real responses, never from an estimate of text length.
- Only LM Studio exposes a precise prompt-processing percentage; Ollama does not.
- Requests that bypass the endpoint cannot be tracked.
- Discover groups model *families*; it does not guarantee identical weights or
  quantizations across engines.
- The telemetry log keeps ids, phases, dates and counters only — no prompts, answers,
  cookies or tokens.

## License

[MIT](LICENSE)
