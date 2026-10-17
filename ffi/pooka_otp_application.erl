%% SPDX-License-Identifier: Apache-2.0

%%% A real OTP application, described at run time, whose top supervisor is
%%% started by a Pooka function.
-module(pooka_otp_application).
-behaviour(application).

-export([start/3, stop/1, running/0]).
-export([start/2]).

%% start(Name, Description, Top) -> {ok, nil} | {error, Text}
start(Name, Description, Top) ->
    App = binary_to_atom(Name, utf8),
    Resource = {application, App,
                [{description, binary_to_list(Description)},
                 {vsn, "0.0.0"},
                 {modules, []},
                 {registered, []},
                 {applications, [kernel, stdlib]},
                 {mod, {?MODULE, Top}}]},
    case load(App, Resource) of
        ok -> started(App);
        {error, Reason} -> {error, Reason}
    end.

%% An application left loaded by an earlier start of ours is loaded again, with
%% the new top function. Any other application with that name belongs to
%% someone else, often a package: Pooka loads every package as an application.
load(App, Resource) ->
    case application:get_key(App, mod) of
        undefined -> plain_load(Resource);
        {ok, {?MODULE, _}} ->
            case lists:keymember(App, 1, application:which_applications()) of
                true -> {error, <<"the application is already running">>};
                false -> application:unload(App), plain_load(Resource)
            end;
        {ok, _} -> taken(App);
        {ok, []} -> taken(App)
    end.

plain_load(Resource) ->
    case application:load(Resource) of
        ok -> ok;
        {error, Reason} -> {error, pooka_otp_ffi:reason_text(Reason)}
    end.

taken(App) ->
    {error, iolist_to_binary([<<"the name ">>, atom_to_binary(App),
        <<" belongs to another application, such as a package; choose another">>])}.

started(App) ->
    case application:start(App) of
        ok -> {ok, nil};
        {error, {already_started, App}} -> {error, <<"the application is already running">>};
        {error, {Reason, _}} -> {error, pooka_otp_ffi:reason_text(Reason)};
        {error, Reason} -> {error, pooka_otp_ffi:reason_text(Reason)}
    end.

stop(Name) when is_binary(Name) ->
    %% Stopping an unknown application must not allocate another permanent atom.
    try application:stop(binary_to_existing_atom(Name, utf8))
    catch error:badarg -> ok
    end,
    nil;
%% The application callback.
stop(_State) ->
    ok.

running() ->
    [atom_to_binary(App) || {App, _, _} <- application:which_applications()].

%% The application callback: start the top supervisor.
start(_Type, Top) ->
    case Top() of
        {ok, Pid} -> {ok, Pid};
        {error, Reason} -> {error, Reason}
    end.
