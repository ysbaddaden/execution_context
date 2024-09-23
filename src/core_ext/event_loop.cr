abstract class Crystal::EventLoop
  @[AlwaysInline]
  def self.current : self
    ExecutionContext.current.event_loop
  end
end

{% if flag?(:unix) && flag?(:evloop_libevent) %}
  class Crystal::LibEvent::EventLoop
    # Create a new resume event for a fiber.
    def create_resume_event(fiber : Fiber) : Crystal::EventLoop::Event
      event_base.new_event(-1, LibEvent2::EventFlags::None, fiber) do |s, flags, data|
        f = data.as(Fiber)
        f.execution_context.enqueue(f)
      end
    end

    # Creates a timeout_event.
    def create_timeout_event(fiber) : Crystal::EventLoop::Event
      event_base.new_event(-1, LibEvent2::EventFlags::None, fiber) do |s, flags, data|
        f = data.as(Fiber)
        if (select_action = f.timeout_select_action)
          f.timeout_select_action = nil
          select_action.time_expired(f)
        else
          f.execution_context.enqueue(f)
        end
      end
    end
  end
{% end %}

# TODO: win32
