module ExecutionContext
  # Singly-linked list of fibers.
  # Last-in, first-out (LIFO) semantic.
  # A fiber can only exist within a single `Queue` at any time.
  #
  # Not thread-safe. An external lock is needed for concurrent accesses.
  #
  # TODO: rename as Fiber::Queue (?)
  # TODO: LIFO semantic is weird (inherited from Go's gQueue); shall we consider FIFO instead?
  struct Queue
    getter size : Int32

    def initialize(@head : Fiber? = nil, @tail : Fiber? = nil, @size = 0)
    end

    def push(fiber : Fiber) : Nil
      fiber.schedlink = @head
      @head = fiber
      @tail = fiber if @tail.nil?
      @size += 1
    end

    def bulk_unshift(queue : Queue*) : Nil
      return unless last = queue.value.@tail
      last.schedlink = nil

      if tail = @tail
        tail.schedlink = queue.value.@head
      else
        @head = queue.value.@head
      end
      @tail = queue.value.@tail

      @size += queue.value.size
    end

    @[AlwaysInline]
    def pop : Fiber
      pop { raise IndexError.new("ERROR: empty Queue") }
    end

    @[AlwaysInline]
    def pop? : Fiber?
      pop { nil }
    end

    private def pop
      if fiber = @head
        @head = fiber.schedlink
        @tail = nil if @head.nil?
        @size -= 1
        fiber.schedlink = nil
        fiber
      else
        yield
      end
    end

    @[AlwaysInline]
    def empty? : Bool
      @head == nil
    end

    def clear
      @size = 0
      @head = @tail = nil
    end

    def each(&) : Nil
      cursor = @head
      while cursor
        yield cursor
        cursor = cursor.schedlink
      end
    end
  end
end
