require "spec"
require "../src/arcana"

# The machine's git config says who carries its mail and where its
# projects are (`Arcana::Mail`): the specs get an empty one of their own.
SPEC_GITCONFIG = File.tempname("arcana-spec-gitconfig")
File.write(SPEC_GITCONFIG, "")
ENV["GIT_CONFIG_GLOBAL"] = SPEC_GITCONFIG
at_exit { File.delete?(SPEC_GITCONFIG) }
