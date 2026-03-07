require "../spec_helper"

describe Arcana::Chat::Response do
  describe ".from_openai_json" do
    it "parses a simple text response" do
      raw = %({
        "id": "chatcmpl-123",
        "model": "gpt-4o-mini",
        "choices": [{
          "message": {"role": "assistant", "content": "Hello!"},
          "finish_reason": "stop"
        }],
        "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
      })

      resp = Arcana::Chat::Response.from_openai_json(raw)
      resp.content.should eq("Hello!")
      resp.finish_reason.should eq("stop")
      resp.model.should eq("gpt-4o-mini")
      resp.prompt_tokens.should eq(10)
      resp.completion_tokens.should eq(5)
      resp.has_tool_calls?.should be_false
      resp.raw_json.should eq(raw)
    end

    it "parses tool calls" do
      raw = %({
        "model": "gpt-4o",
        "choices": [{
          "message": {
            "role": "assistant",
            "content": null,
            "tool_calls": [{
              "id": "call_abc",
              "type": "function",
              "function": {
                "name": "get_weather",
                "arguments": "{\\"city\\":\\"Paris\\"}"
              }
            }]
          },
          "finish_reason": "tool_calls"
        }]
      })

      resp = Arcana::Chat::Response.from_openai_json(raw)
      resp.content.should be_nil
      resp.has_tool_calls?.should be_true
      resp.tool_calls.size.should eq(1)

      tc = resp.tool_calls[0]
      tc.id.should eq("call_abc")
      tc.function.name.should eq("get_weather")
      tc.parsed_arguments["city"].as_s.should eq("Paris")
    end

    it "finds tool call by name" do
      raw = %({
        "model": "gpt-4o",
        "choices": [{
          "message": {
            "role": "assistant",
            "tool_calls": [
              {"id": "1", "type": "function", "function": {"name": "foo", "arguments": "{}"}},
              {"id": "2", "type": "function", "function": {"name": "bar", "arguments": "{}"}}
            ]
          },
          "finish_reason": "tool_calls"
        }]
      })

      resp = Arcana::Chat::Response.from_openai_json(raw)
      resp.tool_call("bar").not_nil!.id.should eq("2")
      resp.tool_call("missing").should be_nil
    end

    it "handles empty choices gracefully" do
      raw = %({"choices": []})
      resp = Arcana::Chat::Response.from_openai_json(raw)
      resp.content.should be_nil
      resp.has_tool_calls?.should be_false
    end

    it "handles missing choices key" do
      raw = %({"error": "something"})
      resp = Arcana::Chat::Response.from_openai_json(raw)
      resp.content.should be_nil
    end

    it "sets provider" do
      raw = %({"choices": [{"message": {"content": "hi"}, "finish_reason": "stop"}]})
      resp = Arcana::Chat::Response.from_openai_json(raw, provider: "custom")
      resp.provider.should eq("custom")
    end
  end
end
