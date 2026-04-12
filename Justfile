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

# Run the Arcana server (default port 19118)
serve port="19118":
    ARCANA_PORT={{port}} crystal run bin/arcana.cr

# Run the MCP bridge (connects to running server)
mcp url="http://127.0.0.1:19118":
    ARCANA_URL={{url}} crystal run bin/arcana-mcp.cr

# Clean generated artifacts
clean:
    rm -rf docs/api/ lib/ bin/arcana bin/arcana-mcp

# One-shot install as a system service (creates arcana user, deploys binary,
# installs systemd unit). Run once to set up. Requires sudo.
install: build
    sudo contrib/systemd/install.sh

# Deploy a fresh binary to an already-installed service. Requires arcana
# group membership (set up by 'just install'); no sudo needed.
deploy: build
    @if [ ! -w /home/arcana/bin ]; then \
        echo "Error: /home/arcana/bin not writable. Are you in the arcana group?"; \
        echo "Run 'newgrp arcana' or log out/in, then retry."; \
        exit 1; \
    fi
    install -m 755 bin/arcana /home/arcana/bin/arcana
    @echo "Deployed. Restart with: sudo systemctl restart arcana"
