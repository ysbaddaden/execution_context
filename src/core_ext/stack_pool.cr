class Fiber::StackPool
  @lock = Crystal::SpinLock.new

  # OPTIMIZE: collect stacks that haven't been used during the loop interval
  #           (instead of deallocating half of them arbitrarily).
  def collect(count = lazy_size // 2) : Nil
    count.times do
      break unless stack = @lock.sync { @deque.shift? }
      Crystal::System::Fiber.free_stack(stack, STACK_SIZE)
    end
  end

  def collect_loop(every = 5.seconds) : Nil
    # loop do
    #   sleep(every)
    #   collect
    # rescue ex
    #   Crystal::System.print_exception(ex)
    # end
  end

  def checkout : {Void*, Void*}
    stack = @lock.sync { @deque.pop? } if @deque.size > 0
    stack ||= Crystal::System::Fiber.allocate_stack(STACK_SIZE, @protect)
    {stack, stack + STACK_SIZE}
  end

  def release(stack) : Nil
    @lock.sync { @deque.push(stack) }
  end
end
