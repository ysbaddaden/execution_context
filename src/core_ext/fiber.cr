class Fiber
  def self.current : Fiber
    Thread.current.current_fiber
  end

  def self.yield : Nil
    Fiber.current.resume_event.add(0.seconds)
    ExecutionContext.reschedule
  end

  # def self.timeout(timeout : Time::Span?, select_action : Channel::TimeoutAction? = nil) : Nil
  #   current.timeout(timeout, select_action)
  # end

  # def self.cancel_timeout : Nil
  #   current.cancel_timeout
  # end

  @execution_context : ExecutionContext?
  property! execution_context : ExecutionContext

  # :nodoc:
  property schedlink : Fiber?

  def initialize(name : String? = nil, execution_context : ExecutionContext = ExecutionContext.current, &proc : ->)
    previous_def(name, &proc)
    @execution_context = execution_context
  end

  # def initialize(stack : Void*, thread)
  #   previous_def(stack, thread)
  #   # @execution_context = ExecutionContext.current # <= infinite recursion
  # end

  def resume : Nil
    ExecutionContext.resume(self)
  end

  def enqueue : Nil
    execution_context.enqueue(self)
  end
end
