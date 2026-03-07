require "./spec_helper"

describe Arcana::Registry do
  describe "built-in providers" do
    it "lists openai as a chat provider" do
      Arcana::Registry.chat_providers.should contain("openai")
    end

    it "lists openai and runware as image providers" do
      Arcana::Registry.image_providers.should contain("openai")
      Arcana::Registry.image_providers.should contain("runware")
    end

    it "lists openai as a TTS provider" do
      Arcana::Registry.tts_providers.should contain("openai")
    end

    it "lists openai as an embed provider" do
      Arcana::Registry.embed_providers.should contain("openai")
    end
  end

  describe "creation errors" do
    it "raises ConfigError for unknown chat provider" do
      expect_raises(Arcana::ConfigError, /Unknown chat provider/) do
        Arcana::Registry.create_chat("nonexistent")
      end
    end

    it "raises ConfigError for unknown image provider" do
      expect_raises(Arcana::ConfigError, /Unknown image provider/) do
        Arcana::Registry.create_image("nonexistent")
      end
    end

    it "raises ConfigError for unknown TTS provider" do
      expect_raises(Arcana::ConfigError, /Unknown TTS provider/) do
        Arcana::Registry.create_tts("nonexistent")
      end
    end

    it "raises ConfigError for unknown embed provider" do
      expect_raises(Arcana::ConfigError, /Unknown embed provider/) do
        Arcana::Registry.create_embed("nonexistent")
      end
    end
  end

  describe "config helpers" do
    config = Arcana::Registry::Config{
      "name"  => JSON::Any.new("test"),
      "count" => JSON::Any.new(42_i64),
      "rate"  => JSON::Any.new(0.75),
      "flag"  => JSON::Any.new(true),
    }

    it ".str extracts strings" do
      Arcana::Registry.str(config, "name").should eq("test")
      Arcana::Registry.str(config, "missing", "default").should eq("default")
    end

    it ".int extracts integers" do
      Arcana::Registry.int(config, "count").should eq(42)
      Arcana::Registry.int(config, "missing", 99).should eq(99)
    end

    it ".float extracts floats" do
      Arcana::Registry.float(config, "rate").should eq(0.75)
      Arcana::Registry.float(config, "missing", 1.0).should eq(1.0)
    end

    it ".bool extracts booleans" do
      Arcana::Registry.bool(config, "flag").should be_true
      Arcana::Registry.bool(config, "missing").should be_false
    end
  end
end
