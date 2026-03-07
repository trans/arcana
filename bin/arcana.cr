require "../src/arcana"

host = ENV["ARCANA_HOST"]? || "127.0.0.1"
port = (ENV["ARCANA_PORT"]? || "4000").to_i

bus = Arcana::Bus.new
dir = Arcana::Directory.new

# -- Register Arcana itself --

arcana_guide = <<-GUIDE
  # Arcana — Crystal AI Communication Library

  ## Adding to your project

  Add to shard.yml:
  ```yaml
  dependencies:
    arcana:
      github: infocomics/arcana
  ```

  Then `require "arcana"` in your code.

  ## Four service modules

  Each module has an abstract Provider, a Request struct, and a Result/Response struct.

  ### Chat (Arcana::Chat)
  Providers: OpenAI (any OpenAI-compatible endpoint), Anthropic (native Messages API).
  ```crystal
  provider = Arcana::Chat::OpenAI.new(api_key: ENV["OPENAI_API_KEY"])
  # or
  provider = Arcana::Chat::Anthropic.new(api_key: ENV["ANTHROPIC_API_KEY"])

  request = Arcana::Chat::Request.new(
    messages: [Arcana::Chat::Message.user("Hello")],
    model: "gpt-4o",
    max_tokens: 500,
  )
  response = provider.complete(request)
  puts response.content
  ```
  Supports function calling via Chat::Tool and Chat::ToolCall.
  History manages rolling conversations with auto-trim at 100k chars.

  ### Image (Arcana::Image)
  Providers: OpenAI (DALL-E/gpt-image), Runware (FLUX models).
  ```crystal
  provider = Arcana::Image::Runware.new(api_key: ENV["RUNWARE_API_KEY"])
  request = Arcana::Image::Request.new(prompt: "a castle", width: 1024, height: 1024)
  result = provider.generate(request, "/tmp/castle.webp")
  ```
  Identity conditioning: SeedImage, AcePlus, PuLID, IPAdapter.
  Structural control: OpenPose, Canny, Depth via ControlNet.

  ### TTS (Arcana::TTS)
  Provider: OpenAI (gpt-4o-mini-tts).
  ```crystal
  provider = Arcana::TTS::OpenAI.new(api_key: ENV["OPENAI_API_KEY"])
  request = Arcana::TTS::Request.new(text: "Hello", voice: "nova")
  result = provider.synthesize(request, "/tmp/hello.opus")
  ```
  Voices: alloy, ash, ballad, coral, echo, fable, onyx, nova, sage, shimmer, verse.

  ### Embed (Arcana::Embed)
  Provider: OpenAI (text-embedding-3-small, endpoint-configurable).
  ```crystal
  provider = Arcana::Embed::OpenAI.new(api_key: ENV["OPENAI_API_KEY"])
  request = Arcana::Embed::Request.new(texts: ["Hello world"])
  result = provider.embed(request)
  puts result.embeddings.first.size  # vector dimensions
  ```

  ## Provider Registry

  Create providers by name without knowing the concrete class:
  ```crystal
  chat = Arcana::Registry.create_chat("openai", {"api_key" => JSON::Any.new("sk-...")})
  img  = Arcana::Registry.create_image("runware", {"api_key" => JSON::Any.new("rw-...")})
  ```
  Built-in: openai (chat/image/tts/embed), anthropic (chat), runware (image).
  Register your own with `Registry.register_chat("name") { |config| ... }`.

  ## Agent Communication Bus

  Agents and services communicate via the Bus:
  ```crystal
  bus = Arcana::Bus.new
  mailbox = bus.mailbox("my-agent")

  # Direct messaging
  bus.send(Arcana::Envelope.new(from: "me", to: "other", payload: ...))

  # Pub/sub
  bus.subscribe("topic", "my-agent")
  bus.publish("topic", envelope)

  # Request/response
  reply = bus.request(envelope, timeout: 5.seconds)
  ```

  ## Services and Actors

  Services (non-LLM) validate input against a schema and respond automatically.
  Actors (abstract base) have init/handle/terminate lifecycle hooks.
  Supervisors monitor actors and restart on crash (OneForOne or OneForAll).

  ## Protocol

  The handshake protocol uses envelope payloads:
  - request(data, intent) — send a request
  - result(data) — successful response
  - need(schema, questions, message) — ask for more info
  - help(guide, schema) — return how-to documentation
  - error(message, code) — failure

  Send `_intent: "help"` to any service to get its usage guide.

  ## Network Server

  Run `just serve` to start the WebSocket + REST gateway.
  Agents connect via WebSocket at ws://host:port/bus.
  Directory is queryable at GET /directory.
  Messages can be sent via POST /send, POST /request, POST /publish.
GUIDE

# -- Built-in services --

arcana_svc = Arcana::Service.new(
  bus: bus, directory: dir,
  address: "arcana",
  name: "Arcana",
  description: "Provider-agnostic AI communication library for Crystal. Arcana provides unified interfaces for chat completion, image generation, text-to-speech, and embeddings, plus an agent-to-agent communication bus with pub/sub, request/response, and OTP-style supervision.",
  guide: arcana_guide,
  tags: ["ai", "crystal", "library", "chat", "image", "tts", "embed", "bus", "agents"],
) { |_data| JSON::Any.new(arcana_guide) }
arcana_svc.start

# Echo service — useful for testing the bus.
echo = Arcana::Service.new(
  bus: bus, directory: dir,
  address: "echo",
  name: "Echo",
  description: "Echoes back whatever you send. Useful for testing bus connectivity.",
  guide: "Send any payload and it will be returned as-is in a result response. No schema required.",
  tags: ["test", "utility"],
) { |data| data }
echo.start

# Registry service — lists available providers.
registry_schema = JSON.parse(%({"type":"object","properties":{"domain":{"type":"string","enum":["chat","image","tts","embed"],"description":"Which provider domain to list"}},"required":["domain"]}))

registry_svc = Arcana::Service.new(
  bus: bus, directory: dir,
  address: "registry",
  name: "Provider Registry",
  description: "Lists available AI providers by domain (chat, image, tts, embed).",
  schema: registry_schema,
  guide: <<-GUIDE,
  Query which providers are registered for a given domain.

  Send: {"domain": "chat"}
  Returns: {"providers": ["anthropic", "openai"]}

  Valid domains: chat, image, tts, embed.
  GUIDE
  tags: ["providers", "discovery"],
) do |data|
  domain = data["domain"].as_s
  providers = case domain
              when "chat"  then Arcana::Registry.chat_providers
              when "image" then Arcana::Registry.image_providers
              when "tts"   then Arcana::Registry.tts_providers
              when "embed" then Arcana::Registry.embed_providers
              else              [] of String
              end
  JSON::Any.new({"providers" => JSON::Any.new(providers.map { |p| JSON::Any.new(p) })})
end
registry_svc.start

# -- Provider-backed services (only registered when API keys are present) --

services = ["echo", "registry"]

if openai_key = ENV["OPENAI_API_KEY"]?
  chat_openai = Arcana::Chat::OpenAI.new(api_key: openai_key)
  chat_openai_schema = JSON.parse(%({"type":"object","properties":{"messages":{"type":"array","description":"Array of message objects with role and content","items":{"type":"object","properties":{"role":{"type":"string","enum":["system","user","assistant"]},"content":{"type":"string"}},"required":["role","content"]}},"model":{"type":"string","description":"Model to use (default: gpt-4o-mini)"},"temperature":{"type":"number","description":"Sampling temperature 0.0-2.0 (default: 0.7)"},"max_tokens":{"type":"integer","description":"Maximum response tokens (default: 150)"}},"required":["messages"]}))

  chat_openai_svc = Arcana::Service.new(
    bus: bus, directory: dir,
    address: "chat:openai",
    name: "OpenAI Chat",
    description: "Chat completion via OpenAI-compatible API.",
    schema: chat_openai_schema,
    guide: <<-GUIDE,
    Send a messages array to get a chat completion.

    Example request:
      {"messages": [{"role": "user", "content": "Hello!"}]}

    Optional fields:
      model: "gpt-4o", "gpt-4o-mini" (default), etc.
      temperature: 0.0-2.0 (default 0.7)
      max_tokens: response limit (default 150)

    Returns: {"content": "...", "model": "...", "finish_reason": "...",
              "prompt_tokens": N, "completion_tokens": N}
    GUIDE
    tags: ["chat", "llm", "openai"],
  ) do |data|
    msgs = data["messages"].as_a.map do |m|
      Arcana::Chat::Message.new(
        role: m["role"].as_s,
        content: m["content"]?.try(&.as_s?),
      )
    end
    request = Arcana::Chat::Request.new(
      messages: msgs,
      model: data["model"]?.try(&.as_s?) || "",
      temperature: data["temperature"]?.try(&.as_f?) || 0.7,
      max_tokens: data["max_tokens"]?.try(&.as_i?) || 150,
    )
    response = chat_openai.complete(request)
    JSON::Any.new({
      "content"           => JSON::Any.new(response.content || ""),
      "model"             => JSON::Any.new(response.model),
      "finish_reason"     => JSON::Any.new(response.finish_reason || ""),
      "prompt_tokens"     => JSON::Any.new(response.prompt_tokens || 0),
      "completion_tokens" => JSON::Any.new(response.completion_tokens || 0),
    })
  end
  chat_openai_svc.start
  services << "chat:openai"

  # Embed service
  embed_openai = Arcana::Embed::OpenAI.new(api_key: openai_key)
  embed_schema = JSON.parse(%({"type":"object","properties":{"texts":{"type":"array","items":{"type":"string"},"description":"Texts to embed"},"model":{"type":"string","description":"Model (default: text-embedding-3-small)"}},"required":["texts"]}))

  embed_svc = Arcana::Service.new(
    bus: bus, directory: dir,
    address: "embed:openai",
    name: "OpenAI Embeddings",
    description: "Generate text embeddings via OpenAI.",
    schema: embed_schema,
    guide: <<-GUIDE,
    Send an array of texts to get embedding vectors.

    Example: {"texts": ["Hello world", "Goodbye"]}

    Returns: {"embeddings": [[0.1, ...], [0.2, ...]], "dimensions": 1536,
              "total_tokens": N}
    GUIDE
    tags: ["embed", "openai", "vectors"],
  ) do |data|
    texts = data["texts"].as_a.map(&.as_s)
    request = Arcana::Embed::Request.new(
      texts: texts,
      model: data["model"]?.try(&.as_s?) || "",
    )
    result = embed_openai.embed(request)
    JSON::Any.new({
      "embeddings"   => JSON::Any.new(result.embeddings.map { |e| JSON::Any.new(e.map { |v| JSON::Any.new(v) }) }),
      "dimensions"   => JSON::Any.new(result.dimensions),
      "total_tokens" => JSON::Any.new(result.total_tokens),
    })
  end
  embed_svc.start
  services << "embed:openai"

  # TTS service
  tts_openai = Arcana::TTS::OpenAI.new(api_key: openai_key)
  tts_schema = JSON.parse(%({"type":"object","properties":{"text":{"type":"string","description":"Text to synthesize"},"voice":{"type":"string","description":"Voice: alloy, ash, ballad, coral, echo, fable, onyx, nova, sage, shimmer, verse (default: alloy)"},"output_path":{"type":"string","description":"File path for output audio"},"format":{"type":"string","description":"Audio format: mp3, wav, aac, flac, opus, pcm (default: opus)"},"instructions":{"type":"string","description":"Style/persona instructions"},"speed":{"type":"number","description":"Speed 0.25-4.0 (default: 1.0)"}},"required":["text","output_path"]}))

  tts_svc = Arcana::Service.new(
    bus: bus, directory: dir,
    address: "tts:openai",
    name: "OpenAI Text-to-Speech",
    description: "Synthesize speech from text via OpenAI.",
    schema: tts_schema,
    guide: <<-GUIDE,
    Send text and an output path to generate speech audio.

    Example: {"text": "Hello world", "output_path": "/tmp/hello.opus"}

    Optional fields:
      voice: alloy (default), nova, echo, etc.
      format: opus (default), mp3, wav, aac, flac, pcm
      instructions: "Speak warmly and clearly"
      speed: 0.25-4.0

    Returns: {"output_path": "/tmp/hello.opus", "model": "...",
              "content_type": "audio/opus", "content_length": N}
    GUIDE
    tags: ["tts", "speech", "audio", "openai"],
  ) do |data|
    request = Arcana::TTS::Request.new(
      text: data["text"].as_s,
      voice: data["voice"]?.try(&.as_s?) || "alloy",
      response_format: data["format"]?.try(&.as_s?) || "opus",
      instructions: data["instructions"]?.try(&.as_s?),
      speed: data["speed"]?.try(&.as_f?),
    )
    result = tts_openai.synthesize(request, data["output_path"].as_s)
    JSON::Any.new({
      "output_path"    => JSON::Any.new(result.output_path),
      "model"          => JSON::Any.new(result.model),
      "content_type"   => JSON::Any.new(result.content_type),
      "content_length" => JSON::Any.new(result.content_length),
    })
  end
  tts_svc.start
  services << "tts:openai"
end

if anthropic_key = ENV["ANTHROPIC_API_KEY"]?
  chat_anthropic = Arcana::Chat::Anthropic.new(api_key: anthropic_key)
  chat_anthropic_schema = JSON.parse(%({"type":"object","properties":{"messages":{"type":"array","description":"Array of message objects with role and content","items":{"type":"object","properties":{"role":{"type":"string","enum":["system","user","assistant"]},"content":{"type":"string"}},"required":["role","content"]}},"model":{"type":"string","description":"Model (default: claude-sonnet-4-20250514)"},"temperature":{"type":"number","description":"Sampling temperature (default: 0.7)"},"max_tokens":{"type":"integer","description":"Maximum response tokens (default: 4096)"}},"required":["messages"]}))

  chat_anthropic_svc = Arcana::Service.new(
    bus: bus, directory: dir,
    address: "chat:anthropic",
    name: "Anthropic Chat",
    description: "Chat completion via Anthropic Messages API.",
    schema: chat_anthropic_schema,
    guide: <<-GUIDE,
    Send a messages array to get a chat completion from Claude.

    Example request:
      {"messages": [{"role": "user", "content": "Hello!"}]}

    Optional fields:
      model: "claude-sonnet-4-20250514" (default), "claude-opus-4-20250514", etc.
      temperature: 0.0-1.0 (default 0.7)
      max_tokens: response limit (default 4096)

    System messages are extracted and sent as top-level system parameter.

    Returns: {"content": "...", "model": "...", "finish_reason": "...",
              "prompt_tokens": N, "completion_tokens": N}
    GUIDE
    tags: ["chat", "llm", "anthropic", "claude"],
  ) do |data|
    msgs = data["messages"].as_a.map do |m|
      Arcana::Chat::Message.new(
        role: m["role"].as_s,
        content: m["content"]?.try(&.as_s?),
      )
    end
    request = Arcana::Chat::Request.new(
      messages: msgs,
      model: data["model"]?.try(&.as_s?) || "",
      temperature: data["temperature"]?.try(&.as_f?) || 0.7,
      max_tokens: data["max_tokens"]?.try(&.as_i?) || 4096,
    )
    response = chat_anthropic.complete(request)
    JSON::Any.new({
      "content"           => JSON::Any.new(response.content || ""),
      "model"             => JSON::Any.new(response.model),
      "finish_reason"     => JSON::Any.new(response.finish_reason || ""),
      "prompt_tokens"     => JSON::Any.new(response.prompt_tokens || 0),
      "completion_tokens" => JSON::Any.new(response.completion_tokens || 0),
    })
  end
  chat_anthropic_svc.start
  services << "chat:anthropic"
end

if runware_key = ENV["RUNWARE_API_KEY"]?
  image_runware = Arcana::Image::Runware.new(api_key: runware_key)
  image_schema = JSON.parse(%({"type":"object","properties":{"prompt":{"type":"string","description":"Image description"},"output_path":{"type":"string","description":"File path for output image"},"width":{"type":"integer","description":"Width in pixels (default: 1024, auto-snapped to FLUX sizes)"},"height":{"type":"integer","description":"Height in pixels (default: 1024)"},"format":{"type":"string","description":"Output format: WEBP (default), PNG"},"enhance_prompt":{"type":"boolean","description":"Let provider rewrite prompt (default: false)"}},"required":["prompt","output_path"]}))

  image_svc = Arcana::Service.new(
    bus: bus, directory: dir,
    address: "image:runware",
    name: "Runware Image Generator",
    description: "Generate images using FLUX models via Runware.",
    schema: image_schema,
    guide: <<-GUIDE,
    Send a prompt and output path to generate an image.

    Example: {"prompt": "a crystal shard glowing", "output_path": "/tmp/shard.webp"}

    Optional fields:
      width/height: default 1024x1024, auto-snapped to FLUX-compatible sizes
      format: WEBP (default) or PNG
      enhance_prompt: true to let the model rewrite your prompt

    Returns: {"output_path": "/tmp/shard.webp", "model": "...", "cost": 0.003}

    Tips:
    - Short, descriptive prompts work best
    - Dimensions are automatically adjusted to valid FLUX aspect ratios
    - Cost per generation is reported in the response
    GUIDE
    tags: ["image", "runware", "flux", "generation"],
  ) do |data|
    request = Arcana::Image::Request.new(
      prompt: data["prompt"].as_s,
      width: data["width"]?.try(&.as_i?) || 1024,
      height: data["height"]?.try(&.as_i?) || 1024,
      output_format: data["format"]?.try(&.as_s?) || "WEBP",
      enhance_prompt: data["enhance_prompt"]?.try(&.as_bool?) || false,
    )
    result = image_runware.generate(request, data["output_path"].as_s)
    h = {
      "output_path" => JSON::Any.new(result.output_path),
      "model"       => JSON::Any.new(result.model),
    } of String => JSON::Any
    if cost = result.cost
      h["cost"] = JSON::Any.new(cost)
    end
    JSON::Any.new(h)
  end
  image_svc.start
  services << "image:runware"
end

STDERR.puts "Arcana v#{Arcana::VERSION} starting on #{host}:#{port}"
STDERR.puts "  WebSocket: ws://#{host}:#{port}/bus"
STDERR.puts "  REST:      http://#{host}:#{port}/directory"
STDERR.puts "  Health:    http://#{host}:#{port}/health"
STDERR.puts "  Services:  #{services.join(", ")}"
STDERR.puts "  Directory: #{dir.list.size} listings"

server = Arcana::Server.new(bus, dir, host: host, port: port)
server.start
