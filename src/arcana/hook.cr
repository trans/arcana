require "http/client"
require "json"
require "./agent_config"

module Arcana
  # `arcana hook <event> [--agent claude|codex]`: what the Claude Code and
  # Codex session hooks run, so both agents register, check mail and sign
  # off the same way. Reads the hook's JSON payload on stdin.
  #
  # - `session-start`: registers the project's handle (from
  #   `.ai/config.yml`) under its owner token, and tells the agent, in its
  #   context, who it is on the bus and that a "held" handle is its own.
  # - `stop`: asks the agent to read waiting mail before it stops, once
  #   per change in the count.
  # - `session-end`: moves unread mail into `.ai/inbox/` as notes (when the
  #   project has `.ai/`), then marks the handle offline. The handle stays
  #   registered, so mail sent between sessions waits for the next agent.
  #
  # A hook must never break the session: a bus that is down, or any other
  # error, means no output and exit 0.
  module Hook
    EVENTS = {"session-start", "stop", "session-end"}

    # Returns the process exit code.
    def self.run(args : Array(String), input : IO = STDIN, output : IO = STDOUT, error : IO = STDERR,
                 base_url : String = ENV["ARCANA_URL"]? || "http://127.0.0.1:19118") : Int32
      event = args[0]?
      unless event && EVENTS.includes?(event)
        error.puts "usage: arcana hook <#{EVENTS.join('|')}> [--agent claude|codex]"
        return 1
      end
      agent = (i = args.index("--agent")) ? args[i + 1]? : nil
      agent ||= ENV["CLAUDE_PROJECT_DIR"]? ? "claude" : "codex"

      payload = begin
        JSON.parse(input.gets_to_end.presence || "{}")
      rescue
        JSON.parse("{}")
      end
      project_dir = ENV["CLAUDE_PROJECT_DIR"]?.try(&.presence) ||
                    payload["cwd"]?.try(&.as_s?).try(&.presence) || Dir.current

      bus = Rest.new(base_url)
      case event
      when "session-start" then session_start(bus, project_dir, output)
      when "stop"          then stop(bus, project_dir, agent, payload, output, error)
      else                      session_end(bus, project_dir, payload)
      end
    rescue ex
      error.puts "arcana hook: #{ex.message}"
      0
    end

    # -- session-start --

    def self.session_start(bus : Rest, project_dir : String, output : IO) : Int32
      cfg = begin
        AgentConfig.load(project_dir)
      rescue ex : AgentConfig::Error
        emit_context(output, "SessionStart", "Arcana: not registered: #{ex.message}")
        return 0
      end

      status, body = bus.post("/register", {
        address:     cfg.handle,
        kind:        "agent",
        description: cfg.description,
        owner_token: cfg.owner_token!,
      })
      return 0 unless status && body # bus not running

      text = case status
             when 200 then registered_text(cfg, bus, body)
             when 409 then held_text(cfg, body)
             else          "Arcana: registering #{cfg.handle} failed: #{body["error"]?.try(&.as_s?) || "status #{status}"}"
             end
      emit_context(output, "SessionStart", text)
      0
    end

    private def self.registered_text(cfg : AgentConfig, bus : Rest, body : JSON::Any) : String
      how = case body["status"]?.try(&.as_s?)
            when "yours"   then "it was already registered under this project's owner token, so the session-start hook refreshed it"
            when "claimed" then "it was registered without an owner token, so the session-start hook claimed it for this project"
            else                "the session-start hook registered it for this project"
            end
      lines = [
        "You are #{cfg.handle} on the Arcana bus: #{how}. " \
        "If Arcana says #{cfg.handle} is already registered or held, that is you, not another agent: " \
        "don't register again or pick another name. Send with from: \"#{cfg.handle}\".",
      ]
      pending = bus.pending(cfg.handle)
      if pending && pending > 0
        lines << "#{pending} message#{pending == 1 ? "" : "s"} waiting: arcana_inbox address:\"#{cfg.handle}\"."
      end
      if cfg.description.empty?
        lines << "Your listing has no description: add arcana.description to .ai/config.yml " \
                 "(or ask the user for one), so other agents know what this project's agent does."
      end
      lines.join("\n")
    end

    private def self.held_text(cfg : AgentConfig, body : JSON::Any) : String
      holder = body["listing"]?
      seen = holder.try(&.["last_seen"]?).try(&.as_s?)
      desc = holder.try(&.["description"]?).try(&.as_s?).try(&.presence)
      "Arcana: #{cfg.handle} is held under a different owner token than this project's " \
      "(#{cfg.token_path}), so you are not registered. " \
      "Holder: #{desc ? %("#{desc}") : "no description"}#{seen ? ", last seen #{seen}" : ""}. " \
      "If that is this project's agent from another checkout or machine, it can unregister it; " \
      "otherwise ask the user before using another handle."
    end

    private def self.emit_context(output : IO, event : String, text : String) : Nil
      output.puts({hookSpecificOutput: {hookEventName: event, additionalContext: text}}.to_json)
    end

    # -- stop --

    def self.stop(bus : Rest, project_dir : String, agent : String, payload : JSON::Any,
                  output : IO, error : IO) : Int32
      handle = AgentConfig.load(project_dir).handle
      if agent == "codex"
        if payload["stop_hook_active"]?.try(&.as_bool?)
          output.puts "{}"
          return 0
        end
        pending = bus.pending(handle) || 0
        if pending > 0
          reason = "You have Arcana mail (#{pending} pending message#{pending == 1 ? "" : "s"}). " \
                   "Receive the pending mail for #{handle} before stopping."
          output.puts({decision: "block", reason: reason}.to_json)
        else
          output.puts "{}"
        end
        return 0
      end

      # Claude: exit 2 shows stderr to the agent and keeps it going. Only
      # once per pending count, or an unread message would loop forever.
      pending = bus.pending(handle) || 0
      return 0 if pending == 0
      flag = mail_flag(handle)
      if File.exists?(flag) && File.read(flag).strip == pending.to_s
        File.delete(flag)
        return 0
      end
      File.write(flag, pending.to_s)
      error.puts "You have mail! (#{pending} message#{pending == 1 ? "" : "s"})"
      2
    end

    def self.mail_flag(handle : String) : String
      dir = ENV["XDG_RUNTIME_DIR"]?.try(&.presence) || Dir.tempdir
      File.join(dir, "arcana-mail-#{handle.gsub(/[^a-zA-Z0-9_-]/, "_")}")
    end

    # -- session-end --

    def self.session_end(bus : Rest, project_dir : String, payload : JSON::Any) : Int32
      # /clear ends the session and starts a new one right away; leave
      # live mail live.
      return 0 if payload["reason"]?.try(&.as_s?) == "clear"

      cfg = AgentConfig.load(project_dir)
      drain(bus, cfg) if cfg.ai_dir?
      bus.post("/presence", {address: cfg.handle, owner_token: cfg.owner_token, online: false})
      File.delete(mail_flag(cfg.handle)) if File.exists?(mail_flag(cfg.handle))
      0
    end

    # Move unread mail into `.ai/inbox/`, one note per message. Returns
    # the paths written.
    def self.drain(bus : Rest, cfg : AgentConfig) : Array(String)
      status, body = bus.post("/receive", {address: cfg.handle})
      return [] of String unless status == 200 && body
      messages = body.as_a? || return [] of String
      return [] of String if messages.empty?

      inbox = File.join(cfg.project_dir, ".ai", "inbox")
      Dir.mkdir_p(inbox)
      messages.map { |env| write_note(inbox, env) }
    end

    def self.write_note(inbox : String, env : JSON::Any) : String
      from = env["from"]?.try(&.as_s?) || "unknown"
      to = env["to"]?.try(&.as_s?) || ""
      subject = env["subject"]?.try(&.as_s?).try(&.presence)
      sent = env["timestamp"]?.try(&.as_s?)
      id = env["correlation_id"]?.try(&.as_s?).try(&.presence) || Random::Secure.hex(8)
      time = sent.try { |t| Time.parse_rfc3339(t) rescue nil } || Time.utc

      text, rest = split_payload(env["payload"]?)
      note = String.build do |io|
        io << "# " << (subject || "Arcana message from #{from}") << "\n\n"
        io << "- **From:** " << from << "\n"
        io << "- **To:** " << to << "\n" unless to.empty?
        io << "- **Sent:** " << (sent || time.to_rfc3339) << "\n"
        io << "- **Arcana correlation id:** " << id << "\n"
        io << "- Unread when the session ended, so the session-end hook moved it here from the Arcana bus.\n"
        io << "\n" << text.strip << "\n" if text
        if rest
          io << "\n```json\n" << rest.to_pretty_json << "\n```\n"
        end
      end

      slug = from.lchop('@').gsub(/[^a-zA-Z0-9-]+/, "-").strip('-')
      path = File.join(inbox, "#{time.to_s("%Y-%m-%d-%H%M%S")}-arcana-#{slug}-#{id[0, 8]}.md")
      tmp = "#{path}.tmp"
      File.write(tmp, note)
      File.rename(tmp, path)
      path
    end

    # The message text (a string payload, or its `text`/`message` field)
    # and whatever else the payload carries.
    private def self.split_payload(payload : JSON::Any?) : {String?, JSON::Any?}
      return {nil, nil} unless payload
      return {payload.as_s, nil} if payload.as_s?
      if h = payload.as_h?
        key = {"text", "message"}.find { |k| h[k]?.try(&.as_s?) }
        if key
          rest = h.reject { |k, _| k == key }
          return {h[key].as_s, rest.empty? ? nil : JSON::Any.new(rest)}
        end
      end
      payload.raw.nil? ? {nil, nil} : {nil, payload}
    end

    # The few REST calls the hooks make, with short timeouts: a hook that
    # hangs holds up the agent.
    class Rest
      def initialize(@base_url : String)
      end

      # {status, parsed body}, or {nil, nil} when the bus can't be reached.
      def post(path : String, body) : {Int32?, JSON::Any?}
        uri = URI.parse(@base_url)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 1.second
        client.read_timeout = 2.seconds
        resp = client.post(path, headers: HTTP::Headers{"Content-Type" => "application/json"}, body: body.to_json)
        {resp.status_code, (JSON.parse(resp.body) rescue nil)}
      rescue IO::Error | Socket::Error
        {nil, nil}
      ensure
        client.try(&.close)
      end

      def pending(address : String) : Int32?
        status, body = post("/peek", {address: address})
        return nil unless status == 200 && body
        body["pending"]?.try(&.as_i?)
      end
    end
  end
end
