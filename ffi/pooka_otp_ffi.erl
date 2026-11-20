%% SPDX-License-Identifier: Apache-2.0

%%% Native identities stay behind Pooka capability constructors.
%%% An alias revokes the delivery address when a request finishes; a monitor
%%% still reports failure. Neither tag is used as a Pooka class representation.
-module(pooka_otp_ffi).
-export([me/0, identity/1, new_subject/2, cast_subject/3, call/6, new_key/1,
         spawn/1, spawn_link/1, is_alive/1, kill/1, sleep/1, sleep_forever/0,
         actor_pid/1, link_actor/1, set_log_level/1, reason_text/1, start_linked/1, new_monitor/3, link/1, unlink/1, mailbox_size/0, trap_exits/1, receive_exit/2]).

me() -> self().
identity(Label) -> <<Label/binary, $#, (base64:encode(term_to_binary(make_ref())))/binary>>.

new_subject(Create, Timer) -> subject({mailbox, self(), make_ref()}, Create, Timer).
cast_subject(Server, Create, Timer) -> subject({cast, Server}, Create, Timer).

%% Each callback validates operations on the private native shape. Only the
%% constructor callback makes the Pooka object, using the compiler's own layout.
subject(Address, Create, Timer) ->
    Create(fun(M) -> post(Address, M) end,
           fun(T) -> read(Address, T) end,
           fun() -> read_forever(Address) end,
           fun() -> owner(Address) end,
           fun(T, M) -> schedule(Address, T, M, Timer) end,
           fun(Pid, M) -> post_at(Address, Pid, M) end).

owner({mailbox, Pid, _}) -> live(Pid);
owner({alias, _, Pid, _}) -> live(Pid);
owner({cast, Pid}) when is_pid(Pid) -> live(Pid);
owner({cast, {global, Name}}) ->
    case global:whereis_name(Name) of undefined -> none; Pid -> live(Pid) end.
%% is_process_alive/1 is local-only. A remote address is a capability, not a
%% liveness guarantee; call/6 installs a monitor before sending and reports
%% noproc or noconnection through the ordinary typed failure result.
live(Pid) when node(Pid) =:= node() ->
    case is_process_alive(Pid) of true -> {some, Pid}; false -> none end;
live(Pid) -> {some, Pid}.

post({mailbox, Pid, Ref}, M) -> Pid ! {Ref, M}, nil;
post({alias, Alias, _, Ref}, M) -> Alias ! {Ref, M}, nil;
post({cast, Server}, M) -> gen_server:cast(Server, {'$pooka_cast', M}), nil.

%% Resolve a named request once, then send to the monitored process. A restart
%% between lookup and send must not deliver work to an unmonitored replacement.
post_at({cast, _}, Pid, M) -> gen_server:cast(Pid, {'$pooka_cast', M}), nil;
post_at(Address, _Pid, M) -> post(Address, M).

read({mailbox, Pid, Ref}, T) when Pid =:= self() ->
    receive {Ref, M} -> {some, M} after max(T, 0) -> none end;
read(_, _) -> erlang:error(pooka_otp_not_owner).
read_forever({mailbox, Pid, Ref}) when Pid =:= self() ->
    receive {Ref, M} -> M end;
read_forever(_) -> erlang:error(pooka_otp_not_owner).

%% A cast timer resolves a registered name at delivery. Revoked aliases simply
%% drop the message. Timer cancellation does not remove an already delivered one.
schedule({mailbox, Pid, Ref}, T, M, Create) ->
    native_schedule(T, Pid, {Ref, M}, Create);
schedule({cast, Pid}, T, M, Create) when is_pid(Pid) ->
    native_schedule(T, Pid, {'$pooka_cast', M}, Create);
schedule(Address, T, M, Create) ->
    Pid = spawn(fun() ->
        receive cancel -> exit(cancelled)
        after max(T, 0) -> post(Address, M)
        end
    end),
    Deadline = erlang:monotonic_time(millisecond) + max(T, 0),
    %% Named destinations and revocable aliases need delayed resolution.
    %% Their intermediary owns one cancel-or-deliver race.
    Create(fun() -> cancel_delivery(Pid) end,
           fun() -> case is_process_alive(Pid) of
               true -> {some, max(0, Deadline-erlang:monotonic_time(millisecond))};
               false -> none
           end end).

%% Ordinary mailbox and server-PID timers stay inside the VM timer wheel.
native_schedule(T, Pid, Message, Create) ->
    Ref = erlang:send_after(max(T, 0), Pid, Message),
    Create(fun() -> case erlang:cancel_timer(Ref) of false -> false; _ -> true end end,
           fun() -> case erlang:read_timer(Ref) of false -> none; N -> {some, N} end end).

cancel_delivery(Pid) ->
    Ref = monitor(process, Pid),
    Pid ! cancel,
    %% Claim success only if cancellation won the worker's receive race.
    receive {'DOWN', Ref, process, Pid, cancelled} -> true;
            {'DOWN', Ref, process, Pid, _} -> false end.

%% Alias revocation and monitor cleanup also run if Make or Post raises.
%% https://www.erlang.org/doc/system/ref_man_processes.html#process-aliases
call(Post, Owner, Make, Create, Timer, Timeout) ->
    case Owner() of
        none -> {error, {some, <<"noproc">>}};
        {some, Pid} ->
            Monitor = monitor(process, Pid), Alias = alias(), Ref = make_ref(),
            try
                Reply = subject({alias, Alias, self(), Ref}, Create, Timer),
                Post(Pid, Make(Reply)),
                receive
                    {Ref, Answer} -> {ok, Answer};
                    {'DOWN', Monitor, process, Pid, Reason} ->
                        {error, {some, reason_text(Reason)}}
                after max(Timeout, 0) -> {error, none}
                end
            after
                unalias(Alias), demonitor(Monitor, [flush]), flush_reply(Ref)
            end
    end.
flush_reply(Ref) -> receive {Ref, _} -> flush_reply(Ref) after 0 -> ok end.

%% Keys may cross a process boundary, but their storage has an owner. One table
%% serves the creator's keys; ETS tidies it away when that process leaves.
%% A fresh reference keeps equal labels from sharing a slot or changing its type.
new_key(Create) ->
    Tag = {?MODULE, key_table},
    Table = case erlang:get(Tag) of
        undefined ->
            New = ets:new(pooka_otp_keys, [set, public, {read_concurrency, true}]),
            erlang:put(Tag, New),
            New;
        Existing -> Existing
    end,
    Ref = make_ref(),
    Create(fun(V) ->
               try ets:insert(Table, {Ref, V}), nil
               catch error:badarg -> error(pooka_otp_key_expired) end
           end,
           fun() ->
               try ets:lookup(Table, Ref) of
                   [] -> none;
                   [{Ref, V}] -> {some, V}
               catch error:badarg -> none end
           end,
           fun() ->
               try ets:delete(Table, Ref), nil
               catch error:badarg -> nil end
           end).

spawn(Fun) -> erlang:spawn(Fun).
spawn_link(Fun) -> erlang:spawn_link(Fun).
is_alive(Pid) -> erlang:is_process_alive(Pid).
kill(Pid) -> exit(Pid, kill), nil.

sleep(Milliseconds) -> timer:sleep(max(Milliseconds, 0)), nil.
sleep_forever() -> receive after infinity -> nil end.

%% A native Pooka actor handle, as the runtime makes it. This is the one place
%% that depends on the runtime's layout; it is checked against Pooka 0.3.0.
actor_pid({'$pooka_actor', _, _, Pid}) when is_pid(Pid) -> {some, Pid};
actor_pid(_) -> none.

%% Tie an actor to the calling process, a supervisor, so its crash is noticed.
link_actor(Actor) ->
    case actor_pid(Actor) of
        {some, Pid} -> erlang:link(Pid), {ok, Pid};
        none -> {error, <<"the start function did not return a Pooka actor">>}
    end.

set_log_level(Level) ->
    Erlang = case Level of
        'LogLevel.Debug' -> debug;
        'LogLevel.Info' -> info;
        'LogLevel.Notice' -> notice;
        'LogLevel.Warning' -> warning;
        'LogLevel.Error' -> error;
        'LogLevel.Critical' -> critical
    end,
    logger:set_primary_config(level, Erlang),
    nil.

%% An exit reason, as text a person can read.
reason_text(normal) -> <<"normal">>;
reason_text(shutdown) -> <<"shutdown">>;
reason_text({shutdown, Reason}) -> reason_text(Reason);
reason_text(Reason) when is_binary(Reason) -> Reason;
reason_text({{pooka_stop, Reason}, _Stack}) -> Reason;
reason_text({pooka_stop, Reason}) -> Reason;
reason_text(Reason) -> unicode:characters_to_binary(io_lib:format("~0tp", [Reason])).


%% Preserve the caller's flags even when Start raises. proc_lib owns its child
%% startup handshake; this wrapper must never consume an arbitrary EXIT message.
start_linked(Start) ->
    Previous = process_flag(trap_exit, true),
    try Start()
    after process_flag(trap_exit, Previous)
    end.


%% Each monitor owns one reference, so waiting and cancellation cannot consume
%% another monitor's notification. The owner check matches mailbox ownership.
new_monitor(Pid, Create, Down) ->
    Owner = self(), Ref = erlang:monitor(process, Pid),
    Create(fun(T) when self() =:= Owner ->
               receive {'DOWN', Ref, process, Process, Reason} ->
                   {some, Down(Process, reason_text(Reason))}
               after max(T, 0) -> none
               end;
              (_) -> erlang:error(pooka_otp_not_owner)
           end,
           fun() when self() =:= Owner -> erlang:demonitor(Ref, [flush]);
              () -> erlang:error(pooka_otp_not_owner)
           end).
link(Pid) -> erlang:link(Pid), nil.
unlink(Pid) -> erlang:unlink(Pid), nil.


mailbox_size() -> {message_queue_len, N} = process_info(self(), message_queue_len), N.
trap_exits(Enabled) -> process_flag(trap_exit, Enabled).
receive_exit(Timeout, Down) ->
    receive {'EXIT', Pid, Reason} when is_pid(Pid) -> {some, Down(Pid, reason_text(Reason))}
    after max(Timeout, 0) -> none
    end.
