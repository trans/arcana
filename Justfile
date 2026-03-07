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

# Clean generated artifacts
clean:
    rm -rf docs/api/ lib/
