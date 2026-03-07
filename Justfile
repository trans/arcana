# Arcana — provider-agnostic AI communication library

# Generate Crystal API docs into docs/api/
docs:
    crystal docs -o docs/api/

# Run specs
test:
    crystal spec

# Check compilation without running
check:
    crystal build --no-codegen src/arcana.cr

# Build server and MCP bridge binaries
build:
    shards build

# Run the Arcana server (default port 4000)
serve port="4000":
    ARCANA_PORT={{port}} crystal run bin/arcana.cr

# Run the MCP bridge (connects to running server)
mcp url="http://127.0.0.1:4000":
    ARCANA_URL={{url}} crystal run bin/arcana-mcp.cr

# Clean generated artifacts
clean:
    rm -rf docs/api/ lib/ bin/arcana bin/arcana-mcp
