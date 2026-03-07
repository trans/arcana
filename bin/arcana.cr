require "../src/arcana"

host = ENV["ARCANA_HOST"]? || "0.0.0.0"
port = (ENV["ARCANA_PORT"]? || "4000").to_i

bus = Arcana::Bus.new
dir = Arcana::Directory.new

# -- Register Arcana itself --

dir.register(Arcana::Directory::Listing.new(
  address: "arcana",
  name: "Arcana",
  description: "Provider-agnostic AI communication library for Crystal. Arcana provides unified interfaces for chat completion, image generation, text-to-speech, and embeddings, plus an agent-to-agent communication bus with pub/sub, request/response, and OTP-style supervision.",
  kind: Arcana::Directory::Kind::Agent,
  guide: <<-GUIDE,
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
  tags: ["ai", "crystal", "library", "chat", "image", "tts", "embed", "bus", "agents"],
))

# -- Built-in services --

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

STDERR.puts "Arcana v#{Arcana::VERSION} starting on #{host}:#{port}"
STDERR.puts "  WebSocket: ws://#{host}:#{port}/bus"
STDERR.puts "  REST:      http://#{host}:#{port}/directory"
STDERR.puts "  Health:    http://#{host}:#{port}/health"
STDERR.puts "  Services:  echo, registry"
STDERR.puts "  Directory: #{dir.list.size} listings"

server = Arcana::Server.new(bus, dir, host: host, port: port)
server.start
