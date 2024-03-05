require "./spec_helper"
require "../src/global_queue"

# TODO: until we fully test Runnables
private class FakeRunnables
  include Enumerable(Fiber)

  def initialize(@capacity : Int32)
    @array = Array(Fiber).new(capacity)
  end

  def capacity : Int32
    @capacity
  end

  def push(item : Fiber) : Nil
    @array << item
  end

  def get? : Fiber?
    @array.shift?
  end

  def each(&block : Fiber ->)
    @array.each(&block)
  end

  def size
    @array.size
  end
end

describe ExecutionContext::GlobalQueue do
  it "#initialize" do
    q = ExecutionContext::GlobalQueue.new
    q.empty?.should be_true
  end

  it "#unsafe_push and #unsafe_pop" do
    f1 = Fiber.new(name: "f1") {}
    f2 = Fiber.new(name: "f2") {}
    f3 = Fiber.new(name: "f3") {}

    q = ExecutionContext::GlobalQueue.new
    q.unsafe_push(f1)
    q.size.should eq(1)

    q.unsafe_push(f2)
    q.unsafe_push(f3)
    q.size.should eq(3)

    q.unsafe_pop?.should be(f3)
    q.size.should eq(2)

    q.unsafe_pop?.should be(f2)
    q.unsafe_pop?.should be(f1)
    q.unsafe_pop?.should be_nil
    q.size.should eq(0)
    q.empty?.should be_true
  end

  describe "#unsafe_grab?" do
    it "can't grab from empty queue" do
      q = ExecutionContext::GlobalQueue.new
      runnables = FakeRunnables.new(6)
      q.unsafe_grab?(runnables, 4).should be_nil
    end

    it "grabs fibers" do
      q = ExecutionContext::GlobalQueue.new
      fibers = 10.times.map { |i| Fiber.new(name: "f#{i}") {} }.to_a
      fibers.each { |f| q.unsafe_push(f) }

      runnables = FakeRunnables.new(6)
      fiber = q.unsafe_grab?(runnables, 4)

      # returned the last enqueued fiber
      fiber.should be(fibers[9])

      # enqueued the next 2 fibers
      runnables.size.should eq(2)
      runnables.get?.should be(fibers[8])
      runnables.get?.should be(fibers[7])

      # the remaining fibers are still there:
      6.downto(0).each do |i|
        q.unsafe_pop?.should be(fibers[i])
      end
    end

    it "can't grab more than available" do
      f = Fiber.new {}
      q = ExecutionContext::GlobalQueue.new
      q.unsafe_push(f)

      # dequeues the unique fiber
      runnables = FakeRunnables.new(6)
      fiber = q.unsafe_grab?(runnables, 4)
      fiber.should be(f)

      # had nothing left to dequeue
      runnables.size.should eq(0)
    end
  end

  describe "thread safety" do
    it "stress test" do
      fail "missing test"
    end
  end
end
