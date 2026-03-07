# Arcana

Provider-agnostic AI communication library for Crystal. Arcana provides a
unified interface across chat completion, image generation, and text-to-speech,
letting you swap providers without changing application code.

## Installation

Add to your `shard.yml`:

```yaml
dependencies:
  arcana:
    github: trans/arcana
```

Then run `shards install`.

## Architecture

Arcana is organized into three modules — **Chat**, **Image**, and **TTS** —
each following the same pattern:

```
Provider  (abstract class — defines the interface)
Request   (struct — what you send)
Result    (struct — what you get back)
```

Every provider includes `Arcana::Traceable`, which accepts an optional
`Proc(String, Nil)` callback for observability. All results carry raw
request/response data for debugging.

Errors follow a simple hierarchy: `Arcana::Error` > `ConfigError` | `APIError`.
`APIError` captures the HTTP status code and response body.

## Chat

Providers implement `complete(request) : Response`.

### OpenAI (and compatible APIs)

Works with any OpenAI-compatible endpoint — OpenAI, Azure, local models, etc.

```crystal
provider = Arcana::Chat::OpenAI.new(
  api_key:  ENV["OPENAI_API_KEY"],
  model:    "gpt-4o-mini",
  endpoint: "https://api.openai.com/v1/chat/completions",  # default
)
```

The `endpoint` parameter is the key to provider flexibility. Point it at
Ollama, LiteLLM, vLLM, or any service that speaks the OpenAI chat format.

### Messages and History

Messages are role-tagged (`system`, `user`, `assistant`, `tool`) and serialize
directly to the OpenAI wire format. `History` manages a rolling conversation
with automatic trimming at 100k characters, preserving the system prompt and
the oldest user/assistant exchange for context continuity.

```crystal
history = Arcana::Chat::History.new
history.add_system("You are a helpful assistant.")
history.add_user("What is Crystal?")

request = Arcana::Chat::Request.from_history(history,
  model: "gpt-4o",
  temperature: 0.5,
  max_tokens: 500,
)

response = provider.complete(request)
puts response.content
```

### Function Calling

Define tools with a name, description, and JSON Schema for parameters.
The model returns `ToolCall` objects you can inspect and dispatch.

```crystal
tool = Arcana::Chat::Tool.new(
  name: "get_weather",
  description: "Get the current weather for a location",
  parameters_json: %({"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}),
)

request = Arcana::Chat::Request.new(
  messages: [Arcana::Chat::Message.user("Weather in Tokyo?")],
  tools: [tool],
  tool_choice: "auto",  # or "required", "none"
)

response = provider.complete(request)
if response.has_tool_calls?
  tc = response.tool_calls.first
  args = tc.parsed_arguments  # => {"city" => "Tokyo"}
end
```

### Response

`Chat::Response` gives you:
- `content` — the model's text reply (nil when it only made tool calls)
- `tool_calls` — array of `ToolCall` structs
- `finish_reason` — `"stop"`, `"tool_calls"`, `"length"`, etc.
- `prompt_tokens` / `completion_tokens` — token usage from the API
- `raw_request` / `raw_json` — full wire-level data for debugging

## Image

Providers implement `generate(request, output_path) : Result`.

### Providers

**OpenAI** — DALL-E models via the generations and edits endpoints.

```crystal
provider = Arcana::Image::OpenAI.new(
  api_key: ENV["OPENAI_API_KEY"],
  model:   "gpt-image-1",  # default
  quality: "medium",
)
```

**Runware** — FLUX model family (Dev, Schnell, Fill) with advanced features.

```crystal
provider = Arcana::Image::Runware.new(
  api_key: ENV["RUNWARE_API_KEY"],
  model:   Arcana::Image::Runware::FLUX_DEV,
)
```

### Basic Generation

```crystal
request = Arcana::Image::Request.new(
  prompt: "A crystal shard glowing with arcane energy",
  width: 1024, height: 1024,
  output_format: "WEBP",
)

result = provider.generate(request, "/tmp/output.webp")
puts result.output_path
```

Runware automatically snaps dimensions to the nearest FLUX-compatible
resolution via `Runware.snap_dimensions`.

### Identity Conditioning

Identity controls character consistency across generations. Four methods
are available, each with different tradeoffs:

| Method | What it does | Best for |
|---|---|---|
| `SeedImage` | img2img — uses reference as compositional base | General re-rendering |
| `AcePlus` | ACE++ zero-training identity preservation | Portraits, subjects |
| `PuLID` | Face-specific identity embedding | Face consistency |
| `IPAdapter` | Style and appearance transfer | Style matching |

```crystal
# Quick constructors
id = Arcana::Image::Identity.seed_image("/path/to/ref.png", strength: 0.95)
id = Arcana::Image::Identity.ace_plus("/path/to/ref.png", strength: 0.65, task_type: "portrait")
id = Arcana::Image::Identity.pulid("/path/to/face.png")
id = Arcana::Image::Identity.ip_adapter("/path/to/style.png", strength: 0.5)

request = Arcana::Image::Request.new(
  prompt: "Same character in a forest",
  identity: id,
)
```

Provider support: OpenAI uses SeedImage via its edits endpoint. Runware
supports all four methods natively.

### Structural Control (ControlNet)

Control guides generation with pose skeletons, edge maps, or depth maps.

```crystal
# Generic ControlNet
ctrl = Arcana::Image::Control.openpose("/path/to/pose.png", weight: 0.8)

# FLUX-optimized pose (Union Pro 2.0, ends at 65% of steps)
ctrl = Arcana::Image::Control.flux_pose("/path/to/pose.png")

request = Arcana::Image::Request.new(
  prompt: "Character in this pose",
  control: ctrl,
)
```

Runware can also preprocess raw images into pose skeletons:

```crystal
pose_path = provider.preprocess_pose("/path/to/photo.jpg", "/tmp/pose.png")
```

### Runware Extras

- `upload_image(path)` — uploads to Runware's CDN, returns a reusable UUID
- `preprocess_pose(input, output)` — extracts OpenPose skeleton from a photo
- `enhance_prompt: true` — lets the provider rewrite your prompt for better results
- Per-generation `cost` reported on `Image::Result`

## TTS

Providers implement `synthesize(request, output_path) : Result`.

### OpenAI

```crystal
provider = Arcana::TTS::OpenAI.new(
  api_key: ENV["OPENAI_API_KEY"],
  model:   "gpt-4o-mini-tts",  # default
)

request = Arcana::TTS::Request.new(
  text: "Hello from Arcana.",
  voice: "nova",
  response_format: "opus",
  instructions: "Speak warmly and clearly.",
  speed: 1.0,
)

result = provider.synthesize(request, "/tmp/hello.opus")
```

**Voices:** alloy, ash, ballad, coral, echo, fable, onyx, nova, sage, shimmer, verse

**Formats:** mp3, wav, aac, flac, opus, pcm

## Utilities

`Arcana::Util` provides shared infrastructure:

- `bearer_headers(api_key)` — builds Authorization + Content-Type headers
- `mime_for(path)` — detects MIME type from file extension
- `download_file(url, path)` — downloads a URL to disk with timeouts
- `parameter_hash(**params)` — SHA-256 hash for cache keying
- `MultipartBuilder` — constructs multipart/form-data requests

## Tracing

Any provider can accept a trace callback for logging or observability:

```crystal
tracer = ->(event : String) { Log.info { event } }

provider = Arcana::Chat::OpenAI.new(
  api_key: ENV["OPENAI_API_KEY"],
  trace: tracer,
)
```

Trace events are JSON strings with `phase`, `event_type`, `provider`,
`endpoint`, and request-specific metadata.

## API Documentation

Full API docs can be generated with:

```
just docs
```

This produces Crystal's standard HTML documentation in `docs/api/`.

## License

MIT
