class Thread
  # :nodoc:
  getter! execution_context : ExecutionContext

  # :nodoc:
  property! current_fiber : Fiber

  # @func : Thread ->

  # protected def start
  #   Thread.threads.push(self)
  #   Thread.current = self
  #   @main_fiber = fiber = Fiber.new(stack_address, self)

  #   begin
  #     @func.call(self)
  #   rescue ex
  #     @exception = ex
  #   ensure
  #     Thread.threads.delete(self)
  #     Fiber.inactive(fiber)
  #     detach { system_close }
  #   end
  # end

  def execution_context=(@execution_context : ExecutionContext)
    main_fiber.execution_context = execution_context
  end
end

class Thread::WaitGroup
  def initialize(@count : Int32)
    @mutex = Thread::Mutex.new
    @condition = Thread::ConditionVariable.new
  end

  def done : Nil
    @mutex.synchronize do
      @count -= 1
      @condition.broadcast if @count == 0
    end
  end

  def wait : Nil
    @mutex.synchronize do
      @condition.wait(@mutex) unless @count == 0
    end
  end
end

