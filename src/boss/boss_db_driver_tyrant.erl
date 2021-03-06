-module(boss_db_driver_tyrant).
-behaviour(boss_db_driver).
-export([start/0, start/1, stop/0, find/1, find/6]).
-export([count/2, counter/1, incr/2, delete/1, save_record/1]).

-define(TRILLION, (1000 * 1000 * 1000 * 1000)).

start() ->
    start([]).

start(_Options) ->
    medici:start().

stop() ->
    medici:stop().

find(Id) when is_list(Id) ->
    find(list_to_binary(Id));
find(<<"">>) ->
    undefined;
find(Id) when is_binary(Id) ->
    Type = infer_type_from_id(Id),
    case medici:get(Id) of
        Record when is_list(Record) ->
            case model_is_loaded(Type) of
                true ->
                    activate_record(Record, Type);
                false ->
                    {error, {module_not_loaded, Type}}
            end;
        {error, invalid_operation} ->
            undefined;
        {error, Reason} ->
            {error, Reason}
    end;

find(_Id) -> {error, invalid_id}.

find(Type, Conditions, Max, Skip, Sort, SortOrder) when is_atom(Type), is_list(Conditions), is_integer(Max),
                                                        is_integer(Skip), is_atom(Sort), is_atom(SortOrder) ->
    case model_is_loaded(Type) of
        true ->
            Query = build_query(Type, Conditions, Max, Skip, Sort, SortOrder),
            lists:map(fun({_Id, Record}) -> activate_record(Record, Type) end,
                medici:mget(medici:search(Query)));
        false ->
            []
    end.

count(Type, Conditions) ->
    medici:searchcount(build_conditions(Type, Conditions)).

counter(Id) when is_list(Id) ->
    counter(list_to_binary(Id));
counter(Id) when is_binary(Id) ->
    case medici:get(Id) of
        Record when is_list(Record) ->
            list_to_integer(binary_to_list(
                    proplists:get_value(<<"_num">>, Record, <<"0">>)));
        {error, _Reason} -> 0
    end.

incr(Id, Count) ->
    medici:addint(Id, Count).

delete(Id) when is_list(Id) ->
    delete(list_to_binary(Id));
delete(Id) when is_binary(Id) ->
    medici:out(Id).

save_record(Record) when is_tuple(Record) ->
    Type = element(1, Record),
    Id = case Record:id() of
        id ->
            atom_to_list(Type) ++ "-" ++ binary_to_list(medici:genuid());
        Defined when is_list(Defined) ->
            Defined
    end,
    RecordWithId = Record:id(Id),
    PackedRecord = pack_record(RecordWithId, Type),

    Result = medici:put(list_to_binary(Id), PackedRecord),
    case Result of
        ok -> {ok, RecordWithId};
        {error, Error} -> {error, [Error]}
    end.

pack_record(RecordWithId, Type) ->
    % metadata string stores the data types, <Data Type><attribute name>
    {Columns, MetadataString} = lists:mapfoldl(fun
            (Attr, Acc) -> 
                Val = RecordWithId:Attr(),
                MagicLetter = case Val of
                    _Val when is_list(_Val) ->    "L";
                    {_, _, _} ->                  "T"; % time
                    {{_, _, _}, {_, _, _}} ->     "T";
                    _Val when is_binary(_Val) ->  "B";
                    _Val when is_integer(_Val) -> "I"; 
                    _Val when is_float(_Val) ->   "F"
                end,
                {{attribute_to_colname(Attr), pack_value(Val)}, 
                    lists:concat([Attr, MagicLetter, Acc])}
        end, [], RecordWithId:attribute_names()),
    [{attribute_to_colname('_type'), list_to_binary(atom_to_list(Type))},
        {attribute_to_colname('_metadata'), list_to_binary(MetadataString)}|Columns].

infer_type_from_id(Id) when is_binary(Id) ->
    infer_type_from_id(binary_to_list(Id));
infer_type_from_id(Id) when is_list(Id) ->
    list_to_atom(hd(string:tokens(Id, "-"))).

extract_metadata(Record, _Type) ->
    MetadataString = proplists:get_value(attribute_to_colname('_metadata'), Record),
    case MetadataString of
        undefined -> [];
        Val when is_binary(Val) -> 
            parse_metadata_string(binary_to_list(Val))
    end.

parse_metadata_string(Val) ->
    parse_metadata_string(Val, [], []).
parse_metadata_string([], [], MetadataAcc) ->
    MetadataAcc;
parse_metadata_string([H|T], NameAcc, MetadataAcc) when H >= $A, H =< $Z ->
    parse_metadata_string(T, [], [{list_to_atom(lists:reverse(NameAcc)), H}|MetadataAcc]);
parse_metadata_string([H|T], NameAcc, MetadataAcc) when H >= $a, H =< $z; H =:= $_; H >= $0, H =< $9 ->
    parse_metadata_string(T, [H|NameAcc], MetadataAcc).

activate_record(Record, Type) ->
    DummyRecord = apply(Type, new, lists:seq(1, proplists:get_value(new, Type:module_info(exports)))),
    Metadata = extract_metadata(Record, Type),
    apply(Type, new, lists:map(fun
                (Key) ->
                    Val = proplists:get_value(attribute_to_colname(Key), Record, <<"">>),
                    case proplists:get_value(Key, Metadata) of
                        $B -> Val;
                        $I -> list_to_integer(binary_to_list(Val));
                        $F -> list_to_integer(binary_to_list(Val)) / ?TRILLION;
                        $T -> unpack_datetime(Val);
                        _ ->
                            case lists:suffix("_time", atom_to_list(Key)) of
                                true -> unpack_datetime(Val);
                                false -> binary_to_list(Val)
                            end
                    end
            end, DummyRecord:attribute_names())).

model_is_loaded(Type) ->
    case code:is_loaded(Type) of
        {file, _Loaded} ->
            Exports = Type:module_info(exports),
            case proplists:get_value(attribute_names, Exports) of
                1 -> true;
                _ -> false
            end;
        false -> false
    end.

attribute_to_colname(Attribute) ->
    list_to_binary(atom_to_list(Attribute)).

build_query(Type, Conditions, Max, Skip, Sort, SortOrder) ->
    Query = build_conditions(Type, Conditions),
    medici:query_order(medici:query_limit(Query, Max, Skip), atom_to_list(Sort), SortOrder).

build_conditions(Type, Conditions) ->
    build_conditions1([{'_type', 'equals', atom_to_list(Type)}|Conditions], []).

build_conditions1([], Acc) ->
    Acc;
build_conditions1([{Key, 'equals', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, str_eq, pack_value(Value)));
build_conditions1([{Key, 'not_equals', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, {no, str_eq}, pack_value(Value)));
build_conditions1([{Key, 'in', Value}|Rest], Acc) when is_list(Value) ->
    PackedValues = pack_tokens(Value),
    build_conditions1(Rest, add_cond(Acc, Key, str_in_list, PackedValues));
build_conditions1([{Key, 'not_in', Value}|Rest], Acc) when is_list(Value) ->
    PackedValues = pack_tokens(Value),
    build_conditions1(Rest, add_cond(Acc, Key, {no, str_in_list}, PackedValues));
build_conditions1([{Key, 'in', {Min, Max}}|Rest], Acc) when Max >= Min ->
    PackedValues = pack_tokens([Min, Max]),
    build_conditions1(Rest, add_cond(Acc, Key, num_between, PackedValues));
build_conditions1([{Key, 'not_in', {Min, Max}}|Rest], Acc) when Max >= Min ->
    PackedValues = pack_tokens([Min, Max]),
    build_conditions1(Rest, add_cond(Acc, Key, {no, num_between}, PackedValues));
build_conditions1([{Key, 'gt', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, num_gt, pack_value(Value)));
build_conditions1([{Key, 'lt', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, num_lt, pack_value(Value)));
build_conditions1([{Key, 'ge', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, num_ge, pack_value(Value)));
build_conditions1([{Key, 'le', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, num_le, pack_value(Value)));
build_conditions1([{Key, 'matches', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, str_regex, pack_value(Value)));
build_conditions1([{Key, 'not_matches', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, {no, str_regex}, pack_value(Value)));
build_conditions1([{Key, 'contains', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, str_and, pack_value(Value)));
build_conditions1([{Key, 'not_contains', Value}|Rest], Acc) ->
    build_conditions1(Rest, add_cond(Acc, Key, {no, str_and}, pack_value(Value)));
build_conditions1([{Key, 'contains_all', Values}|Rest], Acc) when is_list(Values) ->
    build_conditions1(Rest, add_cond(Acc, Key, str_and, pack_tokens(Values)));
build_conditions1([{Key, 'not_contains_all', Values}|Rest], Acc) when is_list(Values) ->
    build_conditions1(Rest, add_cond(Acc, Key, {no, str_and}, pack_tokens(Values)));
build_conditions1([{Key, 'contains_any', Values}|Rest], Acc) when is_list(Values) ->
    build_conditions1(Rest, add_cond(Acc, Key, str_or, pack_tokens(Values)));
build_conditions1([{Key, 'contains_none', Values}|Rest], Acc) when is_list(Values) ->
    build_conditions1(Rest, add_cond(Acc, Key, {no, str_or}, pack_tokens(Values))).

add_cond(Acc, Key, Op, PackedVal) ->
    medici:query_add_condition(Acc, attribute_to_colname(Key), Op, [PackedVal]).

pack_tokens(Tokens) ->
    list_to_binary(string:join(lists:map(fun(V) -> binary_to_list(pack_value(V)) end, Tokens), " ")).

pack_datetime({Date, Time}) ->
    list_to_binary(integer_to_list(calendar:datetime_to_gregorian_seconds({Date, Time}))).

pack_now(Now) -> pack_datetime(calendar:now_to_datetime(Now)).

pack_value(V) when is_binary(V) ->
    V;
pack_value(V) when is_list(V) ->
    list_to_binary(V);
pack_value({MegaSec, Sec, MicroSec}) when is_integer(MegaSec) andalso is_integer(Sec) andalso is_integer(MicroSec) ->
    pack_now({MegaSec, Sec, MicroSec});
pack_value({{_, _, _}, {_, _, _}} = Val) ->
    pack_datetime(Val);
pack_value(Val) when is_integer(Val) ->
    list_to_binary(integer_to_list(Val));
pack_value(Val) when is_float(Val) ->
    list_to_binary(integer_to_list(trunc(Val * ?TRILLION))).

unpack_datetime(<<"">>) -> calendar:gregorian_seconds_to_datetime(0);
unpack_datetime(Bin) -> calendar:universal_time_to_local_time(
        calendar:gregorian_seconds_to_datetime(list_to_integer(binary_to_list(Bin)))).
