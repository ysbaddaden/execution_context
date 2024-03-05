abstract class ExecutionContext
  # Singly-linked list of fibers.
  # Last-in, first-out (LIFO) semantic.
  # A fiber can only exist within a single `Queue` at any time.
  #
  # Not thread-safe. An external lock is needed for concurrent accesses.
  #
  # TODO: rename as Fiber::Queue (?)
  struct Queue
    def initialize(@head : Fiber?, @tail : Fiber?)
    end

    def push(fiber : Fiber) : Nil
      fiber.schedlink = @head
      @head = fiber
      @tail = fiber if @tail.nil?
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
    end

    @[AlwaysInline]
    def pop : Fiber
      pop { raise IndexError.new }
    end

    @[AlwaysInline]
    def pop? : Fiber?
      pop { nil }
    end

    private def pop
      if fiber = @head
        @head = fiber.schedlink
        @tail = nil if @head.nil?
        fiber
      else
        yield
      end
    end

    @[AlwaysInline]
    def empty? : Bool
      @head == nil
    end

    # def clear
    #   @head = @tail = nil
    # end
  end
end
