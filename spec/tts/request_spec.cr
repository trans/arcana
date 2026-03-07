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
