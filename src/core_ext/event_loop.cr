abstract class Crystal::EventLoop
  # Runs the loop, triggering activable events, then returns.
  #
  # Set `blocking` to false to return immediately if there are no activable
  # events. Set it to true to wait for activable events (blocking the current
  # thread).
  #
  # Returns `true` on normal returns (e.g. has activated events, has pending
  # events but nonblocking run) and `false` when there are no registered events.
  #
  # FIXME: what to do when the event loop has no registered event to wait for?
  #        in that situation libevent2 returns a specific value (1) and breaks
  #        the loop.
  #
  # OPTIMIZE: the loop should return the next runnable fiber (for the current
  #           EC); it could be resumed directly, instead of going through the
  #           schedulers queues —not possible with libevent2... or maybe through
  #           a Go-like `runnext` property on the current scheduler (?)
  abstract def run(blocking : Bool) : Bool

  # Tells a blocking run loop to no longer wait for events to activate. It may
  # for example enqueue a NOOP event with an immediate timeout. Having activated
  # an event, the loop shall return, allowing the thread to continue.
  #
  # Should be a NOOP when the loop isn't running or is running in a nonblocking
  # mode.
  abstract def interrupt_loop : Nil
end

{% if flag?(:unix) %}
  lib LibEvent2
    fun event_base_loopexit(EventBase, LibC::Timeval*) : LibC::Int

    # @[Flags]
    # enum EventLoopFlags
    #   NoExitOnEmpty = 0x04
    # end
  end

  module Crystal::LibEvent
    struct Event
      struct Base
        # NOTE: may return `true` even if no event has been triggered (e.g.
        #       nonblocking), but `false` means that nothing was processed.
        def loop(blocking : Bool, exit_on_empty : Bool) : Bool
          flags = LibEvent2::EventLoopFlags::Once
          flags |= LibEvent2::EventLoopFlags::NonBlock unless blocking
          flags |= LibEvent2::EventLoopFlags.new(0x04) unless exit_on_empty
          LibEvent2.event_base_loop(@base, flags) == 0
        end

        def loop_exit : Nil
          LibEvent2.event_base_loopexit(@base, nil)
        end
      end
    end
  end

  class Crystal::LibEvent::EventLoop < Crystal::EventLoop
    @[AlwaysInline]
    def run(blocking : Bool, block_when_empty : Bool = false) : Bool
      event_base.loop(blocking, block_when_empty)
    end

    @[AlwaysInline]
    def interrupt_loop : Nil
      event_base.loop_exit
    end
  end
{% else %}
  {% raise "EventLoop patch for ExecutionContext only supports UNIX (libevent)" %}
{% end %}
