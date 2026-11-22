%% SPDX-License-Identifier: Apache-2.0

%%% Erlang owns table lifetime, permissions and atomicity. Each row has
%%% exactly two fields: the Pooka key at ETS position 1 and its value at 2.
-module(pooka_otp_ets).

-export([create/6, scan/2, resume/1, insert/3, insert_many/2, insert_new/3,
         insert_new_many/2, lookup/2, contains/2, take/2, delete/2,
         delete_object/3, clear/1, drop/1, entries/1, first/1, last/1,
         next/2, previous/2, size/1, memory_words/1, owner/1, give_away/2,
         set_heir/2, replace/3, compare_exchange/4, increment/4]).

create(Kind, Access, Read, Write, Decentralized, Compressed) ->
    protect(fun() ->
        Compression = case Compressed of true -> [compressed]; false -> [] end,
        ets:new(pooka_table, [kind(Kind), access(Access),
                            {read_concurrency, Read}, {write_concurrency, write_concurrency(Write)},
                            {decentralized_counters, Decentralized} | Compression])
    end).

kind('Kind.Set') -> set;
kind('Kind.OrderedSet') -> ordered_set;
kind('Kind.Bag') -> bag;
kind('Kind.DuplicateBag') -> duplicate_bag.

access('Access.Private') -> private;
access('Access.Protected') -> protected;
access('Access.Public') -> public.

write_concurrency('WriteConcurrency.Disabled') -> false;
write_concurrency('WriteConcurrency.Enabled') -> true;
write_concurrency('WriteConcurrency.Automatic') -> auto.

%% Use native continuations to bound the number of rows returned per batch.
scan(Table, Limit) ->
    protect(fun() -> batch(ets:select(Table, [{'_', [], ['$_']}], Limit)) end).
resume(Cursor) -> protect(fun() -> batch(ets:select(Cursor)) end).

batch('$end_of_table') -> {[], none};
batch({Rows, '$end_of_table'}) -> {Rows, none};
batch({Rows, Cursor}) -> {Rows, {some, Cursor}}.

insert(Table, Key, Value) -> write(fun() -> ets:insert(Table, {Key, Value}) end).
insert_many(Table, Rows) -> write(fun() -> ets:insert(Table, Rows) end).
insert_new(Table, Key, Value) ->
    protect(fun() -> ets:insert_new(Table, {Key, Value}) end).
insert_new_many(Table, Rows) -> protect(fun() -> ets:insert_new(Table, Rows) end).
lookup(Table, Key) -> protect(fun() -> values(ets:lookup(Table, Key)) end).
contains(Table, Key) -> protect(fun() -> ets:member(Table, Key) end).
take(Table, Key) -> protect(fun() -> values(ets:take(Table, Key)) end).
delete(Table, Key) -> write(fun() -> ets:delete(Table, Key) end).
delete_object(Table, Key, Value) ->
    write(fun() -> ets:delete_object(Table, {Key, Value}) end).
clear(Table) -> write(fun() -> ets:delete_all_objects(Table) end).
drop(Table) -> write(fun() -> ets:delete(Table) end).
entries(Table) -> protect(fun() -> ets:tab2list(Table) end).
first(Table) -> protect(fun() -> key(ets:first_lookup(Table)) end).
last(Table) -> protect(fun() -> key(ets:last_lookup(Table)) end).
next(Table, Key) -> protect(fun() -> key(ets:next_lookup(Table, Key)) end).
previous(Table, Key) -> protect(fun() -> key(ets:prev_lookup(Table, Key)) end).

key('$end_of_table') -> none;
key({Key, _Rows}) -> {some, Key}.

values(Rows) -> [Value || {_Key, Value} <- Rows].

size(Table) -> info(Table, size).
memory_words(Table) -> info(Table, memory).
owner(Table) -> info(Table, owner).

info(Table, Item) ->
    protect(fun() ->
        case ets:info(Table, Item) of
            undefined -> error(badarg);
            Value -> Value
        end
    end).

give_away(Table, Recipient) -> write(fun() -> ets:give_away(Table, Recipient, nil) end).
set_heir(Table, Heir) ->
    write(fun() ->
        case Heir of
            none -> ets:setopts(Table, {heir, none});
            {some, Pid} -> ets:setopts(Table, {heir, Pid, nil})
        end
    end).

replace(Table, Key, Value) ->
    protect(fun() -> ets:update_element(Table, Key, {2, Value}) end).

%% Keep user values as constants so atoms such as '$1' are never
%% interpreted as match variables. Preserve the original key in the row.
compare_exchange(Table, Key, Expected, Replacement) ->
    protect(fun() ->
        Spec = [{{'$1', '$2'},
                 [{'=:=', '$1', {const, Key}}, {'=:=', '$2', {const, Expected}}],
                 [{{'$1', {const, Replacement}}}]}],
        ets:select_replace(Table, Spec) =:= 1
    end).

increment(Table, Key, Amount, Starting) ->
    protect(fun() -> ets:update_counter(Table, Key, {2, Amount}, {Key, Starting}) end).

write(Work) -> protect(fun() -> true = Work(), nil end).

protect(Work) ->
    try {ok, Work()}
    catch
        error:badarg -> {error, <<"invalid ETS argument, table unavailable, or access denied">>};
        error:system_limit -> {error, <<"ETS system limit reached">>}
    end.
