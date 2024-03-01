abstract class Crystal::EventLoop
  # Runs the loop, triggering activable events, then returns. Set `blocking` to
  # false to return immediately if there are no activable events, otherwise set
  # it to true to wait for activable events (blocking the current thread).
  #
  # Returns true if any event has been triggered; returns false otherwise.
  #
  # OPTIMIZE: the loop should return a fiber for the current execution context
  #           directly to skip the queue —not possible with libevent2 or maybe
  #           through a Go-like `runnext` property on the current EC?
  abstract def run(blocking : Bool) : Bool
end

{% if flag?(:unix) %}
  module Crystal::LibEvent
    struct Event
      struct Base
        # NOTE: may return `true` even if no event has been triggered (e.g.
        #       nonblocking), but `false` means that nothing was processed.
        def run(blocking : Bool) : Bool
          flags = LibEvent2::EventLoopFlags::Once
          flags |= LibEvent2::EventLoopFlags::NonBlock unless blocking
          LibEvent2.event_base_loop(@base, flags) == 0
        end
      end
    end
  end

  class Crystal::LibEvent::EventLoop < Crystal::EventLoop
    def run(blocking : Bool) : Bool
      event_base.run(blocking)
    end
  end
{% else %}
  {% raise "EventLoop patch for ExecutionContext only supports UNIX (libevent)" %}
{% end %}
