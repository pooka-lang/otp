%% SPDX-License-Identifier: Apache-2.0

%%% A real gen_server whose callbacks are Pooka functions.
%%%
%%% The server state is the Pooka state plus the functions that handle it.
%%% Casts and calls both reach the same Pooka `handle` function: a call simply
%%% carries a reply subject inside its message, made by the caller's `make`
%%% function, and the handler answers by sending to it.
-module(pooka_otp_server).
-behaviour(gen_server).

-export([start/10, stop/1, named_subject/3, pid_subject/3]).
-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2, handle_continue/2]).

-record(server, {handle, on_stop, state, continuation, idle}).

%% start/10 returns a native PID; Pooka wraps it in a real Server capability.
%% Handle/Continue/Idle return state plus a typed scheduling action, or a stop.
%% Name is a fresh binary registry identity, not an atom created from user input.
start(_Init, _Handle, _OnStop, _Name, Timeout, _Continue, _Idle, _InitialContinue, _Create, _Timer)
  when Timeout < 0; Timeout > 16#ffffffff ->
    {error, <<"init timeout must be between 0 and 4294967295 milliseconds">>};
start(Init, Handle, OnStop, Name, Timeout, Continue, Idle, InitialContinue, Create, Timer) ->
    Arguments = {Init, Handle, OnStop, Continue, Idle, InitialContinue, Create, Timer},
    Options = [{timeout, Timeout}],
    Started = pooka_otp_ffi:start_linked(fun() ->
        case Name of
            none -> gen_server:start_link(?MODULE, Arguments, Options);
            {some, Text} -> gen_server:start_link({global, {pooka_otp_server, Text}}, ?MODULE, Arguments, Options)
        end
    end),
    case Started of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, _}} -> {error, <<"a process with that name is already running">>};
        {error, Reason} -> {error, pooka_otp_ffi:reason_text(Reason)}
    end.

%% Binary identities use the native registry without creating atoms.
named_subject(Identity, Create, Timer) ->
    pooka_otp_ffi:cast_subject({global, {pooka_otp_server, Identity}}, Create, Timer).
pid_subject(Pid, Create, Timer) -> pooka_otp_ffi:cast_subject(Pid, Create, Timer).

stop(Server) ->
    try gen_server:stop(Server) of
        ok -> nil
    catch
        exit:_ -> nil
    end.

%% --- callbacks ----------------------------------------------------------------

init({Init, Handle, OnStop, Continue, Idle, InitialContinue, Create, Timer}) ->
    process_flag(trap_exit, true),
    case Init(pooka_otp_ffi:cast_subject(self(), Create, Timer)) of
        {ok, State} ->
            Server = #server{handle = Handle, on_stop = OnStop, state = State,
                             continuation = Continue, idle = Idle},
            case InitialContinue of
                true -> {ok, Server, {continue, run}};
                false -> {ok, Server}
            end;
        {error, Reason} -> {error, Reason}
    end.

handle_cast({'$pooka_cast', Message}, Server) ->
    step(Message, Server).

handle_call(_Request, _From, Server) ->
    {reply, {error, unsupported_request}, Server}.

%% Timers made with send_after arrive as plain messages.
handle_info({'$pooka_cast', Message}, Server) ->
    step(Message, Server);
handle_info(timeout, #server{idle = {some, Work}, state = State} = Server) ->
    outcome(Work(State), Server);
handle_info(Other, Server) ->
    logger:notice("pooka_otp server ~p ignored an unexpected message: ~0tp", [self(), Other]),
    {noreply, Server}.

terminate(Reason, #server{on_stop = {some, OnStop}, state = State}) ->
    OnStop(State, pooka_otp_ffi:reason_text(Reason)),
    ok;
terminate(_, _) ->
    ok.

step(Message, #server{handle = Handle, state = State} = Server) ->
    outcome(Handle(State, Message), Server).

%% Continuations run before ordinary mailbox messages, not in a spawned process.
%% https://www.erlang.org/doc/apps/stdlib/gen_server.html#c:handle_continue/2
handle_continue(run, #server{continuation = {some, Work}, state = State} = Server) ->
    outcome(Work(State), Server);
handle_continue(run, Server) ->
    {stop, {pooka_stop, <<"continuation callback is not configured">>}, Server}.

outcome({ok, {Next, Action, Timeout}}, Server) ->
    {noreply, Server#server{state = Next}, action(Action, Timeout)};
outcome({error, {true, _}}, Server) -> {stop, normal, Server};
outcome({error, {false, Reason}}, Server) -> {stop, {pooka_stop, Reason}, Server}.

action('Action.Continue', _) -> {continue, run};
action('Action.Hibernate', _) -> hibernate;
action('Action.Wait', none) -> infinity;
action('Action.Wait', {some, Milliseconds}) -> max(Milliseconds, 0).
