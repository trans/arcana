require "../spec_helper"

# Expose parse_response for testing without API calls.
class Arcana::Chat::Anthropic
  def test_parse_response(body : String, payload : String = "{}") : Arcana::Chat::Response
    parse_response(body, payload)
  end
end

describe Arcana::Chat::Anthropic do
  describe "registry" do
    it "is registered as a chat provider" do
      Arcana::Registry.chat_providers.should contain("anthropic")
    end
  end

  describe "initialization" do
    it "raises on empty API key" do
      expect_raises(Arcana::ConfigError, /API key/) do
        Arcana::Chat::Anthropic.new(api_key: "")
      end
    end

    it "uses default model" do
      provider = Arcana::Chat::Anthropic.new(api_key: "sk-test")
      provider.model.should eq(Arcana::Chat::Anthropic::DEFAULT_MODEL)
      provider.name.should eq("anthropic")
    end
  end

  describe "response parsing" do
    provider = Arcana::Chat::Anthropic.new(api_key: "sk-test")

    it "parses a simple text response" do
      body = %({
        "id": "msg_123",
        "type": "message",
        "role": "assistant",
        "model": "claude-sonnet-4-20250514",
        "content": [{"type": "text", "text": "Hello!"}],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 10, "output_tokens": 5}
      })

      resp = provider.test_parse_response(body)
      resp.content.should eq("Hello!")
      resp.finish_reason.should eq("stop")
      resp.model.should eq("claude-sonnet-4-20250514")
      resp.provider.should eq("anthropic")
      resp.prompt_tokens.should eq(10)
      resp.completion_tokens.should eq(5)
      resp.has_tool_calls?.should be_false
    end

    it "parses tool use response" do
      body = %({
        "id": "msg_456",
        "type": "message",
        "role": "assistant",
        "model": "claude-sonnet-4-20250514",
        "content": [
          {"type": "text", "text": "Let me check."},
          {"type": "tool_use", "id": "toolu_1", "name": "get_weather", "input": {"city": "Tokyo"}}
        ],
        "stop_reason": "tool_use",
        "usage": {"input_tokens": 20, "output_tokens": 15}
      })

      resp = provider.test_parse_response(body)
      resp.content.should eq("Let me check.")
      resp.finish_reason.should eq("tool_calls")
      resp.has_tool_calls?.should be_true
      resp.tool_calls.size.should eq(1)

      tc = resp.tool_calls[0]
      tc.id.should eq("toolu_1")
      tc.function.name.should eq("get_weather")
      tc.parsed_arguments["city"].as_s.should eq("Tokyo")
    end

    it "maps stop_reason to OpenAI-compatible finish_reason" do
      {"end_turn" => "stop", "tool_use" => "tool_calls", "max_tokens" => "length"}.each do |anthropic, expected|
        body = %({
          "content": [{"type": "text", "text": "x"}],
          "stop_reason": "#{anthropic}",
          "model": "test"
        })
        resp = provider.test_parse_response(body)
        resp.finish_reason.should eq(expected)
      end
    end

    it "extracts prompt caching tokens" do
      body = %({
        "id": "msg_789",
        "type": "message",
        "role": "assistant",
        "model": "claude-sonnet-4-20250514",
        "content": [{"type": "text", "text": "Cached!"}],
        "stop_reason": "end_turn",
        "usage": {"input_tokens": 100, "output_tokens": 20, "cache_read_input_tokens": 80, "cache_creation_input_tokens": 15}
      })

      resp = provider.test_parse_response(body)
      resp.prompt_tokens.should eq(100)
      resp.completion_tokens.should eq(20)
      resp.cache_read_tokens.should eq(80)
      resp.cache_creation_tokens.should eq(15)
    end

    it "handles missing cache tokens gracefully" do
      body = %({
        "content": [{"type": "text", "text": "No cache"}],
        "stop_reason": "end_turn",
        "model": "test",
        "usage": {"input_tokens": 10, "output_tokens": 5}
      })

      resp = provider.test_parse_response(body)
      resp.cache_read_tokens.should be_nil
      resp.cache_creation_tokens.should be_nil
    end

    it "stores raw request and response" do
      body = %({"content": [{"type": "text", "text": "hi"}], "stop_reason": "end_turn", "model": "test"})
      resp = provider.test_parse_response(body, "the-request")
      resp.raw_request.should eq("the-request")
      resp.raw_json.should eq(body)
    end
  end
end
