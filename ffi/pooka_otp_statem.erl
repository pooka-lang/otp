%% SPDX-License-Identifier: Apache-2.0

%%% OTP owns the event queue, postponed events and timers. Pooka owns the
%%% event type and replies through the same monitored subjects as otp/server.
-module(pooka_otp_statem).
-behaviour(gen_statem).

-export([start/6, subject_at/3, named/3, stop/1]).
-export([init/1, callback_mode/0, handle_event/4, terminate/3]).

-record(machine, {handle, tidy, data}).

start(Init, Handle, Tidy, Name, Create, Timer) ->
    Args = {Init, Handle, Tidy, Create, Timer},
    Result = pooka_otp_ffi:start_linked(fun() ->
        case Name of
            none -> gen_statem:start_link(?MODULE, Args, [{timeout, 5000}]);
            {some, Id} -> gen_statem:start_link(address(Id), ?MODULE, Args, [{timeout, 5000}])
        end
    end),
    case Result of
        {ok, Pid} -> {ok, Pid};
        {error, Reason} -> {error, pooka_otp_ffi:reason_text(Reason)}
    end.

address(Id) -> {global, {?MODULE, Id}}.

subject_at(Pid, Create, Timer) -> pooka_otp_ffi:cast_subject(Pid, Create, Timer).
named(Id, Create, Timer) -> pooka_otp_ffi:cast_subject(address(Id), Create, Timer).

stop(Pid) ->
    try gen_statem:stop(Pid) of ok -> nil
    catch exit:_ -> nil
    end.

callback_mode() -> handle_event_function.

init({Init, Handle, Tidy, Create, Timer}) ->
    process_flag(trap_exit, true),
    case Init(subject_at(self(), Create, Timer)) of
        {ok, {State, Data, Actions}} ->
            {ok, State, #machine{handle = Handle, tidy = Tidy, data = Data}, actions(Actions)};
        {error, Reason} -> {stop, Reason}
    end.

handle_event(Type, {'$pooka_cast', Message}, State, Machine)
  when Type =:= cast; Type =:= info ->
    step(State, Message, Machine);
handle_event(Type, Message, State, Machine)
  when Type =:= internal; Type =:= timeout; Type =:= state_timeout ->
    step(State, Message, Machine);
handle_event({timeout, _Name}, Message, State, Machine) ->
    step(State, Message, Machine);
handle_event({call, From}, _, _, _) ->
    {keep_state_and_data, [{reply, From, {error, unsupported_request}}]};
handle_event(_, _, _, _) ->
    keep_state_and_data.

step(State, Message, #machine{handle = Handle, data = Data} = Machine) ->
    case Handle(State, Data, Message) of
        {ok, {none, Next, Actions}} ->
            {keep_state, Machine#machine{data = Next}, actions(Actions)};
        {ok, {{some, Phase}, Next, Actions}} ->
            {next_state, Phase, Machine#machine{data = Next}, actions(Actions)};
        {error, {true, _}} -> {stop, normal};
        {error, {false, Reason}} -> {stop, {pooka_stop, Reason}}
    end.

terminate(Reason, State, #machine{tidy = {some, Tidy}, data = Data}) ->
    Tidy(State, Data, pooka_otp_ffi:reason_text(Reason)),
    ok;
terminate(_, _, _) -> ok.

%% The action kinds follow OTP's distinct timeout and queue semantics.
%% https://www.erlang.org/doc/apps/stdlib/gen_statem.html#t:action/0
actions(Actions) -> [action(A) || A <- Actions].

action({'_ActionKind.Postpone', none, _, _}) -> postpone;
action({'_ActionKind.Hibernate', none, _, _}) -> hibernate;
action({'_ActionKind.Internal', {some, Message}, _, _}) -> {next_event, internal, Message};
action({'_ActionKind.EventTimeout', {some, Message}, Ms, _}) -> {timeout, max(Ms, 0), Message};
action({'_ActionKind.StateTimeout', {some, Message}, Ms, _}) -> {state_timeout, max(Ms, 0), Message};
action({'_ActionKind.NamedTimeout', {some, Message}, Ms, Name}) -> {{timeout, Name}, max(Ms, 0), Message};
action({'_ActionKind.CancelEventTimeout', none, _, _}) -> {timeout, cancel};
action({'_ActionKind.CancelStateTimeout', none, _, _}) -> {state_timeout, cancel};
action({'_ActionKind.CancelNamedTimeout', none, _, Name}) -> {{timeout, Name}, cancel}.
