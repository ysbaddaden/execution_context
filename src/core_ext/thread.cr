class Thread
  # :nodoc:
  getter! execution_context : ExecutionContext

  # :nodoc:
  property! current_scheduler : ExecutionContext::Scheduler

  # :nodoc:
  property! current_fiber : Fiber

  def execution_context=(@execution_context : ExecutionContext)
    main_fiber.execution_context = execution_context
  end

  # the following methods set `@current_fiber` and are otherwise identical to crystal:master

  def initialize
    @func = ->(t : Thread) {}
    @system_handle = Crystal::System::Thread.current_handle
    @current_fiber = @main_fiber = Fiber.new(stack_address, self)

    Thread.threads.push(self)
  end

  protected def start
    Thread.threads.push(self)
    Thread.current = self
    @current_fiber = @main_fiber = fiber = Fiber.new(stack_address, self)

    if name = @name
      self.system_name = name
    end

    begin
      @func.call(self)
    rescue ex
      @exception = ex
    ensure
      Thread.threads.delete(self)
      Fiber.inactive(fiber)
      detach { system_close }
    end
  end

  def scheduler : Crystal::Scheduler
    raise "BUG: deprecated call to Thread#scheduler"
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
