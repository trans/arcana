require "json"

module Arcana
  # Unified provider registry across all domains (chat, image, tts, embed).
  #
  # Providers self-register with a name and factory block. Consumers
  # create providers by name + config without knowing the concrete class.
  #
  #   Arcana::Registry.create_chat("openai", {"api_key" => "sk-..."})
  #
  class Registry
    alias Config = Hash(String, JSON::Any)

    @@chat = {} of String => Proc(Config, Chat::Provider)
    @@image = {} of String => Proc(Config, Image::Provider)
    @@tts = {} of String => Proc(Config, TTS::Provider)
    @@embed = {} of String => Proc(Config, Embed::Provider)

    # -- Registration --

    def self.register_chat(name : String, &block : Config -> Chat::Provider)
      @@chat[name] = block
    end

    def self.register_image(name : String, &block : Config -> Image::Provider)
      @@image[name] = block
    end

    def self.register_tts(name : String, &block : Config -> TTS::Provider)
      @@tts[name] = block
    end

    def self.register_embed(name : String, &block : Config -> Embed::Provider)
      @@embed[name] = block
    end

    # -- Creation --

    def self.create_chat(name : String, config : Config = Config.new) : Chat::Provider
      factory = @@chat[name]? || raise ConfigError.new("Unknown chat provider: #{name}")
      factory.call(config)
    end

    def self.create_image(name : String, config : Config = Config.new) : Image::Provider
      factory = @@image[name]? || raise ConfigError.new("Unknown image provider: #{name}")
      factory.call(config)
    end

    def self.create_tts(name : String, config : Config = Config.new) : TTS::Provider
      factory = @@tts[name]? || raise ConfigError.new("Unknown TTS provider: #{name}")
      factory.call(config)
    end

    def self.create_embed(name : String, config : Config = Config.new) : Embed::Provider
      factory = @@embed[name]? || raise ConfigError.new("Unknown embed provider: #{name}")
      factory.call(config)
    end

    # -- Discovery --

    def self.chat_providers : Array(String)
      @@chat.keys.sort
    end

    def self.image_providers : Array(String)
      @@image.keys.sort
    end

    def self.tts_providers : Array(String)
      @@tts.keys.sort
    end

    def self.embed_providers : Array(String)
      @@embed.keys.sort
    end

    # -- Config helpers --

    # Pull a string from config, with optional default.
    def self.str(config : Config, key : String, default : String = "") : String
      config[key]?.try(&.as_s?) || default
    end

    # Pull a float from config, with optional default.
    def self.float(config : Config, key : String, default : Float64 = 0.0) : Float64
      val = config[key]?
      return default unless val
      val.as_f? || val.as_i?.try(&.to_f64) || default
    end

    # Pull an int from config, with optional default.
    def self.int(config : Config, key : String, default : Int32 = 0) : Int32
      val = config[key]?
      return default unless val
      val.as_i? || val.as_f?.try(&.to_i32) || default
    end

    # Pull a bool from config, with optional default.
    def self.bool(config : Config, key : String, default : Bool = false) : Bool
      config[key]?.try(&.as_bool?) || default
    end
  end
end

# -- Built-in provider registrations --

Arcana::Registry.register_chat("openai") do |config|
  Arcana::Chat::OpenAI.new(
    api_key: Arcana::Registry.str(config, "api_key"),
    model: Arcana::Registry.str(config, "model", "gpt-4o-mini"),
    endpoint: Arcana::Registry.str(config, "endpoint", Arcana::Chat::OpenAI::ENDPOINT),
  ).as(Arcana::Chat::Provider)
end

Arcana::Registry.register_chat("anthropic") do |config|
  Arcana::Chat::Anthropic.new(
    api_key: Arcana::Registry.str(config, "api_key"),
    model: Arcana::Registry.str(config, "model", Arcana::Chat::Anthropic::DEFAULT_MODEL),
    max_tokens: Arcana::Registry.int(config, "max_tokens", Arcana::Chat::Anthropic::MAX_TOKENS_DEFAULT),
    endpoint: Arcana::Registry.str(config, "endpoint", Arcana::Chat::Anthropic::ENDPOINT),
  ).as(Arcana::Chat::Provider)
end

Arcana::Registry.register_chat("grok") do |config|
  Arcana::Chat::OpenAI.new(
    api_key: Arcana::Registry.str(config, "api_key"),
    model: Arcana::Registry.str(config, "model", "grok-3"),
    endpoint: Arcana::Registry.str(config, "endpoint", "https://api.x.ai/v1/chat/completions"),
  ).as(Arcana::Chat::Provider)
end

Arcana::Registry.register_chat("deepseek") do |config|
  Arcana::Chat::OpenAI.new(
    api_key: Arcana::Registry.str(config, "api_key"),
    model: Arcana::Registry.str(config, "model", "deepseek-chat"),
    endpoint: Arcana::Registry.str(config, "endpoint", "https://api.deepseek.com/v1/chat/completions"),
  ).as(Arcana::Chat::Provider)
end

Arcana::Registry.register_chat("gemini") do |config|
  Arcana::Chat::Gemini.new(
    api_key: Arcana::Registry.str(config, "api_key"),
    model: Arcana::Registry.str(config, "model", Arcana::Chat::Gemini::DEFAULT_MODEL),
    endpoint: Arcana::Registry.str(config, "endpoint", Arcana::Chat::Gemini::ENDPOINT),
  ).as(Arcana::Chat::Provider)
end

Arcana::Registry.register_image("openai") do |config|
  Arcana::Image::OpenAI.new(
    api_key: Arcana::Registry.str(config, "api_key"),
    model: Arcana::Registry.str(config, "model", "gpt-image-1"),
    quality: Arcana::Registry.str(config, "quality", "medium"),
  ).as(Arcana::Image::Provider)
end

Arcana::Registry.register_image("runware") do |config|
  Arcana::Image::Runware.new(
    api_key: Arcana::Registry.str(config, "api_key"),
    model: Arcana::Registry.str(config, "model", Arcana::Image::Runware::FLUX_DEV),
  ).as(Arcana::Image::Provider)
end

Arcana::Registry.register_tts("openai") do |config|
  Arcana::TTS::OpenAI.new(
    api_key: Arcana::Registry.str(config, "api_key"),
    model: Arcana::Registry.str(config, "model", "gpt-4o-mini-tts"),
  ).as(Arcana::TTS::Provider)
end

Arcana::Registry.register_embed("openai") do |config|
  Arcana::Embed::OpenAI.new(
    api_key: Arcana::Registry.str(config, "api_key"),
    model: Arcana::Registry.str(config, "model", "text-embedding-3-small"),
    endpoint: Arcana::Registry.str(config, "endpoint", Arcana::Embed::OpenAI::ENDPOINT),
  ).as(Arcana::Embed::Provider)
end

Arcana::Registry.register_embed("voyage") do |config|
  Arcana::Embed::Voyage.new(
    api_key: Arcana::Registry.str(config, "api_key"),
    model: Arcana::Registry.str(config, "model", "voyage-3"),
    endpoint: Arcana::Registry.str(config, "endpoint", Arcana::Embed::Voyage::ENDPOINT),
  ).as(Arcana::Embed::Provider)
end
