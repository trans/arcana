# Arcana

Provider-agnostic AI communication library for Crystal. Unified interfaces
for chat completion, image generation, text-to-speech, and embeddings, plus
an agent-to-agent communication bus with pub/sub, request/response, and
OTP-style supervision.

## Installation

Add to your `shard.yml`:

```yaml
dependencies:
  arcana:
    github: trans/arcana
```

Then run `shards install`.

## Architecture

Arcana is organized into four modules — **Chat**, **Image**, **TTS**, and
**Embed** — each following the same pattern:

```
Provider  (abstract class — defines the interface)
Request   (struct — what you send)
Result    (struct — what you get back)
```

On top of these sit the **Bus** (agent communication), **Registry** (provider
factory), **Actor/Supervisor** (OTP-style process management), and **Server**
(WebSocket + REST gateway).

Errors follow a simple hierarchy: `Arcana::Error` > `ConfigError` | `APIError` | `CancelledError`.
`APIError` captures the HTTP status code and response body.

## Chat

Providers implement `complete(request) : Response` and `stream(request) { |event| }`.

### Providers

**OpenAI** — works with any OpenAI-compatible endpoint (OpenAI, Azure, Ollama, vLLM, etc.)

```crystal
provider = Arcana::Chat::OpenAI.new(
  api_key:  ENV["OPENAI_API_KEY"],
  model:    "gpt-4o-mini",
  endpoint: "https://api.openai.com/v1/chat/completions",  # default
)
```

**Anthropic** — native Messages API with system message extraction, cache token tracking, and server-side tools.

```crystal
provider = Arcana::Chat::Anthropic.new(
  api_key: ENV["ANTHROPIC_API_KEY"],
  model:   "claude-sonnet-4-20250514",
)
```

### Messages and History

Messages are role-tagged (`system`, `user`, `assistant`, `tool`). `History`
manages a rolling conversation with automatic trimming at 100k characters.

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

```crystal
tool = Arcana::Chat::Tool.new(
  name: "get_weather",
  description: "Get the current weather for a location",
  parameters_json: %({"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}),
)

request = Arcana::Chat::Request.new(
  messages: [Arcana::Chat::Message.user("Weather in Tokyo?")],
  tools: [tool],
  tool_choice: "auto",
)

response = provider.complete(request)
if response.has_tool_calls?
  tc = response.tool_calls.first
  args = tc.parsed_arguments  # => {"city" => "Tokyo"}
end
```

### Server-Side Tools

Anthropic server-executed tools like web search and code execution:

```crystal
request = Arcana::Chat::Request.new(
  messages: [Arcana::Chat::Message.user("What's the latest Crystal release?")],
  server_tools: [Arcana::Chat::ServerTool.web_search(max_uses: 5)],
)

response = provider.complete(request)
response.server_tool_results  # => raw search result blocks
```

### Streaming

Block-based streaming for both providers. Text deltas are yielded
incrementally, tool_use blocks are emitted when complete.

```crystal
response = provider.stream(request) do |event|
  case event.type
  when .text_delta?
    print event.text
  when .tool_use?
    tc = event.tool_call.not_nil!
  when .done?
    final = event.response.not_nil!
  end
end
```

### Cancellation

Cancel in-flight requests (both `complete` and `stream`) from another fiber:

```crystal
ctx = Arcana::Context.new

spawn do
  provider.stream(request, ctx) { |e| ... }
rescue Arcana::CancelledError
  # request was cancelled
end

# Later, from another fiber:
ctx.cancel
```

### Response

`Chat::Response` gives you:
- `content` — the model's text reply (nil when it only made tool calls)
- `tool_calls` — array of `ToolCall` structs
- `finish_reason` — `"stop"`, `"tool_calls"`, `"length"`, etc.
- `prompt_tokens` / `completion_tokens` — token usage
- `cache_read_tokens` / `cache_creation_tokens` — Anthropic prompt caching
- `server_tool_results` — server-side tool output blocks
- `raw_request` / `raw_json` — full wire-level data for debugging

### Model Listing

```crystal
models = provider.models  # => ["claude-sonnet-4-20250514", "claude-opus-4-20250514", ...]
```

## Image

Providers implement `generate(request, output_path) : Result`.

### Providers

**OpenAI** — DALL-E and gpt-image models.

```crystal
provider = Arcana::Image::OpenAI.new(api_key: ENV["OPENAI_API_KEY"])
```

**Runware** — FLUX model family with identity conditioning and ControlNet.

```crystal
provider = Arcana::Image::Runware.new(api_key: ENV["RUNWARE_API_KEY"])
```

### Basic Generation

```crystal
request = Arcana::Image::Request.new(
  prompt: "A crystal shard glowing with arcane energy",
  width: 1024, height: 1024,
)
result = provider.generate(request, "/tmp/output.webp")
```

### Identity Conditioning

| Method | Best for |
|---|---|
| `SeedImage` | General re-rendering (img2img) |
| `AcePlus` | Portraits, subjects (zero-training) |
| `PuLID` | Face consistency |
| `IPAdapter` | Style matching |

```crystal
id = Arcana::Image::Identity.ace_plus("/path/to/ref.png", strength: 0.65)
request = Arcana::Image::Request.new(prompt: "Same character in a forest", identity: id)
```

### Structural Control (ControlNet)

```crystal
ctrl = Arcana::Image::Control.openpose("/path/to/pose.png", weight: 0.8)
request = Arcana::Image::Request.new(prompt: "Character in this pose", control: ctrl)
```

## TTS

Providers implement `synthesize(request, output_path) : Result`.

```crystal
provider = Arcana::TTS::OpenAI.new(api_key: ENV["OPENAI_API_KEY"])

request = Arcana::TTS::Request.new(
  text: "Hello from Arcana.",
  voice: "nova",
  response_format: "opus",
  instructions: "Speak warmly and clearly.",
)

result = provider.synthesize(request, "/tmp/hello.opus")
```

**Voices:** alloy, ash, ballad, coral, echo, fable, onyx, nova, sage, shimmer, verse

## Embed

Providers implement `embed(request) : Result`.

```crystal
provider = Arcana::Embed::OpenAI.new(api_key: ENV["OPENAI_API_KEY"])

request = Arcana::Embed::Request.new(texts: ["Hello world", "Goodbye"])
result = provider.embed(request)

result.embeddings       # => Array(Array(Float64))
result.dimensions       # => 1536
result.total_tokens     # => token count
```

## Provider Registry

Create providers by name without knowing the concrete class:

```crystal
chat = Arcana::Registry.create_chat("anthropic", {"api_key" => JSON::Any.new(key)})
img  = Arcana::Registry.create_image("runware", {"api_key" => JSON::Any.new(key)})
```

Built-in: `openai` (chat/image/tts/embed), `anthropic` (chat), `runware` (image).

Register your own:

```crystal
Arcana::Registry.register_chat("custom") { |config| MyProvider.new(config) }
```

## Agent Communication Bus

Agents and services communicate via the Bus with direct messaging,
pub/sub fan-out, and request/response patterns.

```crystal
bus = Arcana::Bus.new
writer = bus.mailbox("writer")
artist = bus.mailbox("artist")

# Direct message
bus.send(Arcana::Envelope.new(from: "writer", to: "artist", subject: "generate", payload: data))

# Pub/sub
bus.subscribe("image:ready", "writer")
bus.publish("image:ready", envelope)

# Request/response (blocks until reply or timeout)
reply = bus.request(envelope, timeout: 5.seconds)
```

### Directory

Capability registry for discovering agents and services:

```crystal
dir = Arcana::Directory.new
dir.register(Arcana::Directory::Listing.new(
  address: "my-agent",
  name: "My Agent",
  description: "Does useful things",
  kind: Arcana::Directory::Kind::Agent,
  guide: "Send a request with...",
  tags: ["ai", "helper"],
))

dir.search("helper")     # search by name/description/tags
dir.by_tag("ai")         # filter by tag
dir.by_kind(Kind::Agent)  # filter by kind
```

### Services

Non-LLM handlers with automatic schema validation and protocol compliance:

```crystal
svc = Arcana::Service.new(
  bus: bus, directory: dir,
  address: "echo",
  name: "Echo",
  description: "Echoes back whatever you send.",
  guide: "Send any payload and it will be returned.",
) { |data| data }
svc.start
```

Send `_intent: "help"` to any service to get its usage guide.

### Protocol

Handshake protocol for agent negotiation:
- `Protocol.request(data, intent)` — send a request
- `Protocol.result(data)` — successful response
- `Protocol.need(schema, questions, message)` — ask for more info
- `Protocol.help(guide, schema)` — return documentation
- `Protocol.error(message, code)` — failure

## Actors and Supervisors

OTP-inspired process management:

```crystal
class MyActor < Arcana::Actor
  def init; end
  def handle(envelope : Arcana::Envelope); end
  def terminate; end
end

supervisor = Arcana::Supervisor.new(bus,
  strategy: Arcana::Supervisor::Strategy::OneForOne,
  max_restarts: 3,
  max_seconds: 60,
)
supervisor.add(MyActor.new(bus, dir, "my-actor"))
supervisor.supervise
```

Strategies: `OneForOne` (restart failed actor) or `OneForAll` (restart all on failure).

## Network Server

WebSocket + REST gateway that bridges remote agents to the local bus:

```crystal
server = Arcana::Server.new(bus, dir, host: "127.0.0.1", port: 4000)
server.start  # blocking
```

- **WebSocket** `ws://host:port/bus` — full bus participation
- **REST** `GET /directory` — query the directory
- **REST** `GET /health` — health check
- **REST** `POST /send`, `/request`, `/publish` — messaging
- **REST** `POST /register` — create a mailbox + directory listing
- **REST** `POST /receive` — poll a mailbox for messages

## MCP Bridge

Connects Claude Code (or any MCP client) to the Arcana bus via stdio:

```json
{
  "mcpServers": {
    "arcana": {
      "type": "stdio",
      "command": "/path/to/arcana-mcp",
      "env": { "ARCANA_URL": "http://127.0.0.1:4000" }
    }
  }
}
```

**Tools:** `arcana_directory`, `arcana_request`, `arcana_send`, `arcana_publish`, `arcana_register`, `arcana_receive`, `arcana_health`

## Running

```
just build    # compile server + MCP bridge
just serve    # start the server
just test     # run specs
just docs     # generate API docs
```

Set environment variables for provider services:
- `OPENAI_API_KEY` — enables chat:openai, embed:openai, tts:openai
- `ANTHROPIC_API_KEY` — enables chat:anthropic
- `RUNWARE_API_KEY` — enables image:runware

## License

MIT
