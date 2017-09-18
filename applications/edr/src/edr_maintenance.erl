%%%-------------------------------------------------------------------
%%% @copyright (C) 2016, 2600Hz
%%% @doc
%%% Sup commands for EDR backends
%%% @end
%%% @contributors
%%%    SIPLABS, LLC (Vorontsov Nikita) <info@siplabs.ru>
%%%    Conversant Ltd (Max Lay)
%%%-------------------------------------------------------------------
-module(edr_maintenance).

-include("edr.hrl").

-export([registered_backends/0
        ,register_backend/1, register_backend/2, register_backend/3, register_backend/4, register_backend/5
        ,delete_backend/1
        ,enable_backend/1
        ,disable_backend/1
        ]).

-spec register_backend(ne_binary())-> 'ok' | {'error', 'already_registered'}.
-spec register_backend(ne_binary(), ne_binary())-> 'ok' | {'error', 'already_registered'}.
-spec register_backend(ne_binary(), ne_binary(), ne_binary() | kz_json:object())-> 'ok' | {'error', 'already_registered'}.
-spec register_backend(ne_binary(), ne_binary(), ne_binary() | kz_json:object(), ne_binary() | kz_json:objects())-> 'ok' | {'error', 'already_registered'}.
-spec register_backend(ne_binary(), ne_binary(), ne_binary() | kz_json:object(), ne_binary() | kz_json:objects(), ne_binary() | boolean())-> 'ok' | {'error', 'already_registered'}.
register_backend(Name) ->
   register_backend(Name, Name).
register_backend(Name, Type) ->
   register_backend(Name, Type, kz_json:new()).
register_backend(Name, Type, Opts) ->
   register_backend(Name, Type, Opts, edr_bindings:bindings_to_json([#edr_binding{}])).
register_backend(Name, Type, Opts, Bindings) ->
   register_backend(Name, Type, Opts, Bindings, 'true').
register_backend(Name, Type, Opts, Bindings, Enabled) when is_binary(Opts) ->
   register_backend(Name, Type, kz_json:decode(Opts), Bindings, Enabled);
register_backend(Name, Type, Opts, Bindings, Enabled) when is_binary(Bindings) ->
   register_backend(Name, Type, Opts, kz_json:decode(Bindings), Enabled);
register_backend(Name, Type, Opts, Bindings, Enabled) when is_binary(Enabled) ->
   register_backend(Name, Type, Opts, Bindings, kz_term:is_true(Enabled));
register_backend(Name, Type, Opts, Bindings, Enabled) ->
    Backends = registered_backends(),
    case [J || J <- Backends, match_backend(Name, J)] of
        [] ->
            Backend = kz_json:from_list([{<<"name">>, Name}
                                        ,{<<"type">>, Type}
                                        ,{<<"options">>, Opts}
                                        ,{<<"bindings">>, Bindings}
                                        ,{<<"enabled">>, Enabled}
                                        ]),
            set_registered_backends([Backend | Backends]),
            case kz_term:is_true(Enabled) of
                'true' ->
                    edr_backend_sup:start_backend(Name),
                    'ok';
                'false' ->
                    'ok'
            end;
        _V ->
            {'error', 'already_registered'}
    end.

-spec delete_backend(ne_binary())-> 'ok'.
delete_backend(Name) ->
    Backends = registered_backends(),
    case [J || J <- Backends, match_backend(Name, J)] of
        [] ->
            {'error', 'not_registered'};
        _ ->
            edr_backend_sup:stop_backend(Name),
            set_registered_backends([J || J <- Backends, not match_backend(Name, J)])
    end.

-spec enable_backend(ne_binary())-> 'ok' | {'error', 'not_registered'}.
enable_backend(Name) ->
    edr_backend_sup:start_backend(Name),
    modify_backend(Name, fun(Backend) -> kz_json:set_value(<<"enabled">>, 'true', Backend) end).

-spec disable_backend(ne_binary()) -> 'ok'.
disable_backend(Name)->
    edr_backend_sup:stop_backend(Name),
    modify_backend(Name, fun(Backend) -> kz_json:set_value(<<"enabled">>, 'false', Backend) end).

-spec modify_backend(ne_binary(), fun((kz_json:object()) -> kz_json:object())) -> 'ok' | {'error', 'not_registered'}.
modify_backend(Name, Fun) ->
    Backends = registered_backends(),
    case [J || J <- Backends, match_backend(Name, J)] of
        [] ->
            {'error', 'not_registered'};
        _ ->
            set_registered_backends([maybe_modify_backend(Name, Fun, J) || J <- Backends])
    end.

-spec maybe_modify_backend(ne_binary(), fun((kz_json:object()) -> kz_json:object()), kz_json:object()) -> kz_json:object().
maybe_modify_backend(Name, Fun, JObj) ->
    case match_backend(Name, JObj) of
        'true' -> Fun(JObj);
        'false' -> JObj
    end.

-spec registered_backends() -> kz_json:object().
registered_backends() -> 
    kapps_config:get_jsons(<<"edr">>, <<"backends">>, []).

-spec match_backend(ne_binary(), kz_json:object()) -> boolean().
match_backend(Name, JObj) ->
    kz_json:get_binary_value(<<"name">>, JObj) =:= Name.

-spec set_registered_backends(kz_json:objects()) -> 'ok'.
set_registered_backends(NewBackends) ->
    {'ok', _} = kapps_config:set(<<"edr">>, <<"backends">>, NewBackends),
    'ok'.
