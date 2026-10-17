%% SPDX-License-Identifier: Apache-2.0

%%% A real OTP supervisor whose children are started by Pooka functions.
%%%
%%% Every child is started through `start_child/1`, which calls the child's
%%% Pooka start function inside the supervisor. Whatever that function starts
%%% with a link, a server or a linked actor, is supervised.
-module(pooka_otp_supervisor).
-behaviour(supervisor).

-export([start/5, add/2, children/1, stop/1, pid/1, start_child/1, terminate/2, restart_child/2, delete/2, counts/1]).
-export([init/1]).

%% start(Name, Strategy, Intensity, Period, Children) -> {ok, Pid} | {error, Text}
%%
%% Each child is #(Id, Start, Restart, IsSupervisor), where Start is
%% fn() -> Result(Pid, String) and Restart is a Pooka `Restart` enum value.
start(Name, Strategy, Intensity, Period, Children) ->
    Arguments = {Strategy, Intensity, Period, Children},
    Started = pooka_otp_ffi:start_linked(fun() ->
        case Name of
            none -> supervisor:start_link(?MODULE, Arguments);
            {some, Text} -> supervisor:start_link({global, {pooka_otp_supervisor, Text}}, ?MODULE, Arguments)
        end
    end),
    case Started of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, _}} -> {error, <<"a supervisor with that name is already running">>};
        {error, {shutdown, {failed_to_start_child, Id, Reason}}} ->
            {error, iolist_to_binary([<<"the child ">>, Id, <<" did not start: ">>, pooka_otp_ffi:reason_text(Reason)])};
        {error, Reason} -> {error, pooka_otp_ffi:reason_text(Reason)}
    end.

add(Supervisor, Child) ->
    case supervisor:start_child(Supervisor, spec(Child)) of
        {ok, Pid} when is_pid(Pid) -> {ok, Pid};
        {ok, Pid, _} when is_pid(Pid) -> {ok, Pid};
        {error, {already_started, _}} -> {error, <<"a child with that id is already running">>};
        {error, already_present} -> {error, <<"a child with that id is already present">>};
        {error, Reason} -> {error, pooka_otp_ffi:reason_text(Reason)}
    end.

%% #(Id, Option(Pid)) for each child, in start order.
children(Supervisor) ->
    lists:reverse([{Id, case Child of Pid when is_pid(Pid) -> {some, Pid}; _ -> none end}
                   || {Id, Child, _, _} <- supervisor:which_children(Supervisor)]).

%% OTP performs ordered shutdown and waits for nested supervisors as configured.
%% There is no unrelated five-second timeout that reports a still-live tree as stopped.
stop(Supervisor) ->
    try gen_server:stop(Supervisor, normal, infinity) of
        ok -> nil
    catch
        exit:noproc -> nil;
        exit:{noproc, _} -> nil
    end.

%% A supervisor handle is its pid.
pid(Supervisor) -> Supervisor.

start_child(Start) ->
    case Start() of
        {ok, Pid} -> {ok, Pid};
        {error, Reason} -> {error, Reason}
    end.

%% --- callback -----------------------------------------------------------------

init({Strategy, Intensity, Period, Children}) ->
    Flags = #{strategy => strategy(Strategy), intensity => Intensity, period => Period},
    {ok, {Flags, [spec(Child) || Child <- Children]}}.

spec({Id, Start, Restart, IsSupervisor, Shutdown}) ->
    #{id => Id,
      start => {?MODULE, start_child, [Start]},
      restart => restart(Restart),
      shutdown => case Shutdown of -1 -> infinity; 0 -> brutal_kill; N -> N end,
      type => case IsSupervisor of true -> supervisor; false -> worker end}.

strategy('Strategy.OneForOne') -> one_for_one;
strategy('Strategy.OneForAll') -> one_for_all;
strategy('Strategy.RestForOne') -> rest_for_one.

restart('Restart.Permanent') -> permanent;
restart('Restart.Transient') -> transient;
restart('Restart.Temporary') -> temporary.


%% Dynamic management retains OTP's distinction between a live child and a
%% retained specification. Expected exits return typed errors to callers.
terminate(Supervisor, Id) -> management(fun() -> supervisor:terminate_child(Supervisor, Id) end).
delete(Supervisor, Id) -> management(fun() -> supervisor:delete_child(Supervisor, Id) end).
restart_child(Supervisor, Id) -> management(fun() -> supervisor:restart_child(Supervisor, Id) end).
management(Run) ->
    try Run() of
        ok -> {ok, nil};
        {ok, Pid} when is_pid(Pid) -> {ok, Pid};
        {ok, Pid, _} when is_pid(Pid) -> {ok, Pid};
        {error, Reason} -> {error, pooka_otp_ffi:reason_text(Reason)}
    catch exit:Reason -> {error, pooka_otp_ffi:reason_text(Reason)}
    end.
counts(Supervisor) ->
    Values = supervisor:count_children(Supervisor),
    {proplists:get_value(specs, Values), proplists:get_value(active, Values),
     proplists:get_value(supervisors, Values), proplists:get_value(workers, Values)}.
