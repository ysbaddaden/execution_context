# Benchmarks

A few benchmarks to quickly try out ExecutionContext and compare it against
the current master.

Run `make` to build all the targets, then we can run some comparison.

## fiber qsort

Recursively splits an array in half and spawns fibers to handle each half until
each slice is small enough to be sorted. This is mostly CPU and scheduler
oriented, with lots of fiber spawns and resumes.

We can compare the default single threaded schedulers:

```console
$ ./fiber_qsort
init
shuffle
running
took 00:00:00.106064998s
$ ./fiber_qsort-ec
init
shuffle running
took: 00:00:00.055556368s
```

Or the multi-threaded schedulers:

```console
$ crystal run.cr ./fiber_qsort-mt ./fiber-qsort-ec-mt
MT:1    89      51
MT:2    46      56
MT:4    76      52
MT:8    87      59
MT:12   214     110
MT:16   737     148
```

## http server

A simple HTTP server that serves it's own source code multiple times. It should
very regularly trigger the event loop. Given the very regular responses (almost
no variations of request handling), it is expected for crystal master to be
slightly faster than execution contexts until we rework the Event Loop (to have
one instance per EC, not per thread), except for ST and MT:1 that might be
faster.

We can do lots of comparisons by starting one or more instances of the
executable (the server uses `SO_REUSEPORT`), each with one or more threads
(`CRYSTAL_WORKERS=N`), then use an external benchmark tool, for example
[wrk](https://github.com/wg/wrk) to measure the throughput.

For example when I start the http server on 1 or 2 cores/threads (on a 4 cores
i7 laptop with hyperthreading, hence capable of 8 threads):

```console
$ wrk -t2 -c 40 -d 30
```

When I start the http server on 4 cores/threads (same laptop):

```console
$ wrk -t4 -c 40 -d 30
```

You can tweak these numbers. The difficulty is to avoid reaching the benchmark
tool's capacity _before_ we reach the http server capacity.
