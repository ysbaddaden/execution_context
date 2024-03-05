require "./spec_helper"
require "../src/queue"

describe ExecutionContext::Queue do
  describe "#initialize" do
    it "creates an empty queue" do
      q = ExecutionContext::Queue.new(nil, nil)
      q.@head.should be_nil
      q.@tail.should be_nil
      q.empty?.should be_true
    end

    it "creates a filled queue" do
      f1 = Fiber.new(name: "f1") {}
      f2 = Fiber.new(name: "f2") {}
      f1.schedlink = f2
      f2.schedlink = nil

      q = ExecutionContext::Queue.new(f2, f1)
      q.@head.should be(f2)
      q.@tail.should be(f1)
      q.empty?.should be_false
    end
  end

  describe "#push" do
    it "to head" do
      q = ExecutionContext::Queue.new(nil, nil)
      f1 = Fiber.new(name: "f1") {}
      f2 = Fiber.new(name: "f2") {}
      f3 = Fiber.new(name: "f3") {}

      # simulate fibers previously added to other queues
      f1.schedlink = f3
      f2.schedlink = f1

      # push first fiber
      q.push(f1)
      q.@head.should be(f1)
      q.@tail.should be(f1)
      f1.schedlink.should be_nil

      # push second fiber
      q.push(f2)
      q.@head.should be(f2)
      q.@tail.should be(f1)
      f2.schedlink.should be(f1)
      f1.schedlink.should be_nil

      # push third fiber
      q.push(f3)
      q.@head.should be(f3)
      q.@tail.should be(f1)
      f3.schedlink.should be(f2)
      f2.schedlink.should be(f1)
      f1.schedlink.should be_nil
    end
  end

  describe "#bulk_unshift" do
    it "to empty queue" do
      # manually create a queue
      f1 = Fiber.new(name: "f1") {}
      f2 = Fiber.new(name: "f2") {}
      f3 = Fiber.new(name: "f3") {}
      f3.schedlink = f2
      f2.schedlink = f1
      f1.schedlink = nil
      q1 = ExecutionContext::Queue.new(f3, f1)

      # push in bulk
      q2 = ExecutionContext::Queue.new(nil, nil)
      q2.bulk_unshift(pointerof(q1))
      q2.@head.should be(f3)
      q2.@tail.should be(f1)
    end

    it "to filled queue" do
      f1 = Fiber.new(name: "f1") {}
      f2 = Fiber.new(name: "f2") {}
      f3 = Fiber.new(name: "f3") {}
      f4 = Fiber.new(name: "f4") {}
      f5 = Fiber.new(name: "f5") {}

      # source queue
      f3.schedlink = f2
      f2.schedlink = f1
      f1.schedlink = nil
      q1 = ExecutionContext::Queue.new(f3, f1)

      # destination queue
      f5.schedlink = f4
      f4.schedlink = nil
      q2 = ExecutionContext::Queue.new(f5, f4)

      # push in bulk
      q2.bulk_unshift(pointerof(q1))
      q2.@head.should be(f5)
      q2.@tail.should be(f1)

      f5.schedlink.should be(f4)
      f4.schedlink.should be(f3)
      f3.schedlink.should be(f2)
      f2.schedlink.should be(f1)
      f1.schedlink.should be(nil)
    end
  end

  describe "#pop" do
    it "from head" do
      f1 = Fiber.new(name: "f1") {}
      f2 = Fiber.new(name: "f2") {}
      f3 = Fiber.new(name: "f3") {}
      f3.schedlink = f2
      f2.schedlink = f1
      f1.schedlink = nil
      q = ExecutionContext::Queue.new(f3, f1)

      # removes third element
      q.pop.should be(f3)
      q.@head.should be(f2)
      q.@tail.should be(f1)

      # removes second element
      q.pop.should be(f2)
      q.@head.should be(f1)
      q.@tail.should be(f1)

      # removes first element
      q.pop.should be(f1)
      q.@head.should be_nil
      q.@tail.should be_nil

      # empty queue
      expect_raises(IndexError) { q.pop }
    end
  end

  describe "#pop?" do
    it "from head" do
      f1 = Fiber.new(name: "f1") {}
      f2 = Fiber.new(name: "f2") {}
      f3 = Fiber.new(name: "f3") {}
      f3.schedlink = f2
      f2.schedlink = f1
      f1.schedlink = nil
      q = ExecutionContext::Queue.new(f3, f1)

      # removes third element
      q.pop?.should be(f3)
      q.@head.should be(f2)
      q.@tail.should be(f1)

      # removes second element
      q.pop?.should be(f2)
      q.@head.should be(f1)
      q.@tail.should be(f1)

      # removes first element
      q.pop?.should be(f1)
      q.@head.should be_nil
      q.@tail.should be_nil

      # empty queue
      q.pop?.should be_nil
    end
  end
end
