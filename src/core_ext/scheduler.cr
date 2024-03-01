# Disables everything from the regular schedulers.
#
# TODO: deprecate all methods (so we get deprecation warnings)

# :nodoc:
class Crystal::Scheduler
  @[AlwaysInline]
  def self.stack_pool : Fiber::StackPool
    ExecutionContext.current.stack_pool
  end

  @[AlwaysInline]
  def self.event_loop
    ExecutionContext.current.event_loop
  end

  @[AlwaysInline]
  def self.current_fiber : Fiber
    Thread.current.current_fiber
  end

  @[AlwaysInline]
  def self.enqueue(fiber : Fiber) : Nil
    fiber.enqueue
  end

  @[AlwaysInline]
  def self.enqueue(fibers : Enumerable(Fiber)) : Nil
    fibers.each(&.enqueue)
  end

  @[AlwaysInline]
  def self.reschedule
    ExecutionContext.reschedule
  end

  @[AlwaysInline]
  def self.resume(fiber : Fiber) : Nil
    ExecutionContext.resume(fiber)
  end

  @[AlwaysInline]
  def self.yield : Nil
    ExecutionContext.yield
  end

  @[AlwaysInline]
  def self.yield(fiber : Fiber) : Nil
    Fiber.current.resume_event.add(0.seconds)
    ExecutionContext.resume(fiber)
  end

  @[AlwaysInline]
  def self.sleep(time : Time::Span) : Nil
    ::sleep(time)
  end

  @[AlwaysInline]
  def self.init : Nil
    ExecutionContext.init_default_context
  end
end
