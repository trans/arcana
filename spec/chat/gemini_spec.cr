require "../spec_helper"

# Expose parse_response for testing without API calls.
class Arcana::Chat::Gemini
  def test_parse_response(body : String, payload : String = "{}") : Arcana::Chat::Response
    parse_response(body, payload)
  end
end

describe Arcana::Chat::Gemini do
  describe "registry" do
    it "is registered as a chat provider" do
      Arcana::Registry.chat_providers.should contain("gemini")
    end
  end

  describe "initialization" do
    it "raises on empty API key" do
      expect_raises(Arcana::ConfigError, /API key/) do
        Arcana::Chat::Gemini.new(api_key: "")
      end
    end

    it "uses default model" do
      provider = Arcana::Chat::Gemini.new(api_key: "test-key")
      provider.model.should eq(Arcana::Chat::Gemini::DEFAULT_MODEL)
      provider.name.should eq("gemini")
    end
  end

  describe "response parsing" do
    provider = Arcana::Chat::Gemini.new(api_key: "test-key")

    it "parses a simple text response" do
      body = %({
        "candidates": [{
          "content": {
            "parts": [{"text": "Hello!"}],
            "role": "model"
          },
          "finishReason": "STOP"
        }],
        "usageMetadata": {
          "promptTokenCount": 10,
          "candidatesTokenCount": 5,
          "totalTokenCount": 15
        },
        "modelVersion": "gemini-2.5-flash"
      })

      resp = provider.test_parse_response(body)
      resp.content.should eq("Hello!")
      resp.finish_reason.should eq("stop")
      resp.model.should eq("gemini-2.5-flash")
      resp.provider.should eq("gemini")
      resp.prompt_tokens.should eq(10)
      resp.completion_tokens.should eq(5)
      resp.has_tool_calls?.should be_false
    end

    it "parses function call response" do
      body = %({
        "candidates": [{
          "content": {
            "parts": [
              {"text": "Let me check the weather."},
              {"functionCall": {"name": "get_weather", "args": {"city": "Tokyo"}}}
            ],
            "role": "model"
          },
          "finishReason": "STOP"
        }],
        "usageMetadata": {
          "promptTokenCount": 20,
          "candidatesTokenCount": 15,
          "totalTokenCount": 35
        },
        "modelVersion": "gemini-2.5-flash"
      })

      resp = provider.test_parse_response(body)
      resp.content.should eq("Let me check the weather.")
      resp.has_tool_calls?.should be_true
      resp.tool_calls.size.should eq(1)

      tc = resp.tool_calls[0]
      tc.function.name.should eq("get_weather")
      tc.parsed_arguments["city"].as_s.should eq("Tokyo")
    end

    it "maps finishReason to normalized finish_reason" do
      {"STOP" => "stop", "MAX_TOKENS" => "length", "SAFETY" => "safety"}.each do |gemini, expected|
        body = %({
          "candidates": [{
            "content": {"parts": [{"text": "x"}], "role": "model"},
            "finishReason": "#{gemini}"
          }],
          "modelVersion": "test"
        })
        resp = provider.test_parse_response(body)
        resp.finish_reason.should eq(expected)
      end
    end

    it "handles missing usage metadata" do
      body = %({
        "candidates": [{
          "content": {"parts": [{"text": "hi"}], "role": "model"},
          "finishReason": "STOP"
        }],
        "modelVersion": "test"
      })

      resp = provider.test_parse_response(body)
      resp.prompt_tokens.should be_nil
      resp.completion_tokens.should be_nil
    end

    it "stores raw request and response" do
      body = %({
        "candidates": [{
          "content": {"parts": [{"text": "hi"}], "role": "model"},
          "finishReason": "STOP"
        }],
        "modelVersion": "test"
      })
      resp = provider.test_parse_response(body, "the-request")
      resp.raw_request.should eq("the-request")
      resp.raw_json.should eq(body)
    end
  end
end
