require "../spec_helper"

describe Arcana::Embed::Request do
  describe "defaults" do
    it "uses sensible defaults" do
      req = Arcana::Embed::Request.new(texts: ["hello"])
      req.texts.should eq(["hello"])
      req.model.should eq("")
      req.trace_tags.should be_nil
    end
  end

  describe ".single" do
    it "wraps a single text in an array" do
      req = Arcana::Embed::Request.single("test", model: "text-embedding-3-small")
      req.texts.should eq(["test"])
      req.model.should eq("text-embedding-3-small")
    end
  end
end
