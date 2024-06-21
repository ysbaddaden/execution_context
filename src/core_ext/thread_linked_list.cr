class Thread
  class LinkedList(T)
    def each(&) : Nil
      @mutex.synchronize do
        unsafe_each { |node| yield node }
      end
    end
  end
end
