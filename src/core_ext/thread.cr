class Thread
  # :nodoc:
  getter! execution_context : ExecutionContext

  # :nodoc:
  property! current_scheduler : ExecutionContext::Scheduler

  def execution_context=(@execution_context : ExecutionContext)
    main_fiber.execution_context = execution_context
  end

  def self.each(&) : Nil
    threads.each { |thread| yield thread }
  end

  # :nodoc:
  def dead_fiber=(@dead_fiber : Fiber) : Fiber
  end

  # :nodoc:
  def dead_fiber? : Fiber?
    if fiber = @dead_fiber
      @dead_fiber = nil
      fiber
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
