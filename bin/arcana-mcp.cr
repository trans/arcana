require "../src/arcana"

base_url = ENV["ARCANA_URL"]? || "http://127.0.0.1:19118"

mcp = Arcana::MCP.new(base_url: base_url)
mcp.run
