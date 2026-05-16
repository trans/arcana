require "../src/arcana"

base_url = ENV["ARCANA_URL"]? || "http://127.0.0.1:19118"
api_key = ENV["ARCANA_API_KEY"]?

mcp = Arcana::MCP.new(base_url: base_url, api_key: api_key)
mcp.run
