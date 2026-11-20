%% Real nodes, restricted to loopback, with a fresh cookie for this demo VM.
%% A standard-IO control channel survives disconnecting distribution, so the
%% peer can always be stopped in the after clause. No application logic lives here.
-module(pooka_otp_distribution_test).
-export([with_peer/1, create/2, disconnect/1, reconnect/1]).

with_peer(Work) ->
    distribution(),
    Name = list_to_atom("pooka_demo_sensor_" ++ integer_to_list(erlang:unique_integer([positive]))),
    Paths = [P || P <- code:get_path(), filelib:is_dir(P)],
    Args = ["-setcookie", atom_to_list(erlang:get_cookie()),
            "-kernel", "inet_dist_use_interface", "{127,0,0,1}",
            "dist_auto_connect", "never", "-pa" | Paths],
    {ok, Peer, Node} = peer:start_link(#{name => Name, host => "127.0.0.1",
        longnames => true, connection => standard_io, args => Args, wait_boot => 10000}),
    try
        true = net_kernel:connect_node(Node),
        Work(Peer)
    after
        peer:stop(Peer)
    end.

%% Pooka tests run concurrently. Claim only the one-time distribution boot;
%% peers and the actual assertions remain independent of each other.
distribution() ->
    distribution_lock(erlang:monotonic_time(millisecond) + 10000).

distribution_lock(Deadline) ->
    Claim = try ets:new(?MODULE, [named_table])
            catch error:badarg -> busy end,
    case Claim of
        busy ->
            true = erlang:monotonic_time(millisecond) < Deadline,
            receive after 5 -> distribution_lock(Deadline) end;
        _ ->
            try distribution_start()
            after ets:delete(?MODULE) end
    end.

distribution_start() ->
    case node() of
        nonode@nohost ->
            {ok, _} = application:ensure_all_started(crypto),
            application:set_env(kernel, inet_dist_use_interface, {127,0,0,1}),
            application:set_env(kernel, dist_auto_connect, never),
            Name = list_to_atom("pooka_demo_controller_" ++ os:getpid() ++ "@127.0.0.1"),
            {ok, _} = net_kernel:start(Name, #{name_domain => longnames}),
            erlang:set_cookie(node(), binary_to_atom(binary:encode_hex(crypto:strong_rand_bytes(16)), utf8)),
            ok;
        Existing ->
            true = lists:prefix("pooka_demo_controller_", atom_to_list(Existing)),
            ok
    end.

%% Run the Pooka factory on the peer; all assertions and worker behaviour
%% remain in the Pooka test module loaded on both nodes.
create(Peer, Factory) ->
    peer:call(Peer, erlang, apply, [Factory, []]).

disconnect(Peer) ->
    Node = peer:call(Peer, erlang, node, []),
    true = erlang:disconnect_node(Node),
    nil.

reconnect(Peer) ->
    Node = peer:call(Peer, erlang, node, []),
    true = net_kernel:connect_node(Node),
    nil.
