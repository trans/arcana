require "spec"
require "file_utils"
require "../src/arcana"

# The person's git config says who carries their mail and where their
# projects are (`Arcana::Mail`): the specs get an empty one of their own.
SPEC_GITCONFIG = File.tempname("arcana-spec-gitconfig")
File.write(SPEC_GITCONFIG, "")
ENV["GIT_CONFIG_GLOBAL"] = SPEC_GITCONFIG
at_exit { File.delete?(SPEC_GITCONFIG) }

# Nor do they see this machine's dot-ai, whose being there decides whether
# Arcana writes mail files (`Mail.carries?`), or keep session records
# among the person's own (`Mail::Sessions`): a place of their own for each.
SPEC_HOME = File.tempname("arcana-spec-home")
{"claude", "codex", "state"}.each { |d| Dir.mkdir_p(File.join(SPEC_HOME, d)) }
ENV["CLAUDE_CONFIG_DIR"] = File.join(SPEC_HOME, "claude")
ENV["CODEX_HOME"] = File.join(SPEC_HOME, "codex")
ENV["XDG_STATE_HOME"] = File.join(SPEC_HOME, "state")
ENV["PATH"] = (ENV["PATH"]? || "").split(':').reject { |d| File.exists?(File.join(d, "dot-ai")) }.join(':')
ENV.delete("DOT_AI_BY")
at_exit { FileUtils.rm_rf(SPEC_HOME) }
