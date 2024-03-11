# ExecutionContext

First stab at implementing [RFC 0002](https://github.com/crystal-lang/rfcs/pull/2)
for [Crystal](https://crystal-lang.org).


## Basics

The `ExecutionContext::SingleThreaded` context starts a scheduler on a single
thread. Every fiber spawned into that context will never run in parallel to each
other (but they will run in parallel to fibers running in other contexts).

The `ExecutionContext::MultiThreaded` context starts multiple threads and a
scheduler on each of them. Fibers spawned into that context will run in
parallel to each other (and other fibers in other contexts). Pending runnable
fibers may be stolen and resumed by any scheduler inside the context (but never
be stolen and resumed by another context)

The `ExecutionContext::Isolated` context starts a single thread to run one
exclusive fiber. Trying to spawn inside this context will actually enqueue the
fibers into another context (the default context by default).

You can spawn a fiber into an explicit execution context using `context.spawn`
while `spawn` will spawn into the current context.

### Default context

The shard creates a default execution context that is
`ExecutionContext::SingleThreaded` by default unless you specify the `-Dmt`
compilation flag in addition to the `-Dpreview_mt` flag (required to make stdlib
object thread safe) in which case it will be `ExecutionContext::MultiThreaded`.


## Requirements

The shard replaces the regular Crystal::Scheduler implementation in stdlib with
new ones.

The shard will monkey-patch many things into Crystal's stdlib as much as
possible, yet there are a couple changes that requires to patch the stdlib
directly.

The patches are in the `/patches` folder of the shard and must be applied on top
of Crystal HEAD. I recommend to clone the Git repository on your local, and to
keep it up to date:

```console
$ git clone https://github.com/crystal-lang/crystal.git
$ cd crystal
$ for f in /path/to/execution_context/patches/*; do patch -p1 $f; done
```


## Usage

Add the shard to your project:

```yaml
dependencies:
  execution_context:
    github: ysbaddaden/execution_context
    branch: main
```

The we can start creating execution contexts:

```crystal
require "execution_context"

st = ExecutionContext::SingleThreaded.new("ST")
mt = ExecutionContext::MultiThreaded.new("MT", size: 4)

100.times do |i|
  st.spawn do
    print "Hello from ST (iteration #{i})\n"
  end

  mt.spawn do
    print "Hello from MT (iteration #{i})\n"
  end
end

sleep 1
```

Remember that you need a patched Crystal and we still need the `preview_mt` flag
to enable thread safety in Crystal stdlib (e.g. GC, Channel, Mutex).

```console
$ CRYSTAL=/path/to/patched-crystal/bin/crystal
$ $CRYSTAL run -Dpreview_mt test.cr
Hello from MT (iteration 0)
Hello from MT (iteration 1)
Hello from ST (iteration 2)
Hello from MT (iteration 2)
Hello from ST (iteration 3)
Hello from ST (iteration 0)
Hello from ST (iteration 1)
Hello from MT (iteration 3)
Hello from ST (iteration 4)
Hello from MT (iteration 4)
Hello from ST (iteration 5)
Hello from MT (iteration 5)
...
```

The messages should be in any order, mixing ST and MT.

## License

Distributed under the Apache-2.0 license.
