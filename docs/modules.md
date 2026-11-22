# Module guide

## Processes and messages

Use `pooka/otp` for typed mailboxes and process lifecycle operations. A `Subject(m)` accepts messages of type `m`. Any process holding the subject can send to it, and the owner reads from it with `receive` or `receive_forever`.

```pooka
module main

import pooka/otp

main() {
  let inbox: otp.Subject(String) = otp.new_subject()
  let _ = otp.spawn(fn() { otp.send(inbox, "hello") })
  assert otp.receive(inbox, 1000) == Some("hello")
}
```

- Use `call` when you need a reply. Its request builder receives a reply subject, and the caller gets a typed timeout or process-down error if the request fails. Late replies after a timeout are dropped.
- Use `schedule` when you need a timer handle to cancel a delayed message. Use `send_after` when you can leave the message scheduled.
- Use `monitor` and `wait_down` when you need to observe another process exiting. A monitor reports the exit without linking the lifetimes of the two processes.
- Create each typed `Name` or `Key` once and retain it across worker restarts. Making another with the same label creates a fresh identity. Values stored under a key are reclaimed when the key's creator exits.

[Processes and messages API](module-pooka@otp.html)

## Servers

Use `pooka/otp/server` for a process that handles one typed protocol and keeps state between messages. The `spec` initializer sets up that state, and each handler returns `next`, `stop`, or `fail`. A class that implements `server.Handler` can supply the callbacks through `from_handler`.

```pooka
module main

import pooka/otp.{Subject}
import pooka/otp/server

main() {
  let spec = server.spec(fn(_) { Ok(0) }, fn(count: Int, reply: Subject(Int)) {
    otp.send(reply, count)
    server.next(count + 1)
  })
  let assert Ok(counter) = server.start(spec)
  assert server.call(counter, fn(reply) { reply }, 1000) == Ok(0)
  assert server.call(counter, fn(reply) { reply }, 1000) == Ok(1)
  server.shutdown(counter)
}
```

Use `continue_with` for work that should run before the next mailbox message, and `next_with_timeout` with an idle handler for work after a quiet period. Give a supervised server a `Name` with `with_name` and call `server.named` when clients should keep reaching it after a restart.

[Server API](module-pooka@otp@server.html)

## State machines

Use `pooka/otp/statem` when the same message means different things in different phases. Keep the phase separate from the data. `stay` updates data within a phase, and `transition` changes the phase. OTP retries postponed messages after the phase changes.

For example, a connection might postpone a write during its handshake and handle it after entering the ready phase. A transition can also queue an `internal` message for immediate follow-up work. Supply these actions with `with_actions`.

| Timer | When it fires |
| --- | --- |
| `event_timeout` | When no other event arrives before the deadline. |
| `state_timeout` | When the deadline passes without a phase change. |
| `named_timeout` | When its deadline passes, even if the phase changes. Scheduling the same name replaces the previous timer. |

Use `send` or `call` to interact with a machine, and `supervisor.statem` to run it as a supervised child. A spec can register a typed name or install an `on_stop` hook.

[State machine API](module-pooka@otp@statem.html)

## Supervisors

Use `pooka/otp/supervisor` to manage worker lifetimes. A supervisor starts children in the order listed in its spec. Use `server`, `statem`, `actor_child`, or `nested` for the corresponding child type. Use `worker` when you already have a function that starts a linked process and returns its PID.

| Strategy | What restarts |
| --- | --- |
| `OneForOne` | The failed child. |
| `OneForAll` | All children. |
| `RestForOne` | The failed child and those listed after it. |

Use `with_restart` on each child to choose when it restarts. A permanent child always restarts, a transient child restarts after an abnormal exit, and a temporary child never restarts. Use `with_intensity` on the supervisor spec to cap restarts in a given period. For a running tree, `children` and `counts` show what is running, and `add`, `terminate`, `restart_child`, and `delete` manage individual children.

[Supervisor API](module-pooka@otp@supervisor.html)

## Applications

Use `pooka/otp/application` when a whole supervision tree should have a name and start or stop as a unit. Pass `application.start` a function that starts the top supervisor. OTP registers the application at runtime, and `application.stop` shuts down its tree.

```pooka
module main

import pooka/otp/application
import pooka/otp/supervisor.{Strategy}

main() {
  let assert Ok(_) = application.start("bakery", "Bread, on time", fn() {
    supervisor.start(supervisor.spec(Strategy.OneForOne, []))
  })
  application.stop("bakery")
}
```

Use `application.running` to list the applications running on the node, including Erlang's own applications.

[Application API](module-pooka@otp@application.html)

## ETS tables

Use `pooka/otp/ets` for typed, in-memory tables shared by processes on one BEAM node. A set keeps one value per key, an ordered set sorts keys, and bags can hold several values per key. A duplicate bag can also store the same row more than once.

```pooka
module main

import pooka/otp/ets

main() {
  let assert Ok(table) = ets.create(ets.Kind.Set, ets.Access.Private)
  assert ets.insert(table, "chapter", 1) == Ok(Nil)
  assert ets.increment(table, "chapter", 1, 0) == Ok(2)
  assert ets.take(table, "chapter") == Ok([2])
  assert ets.drop(table) == Ok(Nil)
}
```

- Use `Private` for owner-only access, `Protected` for shared reads with owner-only writes, and `Public` when multiple processes need to write. `create_with` lets you configure concurrency and compression.
- Use `insert_new` to claim an absent key, `compare_exchange` to replace a matching value, and `take` to remove a key and read its values in one operation. An empty lookup returns `Ok([])`; an unavailable table or denied operation returns `Error`.
- Use `scan` and `resume` to read one batch at a time, or `fold` to reduce rows. These traverse the live table, so concurrent writes can affect what you see.
- The creating process owns the table. When it exits, ETS deletes the table unless a live heir inherits it. Use `set_heir` to arrange inheritance or `give_away` to transfer ownership immediately.

[ETS API](module-pooka@otp@ets.html)
