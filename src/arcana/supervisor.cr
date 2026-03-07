module Arcana
  # Monitors actors and restarts them on crash.
  #
  # Follows OTP supervision principles: actors are expected to crash,
  # and the supervisor brings them back.
  #
  #   sup = Arcana::Supervisor.new(bus, dir,
  #     strategy: :one_for_one,
  #     max_restarts: 3,
  #     within: 5.seconds,
  #   )
  #   sup.supervise(agent1)
  #   sup.supervise(agent2)
  #   sup.start
  #
  class Supervisor
    enum Strategy
      OneForOne  # restart only the crashed actor
      OneForAll  # restart all actors if any one crashes
    end

    getter strategy : Strategy
    @actors = [] of Actor
    @restart_log = {} of String => Array(Time)
    @mutex = Mutex.new
    @running = false

    def initialize(
      @bus : Bus,
      @directory : Directory,
      @strategy : Strategy = Strategy::OneForOne,
      @max_restarts : Int32 = 3,
      @within : Time::Span = 5.seconds,
    )
    end

    # Add an actor to be supervised. Registers and starts it.
    def supervise(actor : Actor)
      @running = true
      @mutex.synchronize { @actors << actor }
      actor.register
      spawn_monitored(actor)
    end

    # Start all supervised actors.
    def start
      @running = true
      @mutex.synchronize do
        @actors.each do |actor|
          actor.register
          spawn_monitored(actor)
        end
      end
    end

    # Stop all supervised actors.
    def stop
      @running = false
      @mutex.synchronize do
        @actors.each(&.stop)
      end
    end

    # List supervised actor addresses.
    def children : Array(String)
      @mutex.synchronize { @actors.map(&.address) }
    end

    private def spawn_monitored(actor : Actor)
      spawn do
        begin
          actor.run
        rescue ex
          handle_crash(actor, ex) if @running
        end
      end
    end

    private def handle_crash(actor : Actor, error : Exception)
      return unless @running
      return unless can_restart?(actor)

      case @strategy
      when Strategy::OneForOne
        spawn_monitored(actor)
      when Strategy::OneForAll
        @mutex.synchronize do
          @actors.each do |a|
            a.stop unless a.address == actor.address
          end
          @actors.each do |a|
            a.register
            spawn_monitored(a)
          end
        end
      end
    end

    # Track restarts and enforce max_restarts within the time window.
    private def can_restart?(actor : Actor) : Bool
      now = Time.utc
      cutoff = now - @within

      @mutex.synchronize do
        log = @restart_log[actor.address] ||= [] of Time
        log.reject! { |t| t < cutoff }

        if log.size >= @max_restarts
          false
        else
          log << now
          true
        end
      end
    end
  end
end
