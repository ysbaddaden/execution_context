require "./core_ext/*"
require "./scheduler"
require "./single_threaded"
require "./isolated"
require "./multi_threaded"
require "./monitor"

{% raise "ERROR: execution contexts require the `preview_mt` compilation flag" unless flag?(:preview_mt) %}

module ExecutionContext
  @@default : ExecutionContext?

  @[AlwaysInline]
  def self.default : ExecutionContext
    @@default.not_nil!("expected default execution context to have been setup")
  end

  # :nodoc:
  def self.init_default_context : Nil
    {% if flag?(:mt) %}
      @@default = MultiThreaded.default(default_workers_count)
    {% else %}
      @@default = SingleThreaded.default
    {% end %}
    @@monitor = Monitor.new
  end

  # Returns the default number of workers to start in the execution context.
  def self.default_workers_count : Int32
    ENV["CRYSTAL_WORKERS"]?.try(&.to_i?) || Math.min(System.cpu_count.to_i, 32)
  end

  # :nodoc:
  protected class_getter(execution_contexts) { Thread::LinkedList(ExecutionContext).new }

  # :nodoc:
  property next : ExecutionContext?

  # :nodoc:
  property previous : ExecutionContext?

  # :nodoc:
  def self.unsafe_each(&) : Nil
    @@execution_contexts.try(&.unsafe_each { |execution_context| yield execution_context })
  end

  def self.each(&) : Nil
    execution_contexts.each { |execution_context| yield execution_context }
  end

  @[AlwaysInline]
  def self.current : ExecutionContext
    Thread.current.execution_context
  end

  # Tells the current scheduler to suspend the current fiber and resume the
  # next runnable fiber. The current fiber will never be resumed; you're
  # responsible to reenqueue it.
  #
  # This method is safe as it only operates on the current ExecutionContext and
  # Scheduler.
  @[AlwaysInline]
  def self.reschedule : Nil
    Scheduler.current.reschedule
  end

  # Tells the current scheduler to suspend the current fiber and to resume
  # `fiber` instead. The current fiber will never be resumed; you're responsible
  # to reenqueue it.
  #
  # Raises `RuntimeError` if the fiber doesn't belong to the current execution
  # context.
  #
  # This method is safe as it only operates on the current ExecutionContext and
  # Scheduler.
  @[AlwaysInline]
  def self.resume(fiber : Fiber) : Nil
    if fiber.execution_context == current
      Scheduler.current.resume(fiber)
    else
      raise RuntimeError.new("Can't resume fiber from #{fiber.execution_context} into #{current.execution_context}")
    end
  end

  # Creates a new fiber then calls `#enqueue` to add it to the execution
  # context.
  #
  # May be called from any ExecutionContext (i.e. must be thread-safe).
  @[AlwaysInline]
  def spawn(*, name : String? = nil, &block : ->) : Fiber
    Fiber.new(name, self, &block).tap { |fiber| enqueue(fiber) }
  end

  # Legacy support for the `same_thread` argument. Each execution context may
  # decide to support it or not (e.g. SingleThreaded can accept it).
  @[Deprecated("The same_thread argument to spawn is deprecated. Create execution contexts instead")]
  abstract def spawn(*, name : String? = nil, same_thread : Bool, &block : ->) : Fiber

  abstract def stack_pool : Fiber::StackPool
  abstract def stack_pool? : Fiber::StackPool?
  abstract def event_loop : Crystal::EventLoop

  # Enqueues a fiber to be resumed inside the execution context.
  #
  # May be called from any ExecutionContext (i.e. must be thread-safe).
  abstract def enqueue(fiber : Fiber) : Nil
end
