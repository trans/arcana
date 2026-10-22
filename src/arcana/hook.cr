require "digest/sha256"
require "http/client"
require "json"
require "./agent_config"

module Arcana
  # `arcana hook <event> [--agent claude|codex]`: what the Claude Code and
  # Codex session hooks run, so both agents register, check mail and sign
  # off the same way. Reads the hook's JSON payload on stdin.
  #
  # - `session-start`: registers the project's handle (from
  #   `.ai/config.yml` in the nearest directory with `.ai/`, see
  #   `AgentConfig.project_root`) under its owner token, and tells the agent, in its
  #   context, who it is on the bus and that a "held" handle is its own.
  # - `stop`: asks the agent to read waiting mail before it stops, once
  #   per change in the count.
  # - `session-end`: moves unread mail into `.ai/mail/inbox/` as notes (when
  #   the project has `.ai/`), then marks the handle offline. The handle stays
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
      start = ENV["CLAUDE_PROJECT_DIR"]?.try(&.presence) ||
              payload["cwd"]?.try(&.as_s?).try(&.presence) || Dir.current
      project_dir = AgentConfig.project_root(start)

      bus = Rest.new(base_url)
      case event
      when "session-start" then session_start(bus, project_dir, output, AgentConfig.broken_link(start))
      when "stop"          then stop(bus, project_dir, agent, payload, output, error)
      else                      session_end(bus, project_dir, payload)
      end
    rescue ex
      error.puts "arcana hook: #{ex.message}"
      0
    end

    # -- session-start --

    # `broken_link` is an `.ai` link on the way to the project whose target
    # is gone (`AgentConfig.broken_link`): the agent is told, whether or not
    # the bus is up, since it means the session is likely in the wrong
    # project.
    def self.session_start(bus : Rest, project_dir : String, output : IO, broken_link : String? = nil) : Int32
      warning = broken_link.try do |link|
        "Warning: #{link} is a link to #{File.readlink(link)}, which doesn't exist, so this session " \
        "isn't in the project the link was meant to lead to: it is in #{project_dir}. " \
        "Tell the user; the link needs fixing."
      end
      cfg = begin
        AgentConfig.load(project_dir)
      rescue ex : AgentConfig::Error
        emit_context(output, "SessionStart", [warning, "Arcana: not registered: #{ex.message}"].compact.join("\n"))
        return 0
      end

      # Signed with the project's key, so the handle is held by it: the
      # first time, the owner token shown moves the handle to the key.
      key_warning = begin
        bus.key = cfg.key!
        nil
      rescue ex
        "Arcana: this project's key can't be read (#{ex.message}), so the session-start hook registered without it."
      end
      warning = [warning, key_warning].compact.join("\n").presence
      status, body = bus.post("/register", {
        address:     cfg.handle,
        kind:        "agent",
        description: cfg.description,
        owner_token: cfg.owner_token!,
      })
      unless status && body # bus not running
        emit_context(output, "SessionStart", warning) if warning
        return 0
      end

      text = case status
             when 200 then registered_text(cfg, bus, body)
             when 409 then held_text(cfg, body)
             else          "Arcana: registering #{cfg.handle} failed: #{body["error"]?.try(&.as_s?) || "status #{status}"}"
             end
      emit_context(output, "SessionStart", [warning, text].compact.join("\n"))
      0
    end

    private def self.registered_text(cfg : AgentConfig, bus : Rest, body : JSON::Any) : String
      how = case body["status"]?.try(&.as_s?)
            when "yours"   then "it was already registered under this project's owner token, so the session-start hook refreshed it"
            when "claimed" then "it was registered without an owner token, so the session-start hook claimed it for this project"
            when "moved"   then "it was registered under this project's owner token, and the session-start hook has now moved it to the project's key"
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
        lines << "Your listing has no description: add a description to .ai/config.yml " \
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

    # Keeps the agent going once per change in the count, so mail it
    # leaves for later never loops it: Claude by exit 2 (stderr is shown to
    # the agent), Codex by `decision: block`.
    def self.stop(bus : Rest, project_dir : String, agent : String, payload : JSON::Any,
                  output : IO, error : IO) : Int32
      handle = AgentConfig.load(project_dir).handle
      pending = bus.pending(handle) || 0
      flag = mail_flag(handle)
      told = File.exists?(flag) && File.read(flag).strip == pending.to_s
      if pending == 0 || told
        File.delete(flag) if pending == 0 && File.exists?(flag)
        output.puts "{}" if agent == "codex"
        return 0
      end

      File.write(flag, pending.to_s)
      text = "You have mail! (#{pending} message#{pending == 1 ? "" : "s"} on the Arcana bus " \
             "for #{handle}: arcana_inbox, then arcana_receive.)"
      if agent == "codex"
        output.puts({decision: "block", reason: text}.to_json)
        return 0
      end
      error.puts text
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
      bus.key = (cfg.key rescue nil)
      drain(bus, cfg) if cfg.ai_dir?
      bus.post("/presence", {address: cfg.handle, owner_token: cfg.owner_token, online: false})
      File.delete(mail_flag(cfg.handle)) if File.exists?(mail_flag(cfg.handle))
      0
    end

    # Move unread mail into `.ai/mail/inbox/`, one note per message (see the
    # dot-ai skill's mail conventions). Returns the paths written.
    def self.drain(bus : Rest, cfg : AgentConfig) : Array(String)
      status, body = bus.post("/receive", {address: cfg.handle})
      return [] of String unless status == 200 && body
      messages = body.as_a? || return [] of String
      return [] of String if messages.empty?

      inbox = File.join(cfg.project_dir, ".ai", "mail", "inbox")
      Dir.mkdir_p(inbox)
      messages.map { |env| write_note(inbox, env) }
    end

    # A mail file: header lines, a blank line, then the message. Named
    # time first (dot-ai), by the time it was sent in UTC, the sender, the
    # subject as a topic, and the message's id:
    # `20261013-190539Z-@ipck--dot-ai-0.3-b6c3b174.md`, or
    # `<time>-<sender>--<id>.md` without a subject. The id is the one the
    # sender carried with the message (`message_id`); only a message that
    # came without one, from an older Arcana or another client, is given
    # the first 8 characters of its correlation id. A reply's `Re:` comes
    # along. Written here at session end, and by the MCP bridge's
    # `arcana_receive` (see `MCP#write_inbox_files`). `write_sent` files
    # the sender's copy.
    def self.write_note(inbox : String, env : JSON::Any) : String
      from = env["from"]?.try(&.as_s?) || "unknown"
      to = env["to"]?.try(&.as_s?) || ""
      subject = env["subject"]?.try(&.as_s?).try(&.gsub(/[\r\n]+/, " ").strip.presence)
      sent = env["timestamp"]?.try(&.as_s?)
      id = env["id"]?.try(&.as_s?).try { |i| i if i.matches?(Envelope::MESSAGE_ID) } ||
           (env["correlation_id"]?.try(&.as_s?).try(&.presence) || Random::Secure.hex(8))[0, 8]
      re = env["re"]?.try(&.as_s?).try { |r| r if r.matches?(Envelope::REPLY_TO) }
      time = sent.try { |t| Time.parse_rfc3339(t) rescue nil } || Time.utc

      body = mail_body(env["payload"]?)
      note = String.build do |io|
        io << "From: " << from << "\n"
        io << "To: " << to << "\n" unless to.empty?
        io << "Sent: " << (sent || time.to_rfc3339) << "\n"
        io << "Subject: " << subject << "\n" if subject
        io << "Id: " << id << "\n"
        io << "Re: " << re << "\n" if re
        io << "Via: arcana\n"
        io << "\n" << body if body
      end

      tail = [mail_topic(subject), id].compact.join('-')
      name = "#{time.to_utc.to_s("%Y%m%d-%H%M%SZ")}-#{name_address(from)}--#{tail}.md"
      write_mail(inbox, name, note)
    end

    # A message's id (dot-ai): the first 8 hex digits of the SHA-256 of
    # the sender's address, the outbound file's name and the message as
    # its file holds it (`mail_body`), joined by newlines. The same on the
    # sender's copy and the recipient's, whatever carries the message, so
    # anyone with the sent copy can compute it again.
    def self.message_id(from : String, name : String, message : String) : String
      Digest::SHA256.hexdigest("#{from}\n#{name}\n#{message}")[0, 8]
    end

    # The name a message sent over the bus has in `sent/` (dot-ai): the
    # time it was written in UTC, the recipient and the subject as a topic
    # (`20261017-120000Z-@ipck--message-ids.md`), or `<time>-<address>.md`
    # without a subject. A name already in use in `mail_dir`'s drafts,
    # outbox or sent gets `-2`, `-3` and so on. Without `mail_dir` (no
    # `mail/` to file in), the name the copy would have, from which the
    # id is still taken.
    def self.sent_name(mail_dir : String?, to : String, subject : String?, time : Time) : String
      topic = mail_topic(subject)
      base = "#{time.to_utc.to_s("%Y%m%d-%H%M%SZ")}-#{name_address(to)}#{topic ? "--#{topic}" : ""}"
      name = "#{base}.md"
      return name unless mail_dir
      n = 1
      while {"drafts", "outbox", "sent"}.any? { |d| File.exists?(File.join(mail_dir, d, name)) }
        name = "#{base}-#{n += 1}.md"
      end
      name
    end

    # The sender's copy of a message sent over the bus, filed in `sent/`
    # under `name` (`sent_name`) as local delivery files the outbox's: a
    # `Re:` line if it answers something, `Sent:` and `Id:`, a blank line,
    # then the message (`mail_body`).
    def self.write_sent(sent : String, name : String, message : String, time : Time,
                        id : String, re : String? = nil) : String
      note = String.build do |io|
        io << "Re: " << re << "\n" if re
        io << "Sent: " << time.to_utc.to_rfc3339 << " via arcana\n"
        io << "Id: " << id << "\n"
        io << "\n" << message
      end
      write_mail(sent, name, note)
    end

    # An address as a file name has it. `#` stays, so a topic's
    # notification is named by the topic.
    private def self.name_address(address : String) : String
      name = address.gsub(/[^@#a-zA-Z0-9_.-]+/, "-").gsub(/-{2,}/, "-").strip('-')
      name.empty? ? "unknown" : name
    end

    # Readers skip hidden names, so no one reads half a message.
    private def self.write_mail(dir : String, name : String, note : String) : String
      path = File.join(dir, name)
      tmp = File.join(dir, ".#{name}")
      File.write(tmp, note)
      File.rename(tmp, path)
      path
    end

    # A subject as a file name's topic: lowercased, each run of anything
    # but `a-z`, `0-9`, `.` and `-` turned into `-`, trimmed of `-`, and
    # cut to 50 characters. Nil when nothing is left.
    def self.mail_topic(subject : String?) : String?
      return nil unless subject
      subject.downcase.gsub(/[^a-z0-9.-]+/, "-").strip('-')[0, 50].rstrip('-').presence
    end

    # A message as a mail file holds it, after the header lines and their
    # blank line: its text, then anything else the payload carries as a
    # JSON block. Nil for an empty payload. The sender's copy in `sent/`
    # (`MCP#write_sent_file`) and the recipient's inbox file hold the same.
    def self.mail_body(payload : JSON::Any?) : String?
      text, rest = split_payload(payload)
      parts = [] of String
      parts << "#{text.strip}\n" if text
      parts << "```json\n#{rest.to_pretty_json}\n```\n" if rest
      parts.empty? ? nil : parts.join("\n")
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
      # The project's key, which signs each request once set.
      property key : Key?

      def initialize(@base_url : String)
      end

      # {status, parsed body}, or {nil, nil} when the bus can't be reached.
      def post(path : String, body) : {Int32?, JSON::Any?}
        uri = URI.parse(@base_url)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 1.second
        client.read_timeout = 2.seconds
        json = body.to_json
        headers = HTTP::Headers{"Content-Type" => "application/json"}
        if key = @key
          headers.merge!(Signing.sign_request(key, "POST", "#{uri.host}:#{uri.port || 80}", path, json))
        end
        resp = client.post(path, headers: headers, body: json)
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
