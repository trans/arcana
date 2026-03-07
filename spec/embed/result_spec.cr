require "../spec_helper"

describe Arcana::Embed::Result do
  it "stores embeddings and metadata" do
    result = Arcana::Embed::Result.new(
      embeddings: [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]],
      token_counts: [5, 7],
      total_tokens: 12,
      model: "text-embedding-3-small",
      provider: "openai",
    )

    result.embeddings.size.should eq(2)
    result.total_tokens.should eq(12)
    result.model.should eq("text-embedding-3-small")
  end

  describe "#embedding" do
    it "returns first embedding for single-text results" do
      result = Arcana::Embed::Result.new(
        embeddings: [[0.1, 0.2, 0.3]],
      )
      result.embedding.should eq([0.1, 0.2, 0.3])
    end
  end

  describe "#dimensions" do
    it "returns vector dimension count" do
      result = Arcana::Embed::Result.new(
        embeddings: [[0.1, 0.2, 0.3, 0.4]],
      )
      result.dimensions.should eq(4)
    end

    it "returns 0 for empty results" do
      result = Arcana::Embed::Result.new(embeddings: [] of Array(Float64))
      result.dimensions.should eq(0)
    end
  end
end
