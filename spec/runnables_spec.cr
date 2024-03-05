require "./spec_helper"
require "../src/runnables"

describe ExecutionContext::Runnables do
  it "#initialize" do
    g = ExecutionContext::GlobalQueue.new
    r = ExecutionContext::Runnables(16).new(g)
    r.capacity.should eq(16)
  end

  describe "#push" do
    it "enqueues the fiber in local queue" do
      fibers = 4.times.map { |i| Fiber.new(name: "f#{i}") {} }.to_a

      # local enqueue
      g = ExecutionContext::GlobalQueue.new
      r = ExecutionContext::Runnables(4).new(g)
      fibers.each { |f| r.push(f) }

      # local dequeue
      fibers.each { |f| r.get?.should be(f) }
      r.get?.should be_nil

      # didn't push to global queue
      g.pop?.should be_nil
    end

    it "moves half the local queue to the global queue on overflow" do
      fibers = 5.times.map { |i| Fiber.new(name: "f#{i}") {} }.to_a

      # local enqueue + overflow
      g = ExecutionContext::GlobalQueue.new
      r = ExecutionContext::Runnables(4).new(g)
      fibers.each { |f| r.push(f) }

      # kept half of local queue
      r.get?.should be(fibers[2])
      r.get?.should be(fibers[3])

      # moved half of local queue + last push to global queue
      g.pop?.should eq(fibers[0])
      g.pop?.should eq(fibers[1])
      g.pop?.should eq(fibers[4])
    end

    it "can always push up to capacity" do
      g = ExecutionContext::GlobalQueue.new
      r = ExecutionContext::Runnables(4).new(g)

      4.times do
        # local
        4.times { r.push(Fiber.new {}) }
        2.times { r.get? }
        2.times { r.push(Fiber.new {}) }

        # overflow (2+1 fibers are sent to global queue + 1 local)
        2.times { r.push(Fiber.new {}) }

        # clear
        3.times { r.get? }
      end

      # on each iteration we pushed 2+1 fibers to the global queue
      g.size.should eq(12)

      # grab fibers back from the global queue
      fiber = g.unsafe_grab?(r, divisor: 1)
      fiber.should_not be_nil
      r.get?.should_not be_nil
      r.get?.should be_nil
    end
  end

  describe "#bulk_push" do
    it "fills the local queue" do
      q = ExecutionContext::Queue.new(nil, nil)
      fibers = 4.times.map { |i| Fiber.new(name: "f#{i}") {} }.to_a
      fibers.each { |f| q.push(f) }

      # local enqueue
      g = ExecutionContext::GlobalQueue.new
      r = ExecutionContext::Runnables(4).new(g)
      r.bulk_push(pointerof(q), 4)

      fibers.reverse_each { |f| r.get?.should be(f) }
      g.empty?.should be_true
    end

    it "pushes the overflow to the global queue" do
      q = ExecutionContext::Queue.new(nil, nil)
      fibers = 7.times.map { |i| Fiber.new(name: "f#{i}") {} }.to_a
      fibers.each { |f| q.push(f) }

      # local enqueue + overflow
      g = ExecutionContext::GlobalQueue.new
      r = ExecutionContext::Runnables(4).new(g)
      r.bulk_push(pointerof(q), 5)

      # filled the local queue
      r.get?.should eq(fibers[6])
      r.get?.should eq(fibers[5])
      r.get?.should be(fibers[4])
      r.get?.should be(fibers[3])

      # moved the rest to the global queue
      g.pop?.should eq(fibers[2])
      g.pop?.should eq(fibers[1])
      g.pop?.should eq(fibers[0])
    end
  end

  describe "#get?" do
    # ...
  end

  describe "#steal_from" do
    it "steals from another runnables" do
      g = ExecutionContext::GlobalQueue.new
      fibers = 6.times.map { |i| Fiber.new(name: "f#{i}") {} }.to_a

      # fill the source queue
      r1 = ExecutionContext::Runnables(16).new(g)
      fibers.each { |f| r1.push(f) }

      # steal from source queue
      r2 = ExecutionContext::Runnables(16).new(g)
      fiber = r2.steal_from(r1)

      # stole half of the runnable fibers
      fiber.should eq(fibers[2])
      r2.get?.should eq(fibers[0])
      r2.get?.should eq(fibers[1])
      r2.get?.should be_nil

      # left the other half
      r1.get?.should be(fibers[3])
      r1.get?.should be(fibers[4])
      r1.get?.should be(fibers[5])
      r1.get?.should be_nil

      # global queue is left untouched
      g.empty?.should be_true
    end
  end

  describe "thread safety" do
    it "stress test" do
      fail "missing test"
    end
  end
end
