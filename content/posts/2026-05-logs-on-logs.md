+++
title = "The Log Log: A Log of Building Logs on Logs"
date = 2026-05-01
description = "Don't worry, it'll all make sense by the time we get to the part about sharding shards across shards."

[extra]
toc = true
comment = false
+++

I recently went down a deep rabbit hole around shared log architectures and how they can be used to perform consensus in distributed systems. The journey was initially prompted by a problem at Materialize, which then turned into a skunkworks, and then morphed into a hobby project where I added all sorts of wild things that I probably wouldn't recommend if the point weren't to have fun.

The journey we'll go on here relates to the storage engine of Materialize, known as `persist`. As a quick primer: `persist` commits data by first writing the bulk of the bytes given to it into object storage, and then writing pointers to that object storage into its metadata storage, known as `Consensus` (often Postgres or Cockroach); `persist` is designed to store [differential dataflow collections](https://github.com/TimelyDataflow/differential-dataflow), and an individual collection we call a "shard". These are likely to be unfamiliar terms so mentally mapping one `persist` shard to mean the durable storage for one table in a database will get you pretty far.

From here, we will go down a rabbit hole five levels deep on how to design a new implementation of `Consensus` that borrows all sorts of ideas from the shared log literature, ultimately yielding a system with much better throughput & efficiency than the available implementations today.

## Level 0: Independent Shard Writes

We'll start at Level 0: what exists today.

Today, each `persist` shard's state is stored as a totally ordered log in the `Consensus` database, with new incremental updates going through a CaS (compare-and-set) operation on this backing store.

Each `persist` shard operates wholly independently, so write traffic to the `Consensus` store scales linearly with the number of `persist` shards. Materialize drives forward most of its objects at a fixed tick rate (e.g. 1Hz, 2Hz, 5Hz, etc), so it's quite easy to estimate the write throughput pushed to `Consensus` as `# shards * tick rate`.

{{ figure(src="/img/diagrams/logs_on_logs_independent_writes.excalidraw.svg", alt="Architecture diagram showing how many objects in Materialize yield many independent persist shards, each performing expensive writes to the Consensus database.") }}

As we can see in this diagram's example, we have four objects upstream, so this translates to four `persist` shards, each having state in independent, ordered logs.

If the upstream is driving these forward with a tick rate of 1Hz, then we have just about `4 objects * 1Hz = 4 compare-and-set / second`. If the `Consensus` store used is Postgres for instance, this workload would directly translate to 4 `INSERT INTO ... ON CONFLICT` transactions per second.

This works fine conceptually, but in practice, scaling `Consensus` can get pretty tricky! People like using Materialize because you can integrate lots of data in it, so they quickly want to add thousands and thousands of maintained objects (each mapping to at least 1 `persist` shard) as it absorbs data from a great many upstream databases. And people like their data served hot & fresh so they might want to bump that tick rate higher and higher, multiplying the write volume per object.

Suddenly you do the simple back-of-the-envelope math, and a user who has 10K maintained objects (totally reasonable usage of Mz) and a desired tick rate of 10Hz (also totally reasonable ask) is looking at 100,000 compare-and-set ops/s.

Something like Postgres caps out pretty quickly, maybe handling ~10K writes/s before hitting its limits. A backing store like one of the many modern scale-out SQL databases, or even object storage, can in principle handle that traffic, but at astronomical financial cost.

Let's start exploring how we can turn that write scale factor of `O(# objects * tick rate)` into something far more palatable.

## Level 1: Brokered Group Commit

My first attempt at a `Consensus` implementation was focused purely on reducing write volume, and did so by batching all of the consensus traffic into periodic group commits to object storage.

{{ figure(src="/img/diagrams/logs_on_logs_brokered_group_commit.excalidraw.svg", alt="Architecture diagram showing a brokered group commit, where persist shard traffic flows through a broker service that batches up writes to object storage, and serves reads from memory.") }}

In this design, each `persist` client is pointed at a `Consensus` implementation backed by a new broker service, and the broker service backs its durable state with a sequence of group commits against object storage.

The broker service does a few important things:

1. It durably records `persist` client writes into object storage. It creates a total ordering of all client writes by writing them into batches with a known sequence (e.g. the files are named `0001`, `0002`, ... , `n`), and leverages conditional puts to ensure it never writes a duplicate entry.

2. It holds an in-memory materialization of each `persist` shard's state

    a. This is used to serve reads directly from memory very quickly.

    b. This is used to determine which compare-and-set operations should be written to object storage by evaluating the compare-and-set operations against the in-memory state.

When the broker restarts, it rehydrates its in-memory state by scanning through the ordered batches in object storage, playing them back in order.

This isn't a bad start -- instead of a `O(# objects * tick rate)` factor on durable writes from Level 0, it's now `O(group commit flush rate)`, which if the broker is fast enough, can mean de-amplifying writes by 100-1000x (!). Sounds great on paper, but unfortunately, this design has some major issues:

* Recovery / rehydration takes increasingly long as the number of batches in object storage grows -- when the broker restarts, it needs to replay _every batch ever written_ to build the correct state! We could think about adding state snapshots to rehydrate from instead, but it's non-trivial to capture that snapshot without introducing something akin to a stop-the-world pause. We could also think about compaction and trimming out unneeded data over time, but that means building a new compaction algorithm on object storage which is also seriously non-trivial.

* If multiple brokers are running concurrently, while they can never conflict on writes to object storage (thanks to conditional puts), their in-memory materializations would become out-of-sync when there's more than one writer. This is a huge correctness issue and could quickly lead to all sorts of mayhem like incorrect compare-and-set evaluations and read operations. And, alas, in a distributed system even if we wish for there to only be a singleton broker, that's not something we can actually guarantee without an explicit fencing protocol.

Hm... how might we handle concurrent writers correctly? How do we make rehydration much, much faster?

## Level 2: Decomposing Writes vs Reads

Let's tackle that problem of concurrent writers first. We want to build a system such that we can have multiple "brokers" all writing to the same backing store, and doing so in a way that yields correct results.

One of the big challenges we made for ourselves was that the broker is responsible for determining which CaS operations from the client are valid -- it has to hold every shard's state in-memory, and is only allowed to include valid operations into its group commits.

This is quite a lot of coordination logic for the write path to think about, and is a huge headache when considering concurrent brokers -- every broker needs to know of every other broker's changes as they happen. This is hard, and kind of sounds like performing... consensus... amongst the brokers.

Uh-oh. Is there anything easier we can do?

With some Frank McSherry nudges, and gestures towards the literature of [Mahesh Balakrishnan](https://maheshba.bitbucket.io/), I read through the [CORFU](https://maheshba.bitbucket.io/papers/corfumain-final.pdf), [Tango](https://maheshba.bitbucket.io/papers/tangososp.pdf), [Delos](https://maheshba.bitbucket.io/papers/delos-osdi2020.pdf), and [Taming Consensus](https://maheshba.bitbucket.io/papers/osr2024.pdf) papers.

As it turns out, yes, there is something easier! What the broker is trying to do is build an ordered log. Unbeknownst to me, many very smart people have thought about this problem quite a lot and the state-of-the-art (for 10+ years) is to perform _blind writes_ into a log, and then leaning on the log's total ordering to perform consensus / state machine replication _in the read path_.

So with this decomposition, the writer is responsible for nothing more than batching up requests and writing them very fast and efficiently to durable storage in some total order. The batches written can be filled with all sorts of duplicates and conflicting requests -- it doesn't matter! the writes are blind! -- all of the handling logic necessary to build a perfectly linear history will be sorted out later. And once it doesn't matter what the writer is putting into the log, we can then have as many writer processes as we want all vying to append into the same shared log. In fact, the only coordination the writers need to agree on in advance is the specific sequence of registers to append into, something satisfied by our scheme of conditional puts into object storage from before.

Then, the _readers_ tail the log and perform state machine replication by applying each operation in-order, all while sorting out any duplicates or conflicts written into the log by the writers. In our case, the reader will build up the in-memory `persist` state that we had in Level 1 by determining which compare-and-set operations from the client succeeded and which ones failed due to conflicts. And because the log is totally ordered, and presumably the state machine replication operations are deterministic, we can add any number of readers to the log as we'd like for high-availability or scale-out purposes.

This means that a `persist` client to this system, in order to determine whether its compare-and-set operation succeeded, must first send its compare-and-set operation to a writer, who will write it into the log and give back a receipt saying in what position it was written, and _then ask a reader_ whether that specific compare-and-set was actually successfully applied or not.

{{ figure(src="/img/diagrams/logs_on_logs_writer_reader_decomposition.excalidraw.svg", alt="Architecture diagram showing blind writes with concurrent writers appending to a shared log in object storage, with a reader tailing the log to materialize state") }}

We can see in this diagram that two entries for a particular shard were given a compare-and-set expectation value of 59 and both written into the log. This type of duplicate entry would have been fatal in our previous design, but now it's a total non-issue. Both get written to the log. Readers accept the first one, and reject the second one. Sweet!

It's hard to overstate how this move to "blind writes" simplifies the architecture -- writers and readers are now wonderfully decoupled, and each can be scaled or replicated out as needed. For those interested in exploring this decomposition further, I strongly encourage reading the aforementioned papers to develop a richer systems perspective, and this excellent [Frank McSherry blog post](https://github.com/frankmcsherry/blog/blob/master/posts/2025-04-27.md) that explores a considerably more intricate problem of resolving database transactions through such a model.

## Level 3: `persist` all the way down

To recap, we've now transformed our solution from "brokered group commit" into the more elevated "writers and readers of a shared, totally ordered log", and we still have that lingering open question about how to make rehydration take a not-infinitely-growing amount of time, perhaps through some type of snapshotting or compaction mechanism.

It would be incredibly convenient if there were some off-the-shelf implementation of an ordered log [built on object storage](https://github.com/MaterializeInc/materialize/blob/b861406cf03cf206adbd05d1cb3fad27f1c0eaa7/src/persist/src/location.rs#L526-L574) that supports [concurrent writers](https://github.com/MaterializeInc/materialize/blob/b861406cf03cf206adbd05d1cb3fad27f1c0eaa7/src/persist-client/src/lib.rs#L482-L493), [concurrent readers](https://github.com/MaterializeInc/materialize/blob/b861406cf03cf206adbd05d1cb3fad27f1c0eaa7/src/persist-client/src/lib.rs#L316-L332), with [state snapshotting](https://github.com/MaterializeInc/materialize/blob/b861406cf03cf206adbd05d1cb3fad27f1c0eaa7/src/persist-client/src/internal/state.rs#L1403-L1450) and [data compaction](https://github.com/MaterializeInc/materialize/blob/b861406cf03cf206adbd05d1cb3fad27f1c0eaa7/src/persist-client/src/internal/compact.rs) that we could just pull into our project and use.

Alas, if only such a thing existed...

Wait.

Hold up.

That's `persist`! `persist` does all of these things!

_`persist`_?! The thing we're writing a new consensus implementation for?? We can't possibly use `persist` as a building block for `persist` consensus, can we?!

I have to say it took me a solid week of thinking about this problem to properly untangle the levels involved here, but `persist` turns out to be an excellent substrate for our shared log implementation! Rather than writing some new custom log atop object storage, we can actually just use a `persist` shard. Of course, _this_ shard won't be backed by our custom consensus implementation; it can use something off-the-shelf like Postgres (which will no longer be a pain to scale since our system will have reduced write volume so much).

Let's redraw our picture with this latest update:

{{ figure(src="/img/diagrams/logs_on_logs_a_persist_shard.excalidraw.svg", alt="Architecture diagram showing how the shared log from before can actually be implemented using a persist shard.") }}

And now for some definitions, because this is going to get confusing otherwise:

* This `Consensus` implementation shall henceforth be known as `persist-shared-log`.
* A _client shard_ is a `persist` shard whose `Consensus` traffic is being serviced _by_ `persist-shared-log`.
* A _log shard_ is a `persist` shard that is used as a shared log _within_ `persist-shared-log`. Its `Consensus` implementation will be something else (e.g. Postgres).
* A _Writer_ is the component of `persist-shared-log` that is responsible for appending data into the shared log through blind writes.
* A _Reader_ is the component of `persist-shared-log` that is responsible for tailing the log, materializing client shard state, servicing client reads, and determining which client writes succeeded and failed.

## Level 3.5: Router Layer

Now that we have this neat Writer/Reader/log shard setup, we can make a small API simplification -- instead of the client needing to know how to discover Writers and Readers directly, we can put a small routing service in front of the log, and let the Router be the only interface to `persist-shared-log`. This minor simplification lets the client have a 1:1 relationship between `Consensus` methods and RPC calls, and makes it easier to evolve the backend independently from the clients which are likely to be deployed at a totally different cadence.

{{ figure(src="/img/diagrams/logs_on_logs_router.excalidraw.svg", alt="Architecture diagram showing how we can put a router service in front so the client does not need to separately know of the writers and readers.") }}

## Level 4: Fixed Sharding Scheme

So at this point, a reasonable thing to do would be to step back, test, benchmark, and validate the system, review the requirements and so on, as we now have a pretty viable `Consensus` implementation that should be able to support many thousands and thousands of client shard operations per second.

But of course, the point of this work is not to be reasonable, and while the system's throughput should be pretty good, it nags at me that if a workload saturated the log we wouldn't have any knobs to pull to scale further.

And now that we have that router... well... we can start layering on all sorts of mischief behind the scenes.

I can't resist. Let's add horizontal sharding.{% sidenote() %}We've made it to the part about sharding shards across shards!{% end %}

The simplest sharding scheme is to have a fixed number of log shards when the system is created, and hardcoding a routing of `hash(client shard) % num log shards`:

{{ figure(src="/img/diagrams/logs_on_logs_fixed_sharding.excalidraw.svg", alt="Diagram of a fixed sharding scheme. The router directs requests to two different log shards, each with their own readers and writers.") }}

Now we can have N log shards for N times more throughput. The router itself is stateless, so we can also have as many of those as we want, too. When revisiting the number of durable writes we're performing, the system now scales as `O(# log shards * Writer flush rate)`.

It is worth noting that while this sharding approach preserves total ordering of writes _per_ client shard, subdividing our writes across independent log shards removes the property of having a total ordering of writes _across_ client shards. A total ordering across client shards isn't a property asked for or used by `persist` today, but it's possible it could be valuable in the future -- as we've seen, total ordering within a distributed system is an incredibly powerful primitive -- so we shouldn't cast this aside lightly.{% sidenote() %}If we wanted to scale throughput while preserving a total ordering across client shards, we could instead look into striped writes across log shards. The Tango paper has some cool ideas here, though it gets complex very quickly.{% end %}

## Level 5: Reconfigurable Sharding Scheme

I have many years of ~~pain~~ experience working on systems that were scaled into a fixed number of shards with absolutely no consideration for what comes after, and it taught me to never leave behind such a mess for anyone else. Let's iron out how we can reconfigure / reshard this system.

Going back to the literature, the Delos paper is particularly inspirational as it outlines a virtual log abstraction that's broken into epochs of individual "loglets" -- physical chunks of the full log -- in a manner highly similar to how virtual memory gives the illusion of a contiguous address space to the user, but is backed by discontiguous physical memory. Writers write to the current loglet, readers read a history spanning loglets to form a full log, and the system can reconfigure itself to move between loglets by sealing off previous ones.

Borrowing from this idea, we can define an epoch in `persist-shared-log` as denoting a particular sharding scheme that maps certain client shards to certain log shards. When we need to reconfigure / reshard the system, we create a new epoch, copy data from the old epoch's log shards into the new epoch's log shards, seal off the old log shards, and then transition traffic to the new log shards. This gives each client shard the illusion of its state being stored in one continuous log, while `persist-shared-log` rotates the actual backing store across various log shards over time.

To layer on this abstraction, we need a new system of record to record epochs, and some orchestrator that can spin up new log shards and spin down the old ones. For this, we introduce some new components:

* The metashard: the durable store that contains our epochs / sharding information. We use another `persist` shard for this, naturally.{% sidenote() %}The shard that tells us how to shard shards across shards.{% end %}

* The Meta service: the process that manages the metashard and orchestrates the writer / reader / log shard lifecycle.

* And, we'll update the service/routing layer to now subscribe to the metashard for epoch updates so it knows where to direct traffic.

Let's update our picture with these new services:

{{ figure(src="/img/diagrams/logs_on_logs_reconfigurable_sharding.excalidraw.svg", alt="Architecture diagram showing how we can add in reconfigurable sharding by introducing a metashard that says which client shard ranges belong to which log shards.") }}

We're starting to see two layers emerge: the control plane (Meta service + metashard) and the data plane (router + writer + reader + log shards). If we nail the boundaries between them we should be able to have a neat and tidy story about how they interact.

### Reconfiguration

It took several attempts, but a protocol for reconfiguration between epochs started to come into shape. One of the goals was to minimize downtime during the transition, which it mostly succeeds at. The protocol depends on a few important properties that revealed themselves after playing with the problem for a bit:

* The lifecycle of each Reader / Writer will be tied to a specific log shard. After reconfiguration, the old Readers / Writers are spun down. This removes any complexity of repointing existing processes from old log shards to new log shards.

* The Writer will idempotently snapshot data from predecessor log shard(s) into its log shard at startup. This allows Readers to get all of the data they need without having to span reads across log shards. (Implementation detail: this is also necessary to make `persist` log shard compaction work.)

* The Meta service will orchestrate the lifecycle of Readers and Writers.

* The Meta service will orchestrate the snapshotting / sealing of log shards through their `persist` interface. This pushes all coordination logic into operations on the shared log shard, rather than direct RPCs.

#### Process Orchestration

Drilling in on that orchestration piece, the flow is pretty simple:

1. Once a new epoch is durably recorded, the Meta service creates new Writers and Readers for the new log shards
2. The Meta service performs the Log Shard Transition steps (outlined below) to idempotently transition data from the old log shards to the new log shards
3. The Meta service spins down the old Writers and Readers of the outgoing log shards

So all the Meta service needs to orchestrate the Writers and Readers is just some thin interface to spin them up and down at the right times. While developing locally, I had a few implementations of this orchestration: one managed each Writer and Reader as Tokio tasks communicating over in-memory channels, the other managed each as OS processes communicating over Unix domain sockets. In a productionized version, one could imagine managing these through something fancier like Kubernetes StatefulSets and Services.

{{ figure(src="/img/diagrams/logs_on_logs_reconfiguration_process.excalidraw.svg", alt="Diagram of the reconfiguration process orchestration, where the meta service spins up new log shards, waits for them to complete their log shard transition, and then spins down the old ones.") }}

#### Log Shard Transition

Safely transitioning data from the old log shards to the new log shards has some subtleties, but ultimately was surprisingly smooth to build. This was another scenario where leaning on `persist` for the log shard backend paid off, as it had all of the tools already available to make this possible.

The flow looks like this:

1. The Meta service takes out a special `persist` handle on the old log shards that holds back compaction, enabling us to safely copy data in the next few steps.
2. The Meta service spins up the new Writers and Readers. For Writers, it computes which shard ranges of the outgoing epoch are needed to snapshot into each Writer's new log shard, and passes this in at run time.
3. Each Writer idempotently copies the data from this old epoch's log shards into its new log shard.
4. The Meta service seals all of the old log shards, preventing further writes to them.
5. Each Writer idempotently copies any data written between step (3) and the seal.
6. The Meta service marks the reconfiguration as complete, and the Router starts sending traffic to the new Writers and Readers.

{{ figure(src="/img/diagrams/logs_on_logs_reconfiguration_protocol.excalidraw.svg", alt="Diagram of the reconfiguration protocol, where source shards are sealed, data is copied into target log shards, and then the system starts writing into the target log shards.") }}

All of the coordination steps between the Meta service and Writer can be done through the `persist` interface on the log shards, so there are no direct RPCs needed between the Meta service and each Writer & Reader. This is another nice decoupling earned through a shared log architecture! The Writer and Reader processes never need to know the Meta service even exists, and the Meta service doesn't need to know anything about the Writer and Reader except for how to spin them up and down, leading to a very satisfying control vs data plane split.

The downtime incurred by reconfiguration is between Steps 4 and 6, as it's effectively a two-phase commit to seal and confirm that every Writer is ready. In practice, the Router buffers requests during reconfiguration and sends them to the new Writers and Readers after the operation completes, so clients are unlikely to see failed requests, but are likely to have a momentary higher-than-average latency blip.

## Putting it all together

Okay we have all our pieces: Control plane! Data plane! Reconfiguration! Router! Meta state! Writers! Readers! Logs! Logs of logs! Shards! Shards of shards!

Let's see how it all looks in one place:

{{ figure(src="/img/diagrams/logs_on_logs_all_the_things.excalidraw.svg", alt="Diagram showing all components: routing layer, meta service and meta persist shard in the control plane; writers, readers, and log shards in the data plane.") }}

Oooh, shiny.

So, how does it perform?

Throughout this process I played around with benchmarks, and generally found that on my laptop, when dedicating 1 CPU core to a Writer and 1 CPU core to a Reader and simulating an approximately real-world workload, the per-log shard throughput hit ~150K client shard writes per second while maintaining ~100ms p9999 tail latencies. Reconfigurations typically had a ~1-2s latency blip. I didn't get to benchmarking a large scale-out version of this last design because I didn't want to pay for the actual cloud compute to try it out, but I remain cautiously optimistic that it'd scale linearly for quite a while before running into trouble.

Compared to existing `Consensus` implementations, `persist-shared-log`'s latencies are a fair bit higher (Postgres / Cockroach tail latencies are typically more like 20-30ms for this workload), which is to be expected when introducing batched writes and object storage to the write path. However, even on the unoptimized code here, `persist-shared-log` hints at _vastly_ better throughput / economics than existing implementations, like 3+ orders of magnitude better per unit of compute. The hope is that while per-op latencies are higher, the throughput gain of `persist-shared-log` is sufficient such that the system driving it -- Materialize -- can tick much faster and have a (significant) net increase in freshness as a result, in addition to supporting tons more objects at once.

That said, this particular journey was less about driving some particular real-world impact and more about having fun exploring an interesting design space. This problem turned into a great vehicle for diving into some hitherto unfamiliar distributed systems literature, and owing to the great ideas in there, I find the final design very aesthetically pleasing.

In this writeup I also didn't cover any of the specific implementation details, but there were many interesting bits there as well... turning each process into a deterministically simulable actor, removing all notions of wallclock time from the system, testing out semi-formal methods for verifying the reconfiguration protocol, modeling `Consensus` write operations as a differential dataflow collection, linearizing read operations through Balakrishnan's delightfully named "bus-stand" optimization, turning the metashard state into a tiny state machine on top of a log... I suspect these are topics that will find themselves in posts in the future in some form or another!
