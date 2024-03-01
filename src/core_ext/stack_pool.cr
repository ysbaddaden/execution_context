class Fiber::StackPool
  class_getter global : self = new

  @lock = Crystal::SpinLock.new

  # Collects `count` stacks from the top of the pool.
  def collect(count = lazy_size // 2) : Nil
    return if count == 0

    buffer = Array(Void*).new(count)

    @lock.sync do
      Deque.half_slices(@deque) do |slice|
        buffer.concat slice[0...{count, slice.size}.min]
        count -= buffer.size
        break if count <= 0
      end
    end

    buffer.each do |stack|
      Crystal::System::Fiber.free_stack(stack, STACK_SIZE)
    end
  end

  # Removes a stack from the bottom of the pool, or allocates a new one.
  def checkout : {Void*, Void*}
    stack = @lock.sync { @deque.pop? } ||
      Crystal::System::Fiber.allocate_stack(STACK_SIZE)
    {stack, stack + STACK_SIZE}
  end

  # Appends a stack to the bottom of the pool.
  def release(stack) : Nil
    @lock.sync { @deque.push(stack) }
  end
end
