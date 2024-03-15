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

  # identical to master, but doesn't prematurely releases the stack _before_ we
  # switch to another fiber, so we don't end up with a thread reusing a stack
  # for a new fiber while the current fiber isn't fully terminated which would
  # corrupt the stack (the same would be needed if we unmapped the stack).

  # :nodoc:
  def run
    GC.unlock_read
    @proc.call
  rescue ex
    io = {% if flag?(:preview_mt) %}
           IO::Memory.new(4096) # PIPE_BUF
         {% else %}
           STDERR
         {% end %}
    if name = @name
      io << "Unhandled exception in spawn(name: " << name << "): "
    else
      io << "Unhandled exception in spawn: "
    end
    ex.inspect_with_backtrace(io)
    {% if flag?(:preview_mt) %}
      STDERR.write(io.to_slice)
    {% end %}
    STDERR.flush
  ensure
    # Remove the current fiber from the linked list
    Fiber.inactive(self)

    # Delete the resume event if it was used by `yield` or `sleep`
    @resume_event.try &.free
    @timeout_event.try &.free
    @timeout_select_action = nil

    @alive = false

    ExecutionContext.reschedule
  end
end
