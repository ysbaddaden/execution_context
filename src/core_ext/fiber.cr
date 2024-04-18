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

  # identical to master BUT we set @execution_context and checkout a stack from
  # the execution context's stack pool

  def initialize(@name : String? = nil, @execution_context : ExecutionContext = ExecutionContext.current, &@proc : ->)
    # previous_def(name, &proc)
    @context = Context.new
    @stack, @stack_bottom =
      {% if flag?(:interpreted) %}
        {Pointer(Void).null, Pointer(Void).null}
      {% else %}
        execution_context.stack_pool.checkout
      {% end %}

    fiber_main = ->(f : Fiber) { f.run }

    # FIXME: This line shouldn't be necessary (#7975)
    stack_ptr = nil
    {% if flag?(:win32) %}
      # align stack bottom to 16 bytes
      @stack_bottom = Pointer(Void).new(@stack_bottom.address & ~0x0f_u64)

      # It's the caller's responsibility to allocate 32 bytes of "shadow space" on the stack right
      # before calling the function (regardless of the actual number of parameters used)

      stack_ptr = @stack_bottom - sizeof(Void*) * 6
    {% else %}
      # point to first addressable pointer on the stack (@stack_bottom points past
      # the stack because the stack grows down):
      stack_ptr = @stack_bottom - sizeof(Void*)
    {% end %}

    # align the stack pointer to 16 bytes:
    stack_ptr = Pointer(Void*).new(stack_ptr.address & ~0x0f_u64)

    makecontext(stack_ptr, fiber_main)

    Fiber.fibers.push(self)
  end

  # def initialize(stack : Void*, thread)
  #   previous_def(stack, thread)
  #   # @execution_context = ExecutionContext.current # <= infinite recursion
  # end

  def enqueue : Nil
    execution_context.enqueue(self)
  end

  def resume : Nil
    ExecutionContext.resume(self)
  end

  # identical to master, but doesn't prematurely releases the stack _before_ we
  # switch to another fiber, so we don't end up with a thread reusing a stack
  # for a new fiber while the current fiber isn't fully terminated which would
  # corrupt the stack (the same would be needed if we unmapped the stack).

  # :nodoc:
  def run
    GC.unlock_read

    {% unless flag?(:interpreted) %}
      if fiber = Thread.current.dead_fiber?
        fiber.execution_context.stack_pool.release(fiber.@stack)
      end
    {% end %}

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
