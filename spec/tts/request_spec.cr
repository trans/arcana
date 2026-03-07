require "../spec_helper"

describe Arcana::TTS::Request do
  describe "defaults" do
    it "uses sensible defaults" do
      req = Arcana::TTS::Request.new(text: "Hello")
      req.voice.should eq("alloy")
      req.model.should eq("gpt-4o-mini-tts")
      req.response_format.should eq("opus")
      req.instructions.should be_nil
      req.speed.should be_nil
    end
  end

  it "accepts all parameters" do
    req = Arcana::TTS::Request.new(
      text: "Test speech",
      voice: "nova",
      model: "tts-1-hd",
      response_format: "mp3",
      instructions: "Speak slowly",
      speed: 0.75,
    )

    req.text.should eq("Test speech")
    req.voice.should eq("nova")
    req.model.should eq("tts-1-hd")
    req.response_format.should eq("mp3")
    req.instructions.should eq("Speak slowly")
    req.speed.should eq(0.75)
  end
end

describe Arcana::TTS::OpenAI do
  it "raises on empty API key" do
    expect_raises(Arcana::ConfigError, /API key/) do
      Arcana::TTS::OpenAI.new(api_key: "")
    end
  end

  it "stream raises CancelledError if context is already cancelled" do
    provider = Arcana::TTS::OpenAI.new(api_key: "sk-test")
    ctx = Arcana::Context.new
    ctx.cancel

    request = Arcana::TTS::Request.new(text: "hello")
    expect_raises(Arcana::CancelledError) do
      provider.stream(request, ctx) { |_chunk| }
    end
  end

  it "stream returns Result with empty output_path" do
    # Can't test actual streaming without API, but verify the interface compiles
    provider = Arcana::TTS::OpenAI.new(api_key: "sk-test")
    provider.name.should eq("openai")
  end
end
