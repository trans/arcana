require "../spec_helper"

describe Arcana::Embed::Voyage do
  it "requires an API key" do
    expect_raises(Arcana::ConfigError) do
      Arcana::Embed::Voyage.new(api_key: "")
    end
  end

  it "has correct defaults" do
    provider = Arcana::Embed::Voyage.new(api_key: "test-key")
    provider.name.should eq("voyage")
    provider.model.should eq("voyage-3")
  end

  it "is registered in the registry" do
    # create_embed should not raise for a registered provider
    provider = Arcana::Registry.create_embed("voyage", {"api_key" => JSON::Any.new("test-key")})
    provider.name.should eq("voyage")
  end
end

describe Arcana::Embed::Request do
  it "supports input_type" do
    req = Arcana::Embed::Request.new(
      texts: ["hello"],
      input_type: "query",
    )
    req.input_type.should eq("query")
  end

  it "defaults input_type to nil" do
    req = Arcana::Embed::Request.new(texts: ["hello"])
    req.input_type.should be_nil
  end
end
