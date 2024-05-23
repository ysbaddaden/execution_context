module ExecutionContext
  module Scheduler
    @[AlwaysInline]
    def self.current : Scheduler
      Thread.current.current_scheduler
    end

    abstract def thread : Thread
    abstract def execution_context : ExecutionContext

    # TODO: move to ExecutionContext
    abstract def event_loop : Crystal::EventLoop

    # Instantiates a Fiber and enqueues it into the scheduler's local queue.
    @[AlwaysInline]
    def spawn(*, name : String? = nil, &block : ->) : Fiber
      Fiber.new(name, execution_context, &block).tap do |fiber|
        # Crystal.trace "sched:spawn %p", fiber.as(Void*)
        enqueue(fiber)
      end
    end

    @[AlwaysInline]
    abstract def spawn(*, name : String? = nil, same_thread : Bool, &block : ->) : Fiber

    # Suspends the execution of the current fiber and resumes the next runnable
    # fiber.
    #
    # Unsafe. Must only be called on `ExecutionContext.current`. Prefer
    # `ExecutionContext.reschedule` instead.
    #
    # FIXME: should the method be `protected` (?)
    protected abstract def enqueue(fiber : Fiber) : Nil

    # Suspends the execution of the current fiber and resumes the next runnable
    # fiber.
    #
    # Unsafe. Must only be called on `ExecutionContext.current`. Prefer
    # `ExecutionContext.reschedule` instead.
    protected abstract def reschedule : Nil

    # Suspends the execution of the current fiber and resumes `fiber`.
    #
    # The current fiber will never be resumed; you're responsible to reenqueue
    # it.
    #
    # Unsafe. Must only be called on `ExecutionContext.current`. Prefer
    # `ExecutionContext.resume` instead.
    protected abstract def resume(fiber : Fiber) : Nil

    # Switches the thread from running the current fiber to run `fiber` instead.
    #
    # Handles thread safety around fiber stacks: locks the GC to not start a
    # collection while we're switching context, releases the stack of a dead
    # fiber.
    #
    # Unsafe. Must only be called by the current scheduler. Caller must ensure
    # that the fiber indeed belongs to the current execution context, and that
    # the fiber can indeed be resumed.
    protected def swapcontext(fiber : Fiber) : Nil
      current_fiber = thread.current_fiber

      {% if @top_level.has_constant?(:PerfTools) && PerfTools.has_constant?(:FiberTrace) %}
        PerfTools::FiberTrace.track_fiber(:yield, current_fiber)
      {% end %}

      {% unless flag?(:interpreted) %}
        thread.dead_fiber = current_fiber if current_fiber.dead?
      {% end %}

      GC.lock_read
      thread.current_fiber = fiber
      Fiber.swapcontext(pointerof(current_fiber.@context), pointerof(fiber.@context))
      GC.unlock_read

      # we switched context so we can't trust `self` anymore (it is the
      # scheduler that rescheduled `fiber` which may be another scheduler) as
      # well as any other local or instance variables (e.g. we must resolve
      # `Thread.current` again)

      {% unless flag?(:interpreted) %}
        if fiber = Thread.current.dead_fiber?
          fiber.execution_context.stack_pool.release(fiber.@stack)
        end
      {% end %}
    end

    def unblock : NoReturn
      raise NotImplementedError.new("#{self.class.name}#unblock")
    end
  end
end
