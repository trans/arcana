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

# Build the Arch .pkg.tar.zst via makepkg. Output left in pkg/.
pkg:
    cd pkg && rm -rf src pkg arcana-*.tar.gz *.pkg.tar.zst
    cd pkg && makepkg -f

# Build the Arch package, install it via pacman, and restart arcana.
# Requires sudo.
install-pkg: pkg
    sudo pacman -U --noconfirm pkg/arcana-[0-9]*-x86_64.pkg.tar.zst
    sudo systemctl restart arcana
    @echo "Installed. Verify with: arcana --version && systemctl status arcana"

# Register arcana-mcp with Claude Code at user scope, so every Claude
# instance on this machine gets it without per-repo .mcp.json. Requires
# arcana-mcp on PATH (installed via `just install-pkg` or `just install`).
# For an auth-enforcing server, append `-e ARCANA_API_KEY=ak_...`.
mcp-add:
    claude mcp add arcana --scope user -- arcana-mcp

# Remove the user-scope arcana MCP registration.
mcp-remove:
    claude mcp remove arcana --scope user

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
