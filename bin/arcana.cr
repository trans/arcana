require "../src/arcana"

# -- Subcommands --

command = ARGV.shift? || "serve"

case command
when "init"
  # Delegate to the init script
  script = File.join(File.dirname(Process.executable_path || __FILE__), "arcana-init")
  unless File.exists?(script)
    script = File.join(File.dirname(__DIR__), "bin", "arcana-init")
  end
  exit Process.run(script, ARGV, output: STDOUT, error: STDERR).exit_code
when "version", "--version", "-v"
  puts "Arcana v#{Arcana::VERSION}"
  exit 0
when "help", "--help", "-h"
  STDERR.puts <<-HELP
  Arcana v#{Arcana::VERSION} — AI communication bus

  Usage: arcana [command] [options]

  Commands:
    serve   Start the Arcana server (default)
    init    Set up a project for the bus
    version Show version

  Options:
    --fresh  Start with empty state (ignore persisted registrations)

  Environment:
    ARCANA_HOST       Server host (default: 127.0.0.1)
    ARCANA_PORT       Server port (default: 19118)
    ARCANA_STATE_DIR  State directory (default: ~/.arcana)
  HELP
  exit 0
when "serve"
  # fall through to server startup below
else
  STDERR.puts "Unknown command: #{command}"
  STDERR.puts "Run 'arcana help' for usage."
  exit 1
end

# -- Server startup --

fresh = ARGV.includes?("--fresh")

host = ENV["ARCANA_HOST"]? || "127.0.0.1"
port = (ENV["ARCANA_PORT"]? || "19118").to_i
state_dir = ENV["ARCANA_STATE_DIR"]? || File.join(Path.home, ".arcana")
state_file = File.join(state_dir, "directory.json")

Dir.mkdir_p(state_dir) unless Dir.exists?(state_dir)

# -- Postgres migrations (when ARCANA_DATABASE_URL is set) --
# Idempotent. Future releases that add new SQL files migrate automatically
# on package upgrade + service restart. If migration fails, fail loud.
if Arcana::DB.enabled?
  begin
    applied = Arcana::DB::Migrate.run
    unless applied.empty?
      STDERR.puts "Database: applied #{applied.size} pending migration#{applied.size == 1 ? "" : "s"}:"
      applied.each { |f| STDERR.puts "  #{f}" }
    end
  rescue ex
    STDERR.puts "FATAL: database migration failed: #{ex.message}"
    exit 1
  end
end

# -- Event log --
# Audit log of material bus actions (registrations, sends, publishes,
# freezes, auth failures, lifecycle). Opt-out by setting
# ARCANA_EVENT_LOG_DISABLE=1. See Arcana::Events for the data model.
events_backend =
  if ENV["ARCANA_EVENT_LOG_DISABLE"]? == "1"
    nil
  else
    event_log_dir = ENV["ARCANA_EVENT_LOG_DIR"]? || File.join(state_dir, "events")
    Arcana::Events::FileBackend.new(
      log_dir: event_log_dir,
      compress_age_days: (ENV["ARCANA_EVENT_COMPRESS_AGE_DAYS"]? || "2").to_i,
      retain_days: (ENV["ARCANA_EVENT_RETAIN_DAYS"]? || "90").to_i,
      archive_dir: ENV["ARCANA_EVENT_ARCHIVE_DIR"]?,
      max_size_mb: ENV["ARCANA_EVENT_MAX_SIZE_MB"]?.try(&.to_i),
    )
  end

bus = Arcana::Bus.new
dir = Arcana::Directory.new
bus.directory = dir
bus.events = events_backend
dir.events = events_backend

# Bounded mailboxes: cap each mailbox's queue length to stop a runaway
# sender from filling memory. Set to 0 (or unset via `unset ...`) to
# disable and go unbounded like pre-0.22.2.
if raw = ENV["ARCANA_MAILBOX_MAX_QUEUE"]?
  max_q = raw.to_i
  bus.default_max_queue = max_q if max_q > 0
else
  bus.default_max_queue = 10_000
end

# -- Register Arcana itself --

arcana_guide = <<-GUIDE
  # Arcana — AI Communication Library & Agent Bus

  ## AI Providers

  ### Chat
  Providers: OpenAI, Anthropic, Gemini, Grok (xAI), DeepSeek.
  All support streaming, cancellation, function calling, and model listing.

  ### Image
  Providers: OpenAI (DALL-E/gpt-image), Runware (FLUX models).

  ### TTS
  Provider: OpenAI (gpt-4o-mini-tts). Voices: alloy, ash, ballad, coral, echo, fable, onyx, nova, sage, shimmer, verse.

  ### Embed
  Providers: OpenAI, Voyage. Supports batch embedding and retry.

  ### Markdown
  Convert LLM markdown responses: `Arcana::Markdown.to_html(text)` or `to_ansi(text)` for terminal output. Also available as the `markdown` bus service.

  ## Agent Communication Bus

  Agents and services communicate via envelopes on the bus.

  ### Sending Messages (`arcana_deliver`)

  All message sending uses `arcana_deliver`. The `ordering` parameter controls behavior:
  - **auto** (default) — the bus decides based on target kind: services get sync (blocks for reply), agents get async (fire and forget)
  - **sync** — always block and wait for a reply
  - **async** — always fire and forget (check `arcana_receive` later for replies)

  The response tells you which mode was resolved and the correlation_id for tracking.

  ### Receiving Messages

  **Check inbox** (`arcana_inbox`): List pending messages WITHOUT consuming them. Returns metadata (correlation_id, from, subject, timestamp).

  **Receive** (`arcana_receive`): Consume messages from your mailbox. Use `id` to selectively consume a specific message by correlation_id.

  ### Multi-Agent Coordination

  **Expected Response Tracking** (`arcana_expect`):
  When you send messages to multiple agents and need all replies before proceeding:
  1. Send messages (expectations are tracked via correlation_id)
  2. Use `arcana_expect action:"check"` to see how many replies are outstanding
  3. Use `arcana_expect action:"await"` to block until all expected replies arrive

  **Freeze/Thaw** (`arcana_freeze`):
  Temporarily hold messages out of the receive queue:
  - `action:"freeze"` — hold a message by correlation_id (it won't appear in receive)
  - `action:"thaw"` — release a frozen message back to the queue
  - `action:"thaw_all"` — release all frozen messages
  - `action:"list"` — see what's currently frozen

  Use cases: pause processing during high-priority work, wait for child agent results before processing new messages.

  ### Pub/Sub

  Subscribe to topics and publish broadcasts:
    `arcana_publish` sends to all subscribers of a topic.

  ### Registration (`arcana_register`)

  Manage your presence on the bus with a single tool:
  - **register** (default) — create a mailbox and directory listing
  - **unregister** — remove your mailbox and listing
  - **busy** — mark yourself as busy (others see this in the directory)
  - **idle** — mark yourself as available again

  ### Discovery

  **Directory** (`arcana_directory`): List all agents and services on the bus. Each listing shows address, name, description, kind (agent/service), busy status, and tags. Query by name, tag, or kind.

  Send `{"tool": "help"}` to any service to get its usage guide and schema (or, for multi-tool providers, its full tools manifest).

  ## Protocol

  The handshake protocol wraps envelope payloads:
  - request(data, intent) — send a request
  - result(data) — successful response
  - need(schema, questions, message) — ask for more info
  - help(guide, schema) — return documentation
  - error(message, code) — failure

  ## Network

  WebSocket: ws://host:port/bus (real-time bidirectional)
  REST: /deliver, /receive, /inbox, /publish, /register, /unregister, /busy, /directory, /health
  MCP: 9 tools for full bus access from Claude Code or any MCP client
GUIDE

# -- Built-in Toolsets --
#
# Each provider (arcana utilities, openai, anthropic, ...) registers as
# a single entity on the bus with its capabilities exposed as tools.
# Discovery: send `{"tool":"help"}` to any entity for its manifest.
# Cross-provider: filter the directory by tag (e.g. `tag:"chat"`).

# Arcana utility Toolset — echo + markdown, plus the auto-generated help.
arcana_ts = Arcana::Toolset.new(
  bus: bus, directory: dir,
  address: "arcana",
  name: "Arcana",
  description: "Provider-agnostic AI communication library for Crystal. Arcana provides unified interfaces for chat, image, text-to-speech, and embeddings, plus an agent-to-agent communication bus with pub/sub, request/response, and OTP-style supervision.",
  tags: ["utility", "arcana"],
)

arcana_ts.tool("echo", "Echoes back whatever you send. Useful for testing bus connectivity.") do |data|
  data
end

markdown_schema = JSON.parse(%({"type":"object","properties":{"text":{"type":"string","description":"Markdown text to convert"},"format":{"type":"string","enum":["html","ansi"],"description":"Output format: html (default) or ansi"}},"required":["text"]}))

arcana_ts.tool("markdown", "Convert Markdown to HTML or ANSI terminal output.", input_schema: markdown_schema) do |data|
  text = data.str("text")
  format = data.str("format", "html")
  result = case format
           when "ansi" then Arcana::Markdown.to_ansi(text)
           else             Arcana::Markdown.to_html(text)
           end
  JSON::Any.new({
    "result" => JSON::Any.new(result),
    "format" => JSON::Any.new(format),
  })
end

arcana_ts.start

# -- Provider-backed services (only registered when API keys are present) --

if openai_key = ENV["OPENAI_API_KEY"]?
  chat_openai = Arcana::AI::Chat::OpenAI.new(api_key: openai_key)
  embed_openai = Arcana::AI::Embed::OpenAI.new(api_key: openai_key)
  tts_openai = Arcana::AI::TTS::OpenAI.new(api_key: openai_key)

  openai_ts = Arcana::Toolset.new(
    bus: bus, directory: dir,
    address: "openai",
    name: "OpenAI",
    description: "OpenAI provider — chat completion, embeddings, text-to-speech.",
    tags: ["llm", "openai"],
  )

  chat_openai_schema = JSON.parse(%({"type":"object","properties":{"messages":{"type":"array","description":"Array of message objects with role and content","items":{"type":"object","properties":{"role":{"type":"string","enum":["system","user","assistant"]},"content":{"type":"string"}},"required":["role","content"]}},"model":{"type":"string","description":"Model to use (default: gpt-4o-mini)"},"temperature":{"type":"number","description":"Sampling temperature 0.0-2.0 (default: 0.7)"},"max_tokens":{"type":"integer","description":"Maximum response tokens (default: 150)"}},"required":["messages"]}))

  openai_ts.tool("chat",
    "Chat completion. Send messages array; get content, model, finish_reason, token counts back.",
    input_schema: chat_openai_schema) do |data|
    msgs = data["messages"].as_a.map do |m|
      Arcana::AI::Chat::Message.new(role: m["role"].as_s, content: m.str?("content"))
    end
    request = Arcana::AI::Chat::Request.new(
      messages: msgs,
      model: data.str("model"),
      temperature: data.float("temperature", 0.7),
      max_tokens: data.int("max_tokens", 150),
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

  embed_schema = JSON.parse(%({"type":"object","properties":{"texts":{"type":"array","items":{"type":"string"},"description":"Texts to embed"},"model":{"type":"string","description":"Model (default: text-embedding-3-small)"}},"required":["texts"]}))

  openai_ts.tool("embed",
    "Generate text embedding vectors for an array of texts.",
    input_schema: embed_schema) do |data|
    texts = data["texts"].as_a.map(&.as_s)
    request = Arcana::AI::Embed::Request.new(texts: texts, model: data.str("model"))
    result = embed_openai.embed(request)
    JSON::Any.new({
      "embeddings"   => JSON::Any.new(result.embeddings.map { |e| JSON::Any.new(e.map { |v| JSON::Any.new(v) }) }),
      "dimensions"   => JSON::Any.new(result.dimensions),
      "total_tokens" => JSON::Any.new(result.total_tokens),
    })
  end

  tts_schema = JSON.parse(%({"type":"object","properties":{"text":{"type":"string","description":"Text to synthesize"},"voice":{"type":"string","description":"Voice: alloy, ash, ballad, coral, echo, fable, onyx, nova, sage, shimmer, verse (default: alloy)"},"output_path":{"type":"string","description":"File path for output audio (required unless inline: true)"},"inline":{"type":"boolean","description":"If true, return audio as base64 in the response instead of writing to disk. Default false."},"format":{"type":"string","description":"Audio format: mp3, wav, aac, flac, opus, pcm (default: opus)"},"instructions":{"type":"string","description":"Style/persona instructions"},"speed":{"type":"number","description":"Speed 0.25-4.0 (default: 1.0)"}},"required":["text"]}))

  openai_ts.tool("tts",
    "Text-to-speech synthesis. Provide either output_path or inline: true.",
    input_schema: tts_schema) do |data|
    inline = data.bool("inline")
    output_path = data.str?("output_path")
    raise "Provide either output_path or inline: true" if !inline && output_path.nil?

    request = Arcana::AI::TTS::Request.new(
      text: data["text"].as_s,
      voice: data.str("voice", "alloy"),
      response_format: data.str("format", "opus"),
      instructions: data.str?("instructions"),
      speed: data.float?("speed"),
    )

    if inline
      # TODO: promote to arcana-ai (add synthesize_bytes on TTS::Provider)
      # so this stops round-tripping through disk.
      temp = File.tempname("arcana-tts-", ".#{request.response_format}")
      begin
        result = tts_openai.synthesize(request, temp)
        audio = Base64.strict_encode(File.read(temp))
        JSON::Any.new({
          "audio_base64"   => JSON::Any.new(audio),
          "model"          => JSON::Any.new(result.model),
          "content_type"   => JSON::Any.new(result.content_type),
          "content_length" => JSON::Any.new(result.content_length),
        })
      ensure
        File.delete(temp) if File.exists?(temp)
      end
    else
      result = tts_openai.synthesize(request, output_path.not_nil!)
      JSON::Any.new({
        "output_path"    => JSON::Any.new(result.output_path),
        "model"          => JSON::Any.new(result.model),
        "content_type"   => JSON::Any.new(result.content_type),
        "content_length" => JSON::Any.new(result.content_length),
      })
    end
  end

  openai_ts.start
end

if anthropic_key = ENV["ANTHROPIC_API_KEY"]?
  chat_anthropic = Arcana::AI::Chat::Anthropic.new(api_key: anthropic_key)

  anthropic_ts = Arcana::Toolset.new(
    bus: bus, directory: dir,
    address: "anthropic",
    name: "Anthropic",
    description: "Anthropic provider — Claude chat completion. Supports optional web search.",
    tags: ["llm", "anthropic", "claude", "web"],
  )

  chat_anthropic_schema = JSON.parse(%({"type":"object","properties":{"messages":{"type":"array","description":"Array of message objects with role and content","items":{"type":"object","properties":{"role":{"type":"string","enum":["system","user","assistant"]},"content":{"type":"string"}},"required":["role","content"]}},"model":{"type":"string","description":"Model (default: claude-sonnet-4-20250514)"},"temperature":{"type":"number","description":"Sampling temperature (default: 0.7)"},"max_tokens":{"type":"integer","description":"Maximum response tokens (default: 4096)"},"web_search":{"type":"boolean","description":"If true, Claude can search the web during its response. The model decides when/whether. Default: false."}},"required":["messages"]}))

  anthropic_ts.tool("chat",
    "Chat completion via Claude. Optional web_search:true lets the model browse.",
    input_schema: chat_anthropic_schema) do |data|
    msgs = data["messages"].as_a.map do |m|
      Arcana::AI::Chat::Message.new(role: m["role"].as_s, content: m.str?("content"))
    end
    server_tools = nil
    if data.bool?("web_search")
      server_tools = [Arcana::AI::Chat::ServerTool.web_search] of Arcana::AI::Chat::ServerTool
    end
    request = Arcana::AI::Chat::Request.new(
      messages: msgs,
      model: data.str("model"),
      temperature: data.float("temperature", 0.7),
      max_tokens: data.int("max_tokens", 4096),
      server_tools: server_tools,
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

  anthropic_ts.start
end

if google_key = ENV["GOOGLE_API_KEY"]?
  chat_gemini = Arcana::AI::Chat::Gemini.new(api_key: google_key)

  gemini_ts = Arcana::Toolset.new(
    bus: bus, directory: dir,
    address: "gemini",
    name: "Gemini",
    description: "Google Gemini provider — chat completion.",
    tags: ["llm", "gemini", "google"],
  )

  chat_gemini_schema = JSON.parse(%({"type":"object","properties":{"messages":{"type":"array","description":"Array of message objects with role and content","items":{"type":"object","properties":{"role":{"type":"string","enum":["system","user","assistant"]},"content":{"type":"string"}},"required":["role","content"]}},"model":{"type":"string","description":"Model (default: gemini-2.5-flash)"},"temperature":{"type":"number","description":"Sampling temperature 0.0-2.0 (default: 0.7)"},"max_tokens":{"type":"integer","description":"Maximum response tokens (default: 4096)"}},"required":["messages"]}))

  gemini_ts.tool("chat",
    "Chat completion via Gemini. System messages become systemInstruction.",
    input_schema: chat_gemini_schema) do |data|
    msgs = data["messages"].as_a.map do |m|
      Arcana::AI::Chat::Message.new(role: m["role"].as_s, content: m.str?("content"))
    end
    request = Arcana::AI::Chat::Request.new(
      messages: msgs,
      model: data.str("model"),
      temperature: data.float("temperature", 0.7),
      max_tokens: data.int("max_tokens", 4096),
    )
    response = chat_gemini.complete(request)
    JSON::Any.new({
      "content"           => JSON::Any.new(response.content || ""),
      "model"             => JSON::Any.new(response.model),
      "finish_reason"     => JSON::Any.new(response.finish_reason || ""),
      "prompt_tokens"     => JSON::Any.new(response.prompt_tokens || 0),
      "completion_tokens" => JSON::Any.new(response.completion_tokens || 0),
    })
  end

  gemini_ts.start
end

if runware_key = ENV["RUNWARE_API_KEY"]?
  image_runware = Arcana::AI::Image::Runware.new(api_key: runware_key)

  runware_ts = Arcana::Toolset.new(
    bus: bus, directory: dir,
    address: "runware",
    name: "Runware",
    description: "Runware provider — image generation with FLUX models.",
    tags: ["runware", "flux", "generation"],
  )

  image_schema = JSON.parse(%({"type":"object","properties":{"prompt":{"type":"string","description":"Image description"},"output_path":{"type":"string","description":"File path for output image"},"width":{"type":"integer","description":"Width in pixels (default: 1024, auto-snapped to FLUX sizes)"},"height":{"type":"integer","description":"Height in pixels (default: 1024)"},"format":{"type":"string","description":"Output format: WEBP (default), PNG"},"enhance_prompt":{"type":"boolean","description":"Let provider rewrite prompt (default: false)"}},"required":["prompt","output_path"]}))

  runware_ts.tool("image",
    "Generate an image from a prompt via FLUX. Dimensions auto-snapped to FLUX aspect ratios.",
    input_schema: image_schema) do |data|
    request = Arcana::AI::Image::Request.new(
      prompt: data["prompt"].as_s,
      width: data.int("width", 1024),
      height: data.int("height", 1024),
      output_format: data.str("format", "WEBP"),
      enhance_prompt: data.bool("enhance_prompt"),
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

  runware_ts.start
end

# -- ChatAgents (autonomous LLM-backed agents) --
#
# Define agents via ARCANA_AGENTS env var as a JSON array:
#   ARCANA_AGENTS='[{"address":"helper","name":"Helper","provider":"openai","model":"gpt-4o","system_prompt":"You are helpful."}]'
#
# Or define a single agent with individual env vars:
#   ARCANA_AGENT_ADDRESS=helper
#   ARCANA_AGENT_NAME=Helper
#   ARCANA_AGENT_PROVIDER=openai       (or "anthropic", "gemini", "grok", "deepseek")
#   ARCANA_AGENT_MODEL=gpt-4o
#   ARCANA_AGENT_SYSTEM_PROMPT="You are helpful."
#   ARCANA_AGENT_MAX_TOKENS=1024
#   ARCANA_AGENT_TEMPERATURE=0.7

if agents_json = ENV["ARCANA_AGENTS"]?
  JSON.parse(agents_json).as_a.each do |agent_def|
    address = agent_def["address"].as_s
    name = agent_def.str?("name") || address
    provider_name = agent_def.str("provider", "openai")
    model = agent_def.str("model")
    system_prompt = agent_def.str("system_prompt", "You are a helpful assistant on the Arcana bus.")
    max_tokens = agent_def.int("max_tokens", 1024)
    temperature = agent_def.float("temperature", 0.7)
    tags = agent_def.str_arr("tags")
    description = agent_def.str("description", "Autonomous LLM agent")

    chat_provider = case provider_name
                    when "anthropic"
                      key = ENV["ANTHROPIC_API_KEY"]? || raise "ANTHROPIC_API_KEY required for agent #{address}"
                      Arcana::AI::Chat::Anthropic.new(api_key: key).as(Arcana::AI::Chat::Provider)
                    when "gemini"
                      key = ENV["GOOGLE_API_KEY"]? || raise "GOOGLE_API_KEY required for agent #{address}"
                      Arcana::AI::Chat::Gemini.new(api_key: key).as(Arcana::AI::Chat::Provider)
                    when "grok"
                      key = ENV["XAI_API_KEY"]? || raise "XAI_API_KEY required for agent #{address}"
                      Arcana::AI::Chat::OpenAI.new(api_key: key, endpoint: "https://api.x.ai/v1/chat/completions", model: "grok-3").as(Arcana::AI::Chat::Provider)
                    when "deepseek"
                      key = ENV["DEEPSEEK_API_KEY"]? || raise "DEEPSEEK_API_KEY required for agent #{address}"
                      Arcana::AI::Chat::OpenAI.new(api_key: key, endpoint: "https://api.deepseek.com/v1/chat/completions", model: "deepseek-chat").as(Arcana::AI::Chat::Provider)
                    else
                      key = ENV["OPENAI_API_KEY"]? || raise "OPENAI_API_KEY required for agent #{address}"
                      Arcana::AI::Chat::OpenAI.new(api_key: key).as(Arcana::AI::Chat::Provider)
                    end

    agent = Arcana::ChatAgent.new(
      bus: bus, directory: dir,
      address: address, name: name, description: description,
      provider: chat_provider,
      system_prompt: system_prompt,
      model: model, max_tokens: max_tokens, temperature: temperature,
      tags: tags,
    )
    agent.start
  end
elsif agent_address = ENV["ARCANA_AGENT_ADDRESS"]?
  provider_name = ENV["ARCANA_AGENT_PROVIDER"]? || "openai"
  chat_provider = case provider_name
                  when "anthropic"
                    key = ENV["ANTHROPIC_API_KEY"]? || raise "ANTHROPIC_API_KEY required for agent"
                    Arcana::AI::Chat::Anthropic.new(api_key: key).as(Arcana::AI::Chat::Provider)
                  when "gemini"
                    key = ENV["GOOGLE_API_KEY"]? || raise "GOOGLE_API_KEY required for agent"
                    Arcana::AI::Chat::Gemini.new(api_key: key).as(Arcana::AI::Chat::Provider)
                  when "grok"
                    key = ENV["XAI_API_KEY"]? || raise "XAI_API_KEY required for agent"
                    Arcana::AI::Chat::OpenAI.new(api_key: key, endpoint: "https://api.x.ai/v1/chat/completions", model: "grok-3").as(Arcana::AI::Chat::Provider)
                  when "deepseek"
                    key = ENV["DEEPSEEK_API_KEY"]? || raise "DEEPSEEK_API_KEY required for agent"
                    Arcana::AI::Chat::OpenAI.new(api_key: key, endpoint: "https://api.deepseek.com/v1/chat/completions", model: "deepseek-chat").as(Arcana::AI::Chat::Provider)
                  else
                    key = ENV["OPENAI_API_KEY"]? || raise "OPENAI_API_KEY required for agent"
                    Arcana::AI::Chat::OpenAI.new(api_key: key).as(Arcana::AI::Chat::Provider)
                  end

  agent = Arcana::ChatAgent.new(
    bus: bus, directory: dir,
    address: agent_address,
    name: ENV["ARCANA_AGENT_NAME"]? || agent_address,
    description: ENV["ARCANA_AGENT_DESCRIPTION"]? || "Autonomous LLM agent",
    provider: chat_provider,
    system_prompt: ENV["ARCANA_AGENT_SYSTEM_PROMPT"]? || "You are a helpful assistant on the Arcana bus.",
    model: ENV["ARCANA_AGENT_MODEL"]? || "",
    max_tokens: (ENV["ARCANA_AGENT_MAX_TOKENS"]? || "1024").to_i,
    temperature: (ENV["ARCANA_AGENT_TEMPERATURE"]? || "0.7").to_f,
  )
  agent.start
end

# -- Construct server (needed before snapshot load for token restoration) --

snapshot_file = File.join(state_dir, "state.json")
state_backend = Arcana::LocalFileBackend.new(snapshot_file)
server = Arcana::Server.new(bus, dir, host: host, port: port, state_file: state_file)
server.events = events_backend

# -- Bearer-token auth (opt-in) --
#
# Set ARCANA_AUTH_REQUIRED=1 to require a valid `Authorization: Bearer ak_...`
# header on every REST call and WebSocket upgrade (except /health). Keys are
# created via `arcana-admin key create`. This requires ARCANA_DATABASE_URL.
if ENV["ARCANA_AUTH_REQUIRED"]? == "1"
  unless Arcana::DB.enabled?
    STDERR.puts "FATAL: ARCANA_AUTH_REQUIRED=1 requires ARCANA_DATABASE_URL to be set"
    exit 1
  end
  server.auth_required = true
end

# -- Restore persisted state --

restored = 0
restored_messages = 0
unless fresh
  if Arcana::Snapshot.load(bus, dir, server, state_backend)
    restored = dir.list.size
    bus.addresses.each { |a| restored_messages += bus.pending(a) }
  elsif File.exists?(state_file)
    # Legacy migration: import old directory.json
    restored = dir.load(state_file)
    dir.list.each do |listing|
      bus.mailbox(listing.address) unless bus.has_mailbox?(listing.address)
    end
  end
end

# -- Shutdown handler: save snapshot on SIGTERM/SIGINT --

shutdown = ->(sig : Signal) do
  STDERR.puts "\nArcana shutting down — saving snapshot..."
  events_backend.try &.record(Arcana::Events::Event.new(
    type: "server.stopped",
    subject: "#{host}:#{port}",
    metadata: {"signal" => JSON::Any.new(sig.to_s)} of String => JSON::Any,
  ))
  begin
    Arcana::Snapshot.save(bus, dir, server, state_backend)
    msg_count = 0
    bus.addresses.each { |a| msg_count += bus.pending(a) }
    STDERR.puts "  Saved #{dir.list.size} listings, #{msg_count} pending messages to #{snapshot_file}"
    events_backend.try &.record(Arcana::Events::Event.new(type: "snapshot.saved", subject: snapshot_file))
  rescue ex
    STDERR.puts "  Snapshot save failed: #{ex.message}"
  end
  events_backend.try &.close
  exit 0
end

Signal::INT.trap { shutdown.call(Signal::INT) }
Signal::TERM.trap { shutdown.call(Signal::TERM) }

# -- Periodic prune of stale agent listings and inactive mailboxes --

listing_ttl = (ENV["ARCANA_AGENT_TTL"]? || "604800").to_i.seconds     # 7d default
mailbox_ttl = (ENV["ARCANA_MAILBOX_TTL"]? || "2592000").to_i.seconds  # 30d default
prune_interval = (ENV["ARCANA_PRUNE_INTERVAL"]? || "3600").to_i.seconds # hourly default

prune_now = ->{
  pruned_listings, pruned_mailboxes = bus.prune_stale(listing_ttl, mailbox_ttl)
  unless pruned_listings.empty? && pruned_mailboxes.empty?
    STDERR.puts "Pruned #{pruned_listings.size} stale listings, #{pruned_mailboxes.size} inactive mailboxes"
    pruned_listings.each { |a| STDERR.puts "  listing:  #{a}" }
    pruned_mailboxes.each { |a| STDERR.puts "  mailbox:  #{a}" }
  end
}

# Run once at startup (after snapshot load) to clear out anything stale
# left over from the previous session.
prune_now.call

# Spawn periodic prune fiber.
spawn do
  loop do
    sleep prune_interval
    begin
      prune_now.call
    rescue ex
      STDERR.puts "Prune error: #{ex.message}"
    end
  end
end

# -- Event log retention sweep --

if events_backend
  sweep_interval = (ENV["ARCANA_EVENT_SWEEP_INTERVAL"]? || "86400").to_i.seconds # 24h default
  do_sweep = ->(b : Arcana::Events::FileBackend) {
    r = b.sweep!
    if r[:compressed] > 0 || r[:purged] > 0 || r[:archived] > 0
      STDERR.puts "Event log sweep: compressed=#{r[:compressed]} purged=#{r[:purged]} archived=#{r[:archived]}"
    end
  }
  do_sweep.call(events_backend.not_nil!)
  spawn do
    loop do
      sleep sweep_interval
      begin
        do_sweep.call(events_backend.not_nil!)
      rescue ex
        STDERR.puts "Event sweep error: #{ex.message}"
      end
    end
  end
end

live_services = dir.list.select(&.kind.service?).map(&.address).sort
live_agents = dir.list.select(&.kind.agent?).map(&.address).sort

STDERR.puts "Arcana v#{Arcana::VERSION} starting on #{host}:#{port}"
STDERR.puts "  WebSocket: ws://#{host}:#{port}/bus"
STDERR.puts "  REST:      http://#{host}:#{port}/directory"
STDERR.puts "  Health:    http://#{host}:#{port}/health"
STDERR.puts "  Restored:  #{restored} listings, #{restored_messages} pending messages" if restored > 0
STDERR.puts "  Auth:      #{server.auth_required ? "ENFORCED (bearer token)" : "disabled"}"
STDERR.puts "  Services:  #{live_services.empty? ? "(none)" : live_services.join(", ")}"
STDERR.puts "  Agents:    #{live_agents.empty? ? "(none)" : live_agents.join(", ")}"
STDERR.puts "  Directory: #{dir.list.size} listings"
STDERR.puts "  Snapshot:  #{snapshot_file}"
if backend = events_backend
  STDERR.puts "  Events:    #{backend.log_dir}"
end

events_backend.try &.record(Arcana::Events::Event.new(
  type: "server.started",
  subject: "#{host}:#{port}",
  metadata: {"version" => JSON::Any.new(Arcana::VERSION)} of String => JSON::Any,
))

server.start
