# Disables everything from the current Crystal scheduler. Delegates everything
# that can be to `ExecutionContext.current`. Aborts when a Crystal::Scheduler is
# instantiated.
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
    # ExecutionContext.current.event_loop
    ExecutionContext::Scheduler.current.event_loop
  end

  @[AlwaysInline]
  def self.current_fiber : Fiber
    Thread.current.current_fiber
  end

  @[AlwaysInline]
  def self.enqueue(fiber : Fiber) : Nil
    fiber.execution_context.enqueue(fiber)
  end

  @[AlwaysInline]
  def self.enqueue(fibers : Enumerable(Fiber)) : Nil
    fibers.each do |fiber|
      fiber.execution_context.enqueue(fiber)
    end
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
    Fiber.current.resume_event.add(0.seconds)
    ExecutionContext.reschedule
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

  def initialize
    message = String.build do |str|
      str.puts "BUG: instantiated a Crystal::Scheduler"
      caller.each { |line| str.puts line }
    end
    abort message

    # not reachable but required for compilation
    previous_def
  end
end
