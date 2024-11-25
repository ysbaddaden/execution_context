abstract class Crystal::EventLoop
  @[AlwaysInline]
  def self.current : self
    ExecutionContext.current.event_loop
  end
end

# the following monkey-patch a method to collect fibers instead of immediately
# enqueueing fibers while running the evloop; it avoids issues where a scheduler
# runs the evloop which enqueues fibers which try to interrupt the evloop...

{% if Crystal::EventLoop.has_constant?(:Polling) %}
  abstract class Crystal::EventLoop::Polling
    @[AlwaysInline]
    def run(runnables : Pointer(ExecutionContext::Queue), blocking : Bool) : Bool
      system_run(blocking) { |fiber| runnables.value.push(fiber) }
      true
    end
  end
{% elsif Crystal::EventLoop.has_constant?(:LibEvent) %}
  class Crystal::EventLoop::LibEvent
    @runnables : Pointer(ExecutionContext::Queue) | Nil

    def run(runnables : Pointer(ExecutionContext::Queue), blocking : Bool) : Bool
      Crystal.trace :evloop, "run", blocking: blocking ? 1 : 0
      @runnables = runnables
       run(blocking)
    ensure
      @runnables = nil
    end

    def callback_enqueue(fiber : Fiber) : Nil
      Crystal.trace :evloop, "callback_enqueue", fiber: fiber
      if runnables = @runnables
        runnables.value.push(fiber)
      else
        raise "BUG"
      end
    end

    # Create a new resume event for a fiber.
    def create_resume_event(fiber : Fiber) : Crystal::EventLoop::Event
      event_base.new_event(-1, LibEvent2::EventFlags::None, fiber) do |s, flags, data|
        f = data.as(Fiber)
        # f.execution_context.enqueue(f)
        Crystal::EventLoop.current.as(LibEvent).callback_enqueue(f)
      end
    end

    # Creates a timeout_event.
    def create_timeout_event(fiber) : Crystal::EventLoop::Event
      event_base.new_event(-1, LibEvent2::EventFlags::None, fiber) do |s, flags, data|
        f = data.as(Fiber)
        if select_action = f.timeout_select_action
          f.timeout_select_action = nil
          if select_action.time_expired?
            # f.execution_context.enqueue(f)
            Crystal::EventLoop.current.as(LibEvent).callback_enqueue(f)
          end
        else
          # f.execution_context.enqueue(f)
          Crystal::EventLoop.current.as(LibEvent).callback_enqueue(f)
        end
      end
    end
  end

  module IO::Evented
    # :nodoc:
    def resume_read(timed_out = false) : Nil
      @read_timed_out = timed_out

      if reader = @readers.get?.try &.shift?
        Crystal.trace :evloop, "resume_read", fiber: reader
        # reader.execution_context.enqueue(reader)
        Crystal::EventLoop.current.as(Crystal::EventLoop::LibEvent).callback_enqueue(reader)
      end
    end

    # :nodoc:
    def resume_write(timed_out = false) : Nil
      @write_timed_out = timed_out

      if writer = @writers.get?.try &.shift?
        Crystal.trace :evloop, "resume_write", fiber: writer
        # writer.execution_context.enqueue(writer)
        Crystal::EventLoop.current.as(Crystal::EventLoop::LibEvent).callback_enqueue(writer)
      end
    end
  end
{% elsif Crystal::EventLoop.has_constant?(:IOCP) %}
  # TODO: win32
{% end %}
