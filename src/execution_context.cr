require "./core_ext/*"
require "./single_threaded"

{% if flag?(:preview_mt) %}
  require "./multi_threaded"
{% end %}

abstract class ExecutionContext
  @@default = uninitialized ExecutionContext

  def self.default : ExecutionContext
    @@default
  end

  def self.init_default_context : Nil
    {% if flag?(:preview_mt) %}
      @@default = MultiThreaded.default(default_workers_count)
    {% else %}
      @@default = SingleThreaded.default
    {% end %}
  end

  def self.default_workers_count : Int32
    ENV["CRYSTAL_WORKERS"]?.try(&.to_i?) || System.cpu_count.to_i
  end

  # Returns the `ExecutionContext` instance that the current thread/fiber is
  # running in.
  def self.current : self
    Thread.current.execution_context
  end

  # the following class methods are safe accessors to the unsafe methods
  # (that are protected). They're safe to access here because they always
  # operate on the current context.

  # Tells the current scheduler to suspend the current fiber, and to resume the
  # next runnable fiber. The current fiber will never be resumed; you're
  # responsible to reenqueue it.
  #
  # This method is safe as it only operates on `.current` only.
  def self.reschedule : Nil
    current.reschedule
  end

  # Tells the current execution context to suspend the current fiber and to
  # resume `fiber`. Raises `RuntimeError` if the fiber doesn't belong to the
  # current execution context.
  #
  # This method is safe as it only operates on `.current` only.
  def self.resume(fiber : Fiber) : Nil
    if fiber.execution_context == current
      current.resume(fiber)
    else
      raise RuntimeError.new("Can't resume fiber from #{fiber.execution_context} into #{current}")
    end
  end

  # Creates a new fiber then calls `#enqueue` to add it to the execution
  # context.
  #
  # May be called from any ExecutionContext (i.e. must be thread-safe).
  def spawn(name : String?, &block : ->) : Fiber
    fiber = Fiber.new(name: name, execution_context: self, &block)
    enqueue(fiber)
    fiber
  end

  # TODO: the event loop should eventually be handled by each ExecutionContext;
  #       might share an intance per context, have one per thread, ...
  abstract def event_loop : Crystal::EventLoop

  # Same as `#spawn` but with support for the legacy `same_thread` parameter. A
  # single-threaded context may accept `same_thread: true` while a
  # multi-threaded one should raise an exception.
  #
  # May be called from any ExecutionContext (i.e. must be thread-safe).
  abstract def spawn(name : String?, same_thread : Bool, &block) : Fiber

  # Enqueues a fiber to be resumed inside the execution context.
  #
  # May be called from any ExecutionContext (i.e. must be thread-safe).
  abstract def enqueue(fiber : Fiber) : Nil

  # TODO: can't stop execution context until fibers can be cancelled (?)
  # abstract def stop(*, wait : Bool = true) : Nil

  # Suspends the execution of the current fiber and resumes the next runnable
  # fiber.
  #
  # Unsafe. Must only be called on `ExecutionContext.current`. Prefer
  # `ExecutionContext.reschedule` instead.
  protected abstract def reschedule : Nil

  # Suspends the execution of the current fiber and resumes `fiber`.
  #
  # Unsafe. Must only be called on `ExecutionContext.current`. Caller must
  # ensure that the fiber indeed belongs to the current execution context.
  # Prefer `ExecutionContext.resume` instead.
  protected def resume(fiber : Fiber) : Nil
    validate_resumable(fiber)

    GC.lock_read
    current_fiber, @thread.current_fiber = @thread.current_fiber, fiber
    Fiber.swapcontext(pointerof(current_fiber.@context), pointerof(fiber.@context))
    GC.unlock_read
  end
end
