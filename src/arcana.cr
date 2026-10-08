require "json"
require "arcana-core"
require "arcana-ai"

require "./arcana/actor"
require "./arcana/chat_agent"
require "./arcana/supervisor"
require "./arcana/server"
require "./arcana/snapshot"
require "./arcana/help"
require "./arcana/mcp"
require "./arcana/agent_config"
require "./arcana/hook"
require "./arcana/markdown"
require "./arcana/db"
require "./arcana/db/migrate"
require "./arcana/auth"

module Arcana
  VERSION = "0.32.1"
end
