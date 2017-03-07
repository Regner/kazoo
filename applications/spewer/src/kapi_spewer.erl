%%%-------------------------------------------------------------------
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   Max Lay
%%%-------------------------------------------------------------------
-module(kapi_spewer).
-include_lib("spewer.hrl").


-export([bind_q/2
        ,unbind_q/2
        ]).
-export([declare_exchanges/0]).

-export([dialed/1, dialed_v/1, publish_dialed/1]).
-export([executing_callflow_element/1, executing_callflow_element_v/1, publish_executing_callflow_element/1]).

-define(EVENT(AccountId, Entity, EntityId, Event), <<"spewer.", (kz_term:to_binary(AccountId))/binary
                                                    ,".", (kz_term:to_binary(Entity))/binary, ".", (kz_term:to_binary(EntityId))/binary
                                                    ,".", (kz_term:to_binary(Event))/binary>>).
-define(USER_EVENT(Prop, Event), <<"spewer.", (props:get_value(<<"Account-ID">>, Prop))/binary
                                  ,".user.", (props:get_value(<<"User-ID">>, Prop))/binary
                                  ,".", (kz_term:to_binary(Event))/binary>>).
-define(DEVICE_EVENT(Prop, Event), <<"spewer.", (props:get_value(<<"Account-ID">>, Prop))/binary
                                    ,".device.", (props:get_value(<<"Device-ID">>, Prop))/binary
                                    ,".", (kz_term:to_binary(Event))/binary>>).
-define(CALLFLOW_EVENT(Prop, Event), <<"spewer.", (props:get_value(<<"Account-ID">>, Prop))/binary
                                      ,".callflow.", (props:get_value(<<"Callflow-ID">>, Prop))/binary
                                      ,".", (kz_term:to_binary(Event))/binary>>).

-define(DEFAULT_HEADERS, [<<"Account-ID">>, <<"Timestamp">>, <<"Event-ID">>, <<"Entity">>]).
-define(DEFAULT_VALUES, [{<<"App-Name">>, ?APP_NAME}
                        ,{<<"App-Version">>, ?APP_VERSION}
                        ,{<<"Event-Category">>, <<"spewer">>}
                        ]).

-define(USER_HEADERS, [<<"User-ID">>]).
-define(USER_VALUES, [{<<"Entity">>, <<"user">>}]).
-define(USER_TYPES, []).

-define(DEVICE_HEADERS, [<<"Device-ID">>]).
-define(DEVICE_VALUES, [{<<"Entity">>, <<"device">>}]).
-define(DEVICE_TYPES, []).

-define(CALLFLOW_HEADERS, [<<"Callflow-ID">>]).
-define(CALLFLOW_VALUES, [{<<"Entity">>, <<"callflow">>}]).
-define(CALLFLOW_TYPES, []).

-type entity() :: 'device' | 'user' | 'callflow'.

-spec entity_v(api_terms(), entity()) -> boolean().
entity_v(Prop, 'user') when is_list(Prop) ->
    kz_api:validate(Prop, ?USER_HEADERS, ?USER_VALUES, ?USER_TYPES);
entity_v(Prop, 'device') when is_list(Prop) ->
    kz_api:validate(Prop, ?DEVICE_HEADERS, ?DEVICE_VALUES, ?DEVICE_TYPES);
entity_v(Prop, 'callflow') when is_list(Prop) ->
    kz_api:validate(Prop, ?CALLFLOW_HEADERS, ?CALLFLOW_VALUES, ?CALLFLOW_TYPES);
entity_v(JObj, Entity) -> entity_v(kz_json:to_proplist(JObj), Entity).

maybe_send_entity_event(Entity, Props, Values, BuildFun, Name) ->
    case entity_v(Props, Entity) of
        'true' -> 'ok';
        'false' -> send_entity_event(Entity, Props, Values, BuildFun, Name)
    end.

send_entity_event('user', Props, Values, BuildFun, Name) ->
    {'ok', Payload} = kz_api:prepare_api_payload(Props, ?USER_VALUES ++ Values, BuildFun),
    amqp_util:kapps_publish(?USER_EVENT(Props, Name), Payload);
send_entity_event('device', Props, Values, BuildFun, Name) ->
    {'ok', Payload} = kz_api:prepare_api_payload(Props, ?DEVICE_VALUES ++ Values, BuildFun),
    amqp_util:kapps_publish(?DEVICE_EVENT(Props, Name), Payload);
send_entity_event('callflow', Props, Values, BuildFun, Name) ->
    {'ok', Payload} = kz_api:prepare_api_payload(Props, ?CALLFLOW_VALUES ++ Values, BuildFun),
    amqp_util:kapps_publish(?CALLFLOW_EVENT(Props, Name), Payload).

-spec bind_q(ne_binary(), kz_proplist()) -> 'ok'.
bind_q(Q, Props) ->
    AccountId = props:get_value('account_id', Props, <<"*">>),
    Entities = props:get_value('entities', Props, [{<<"*">>, <<"*">>}]),
    bind_q(Q, AccountId, Entities).
bind_q(Q, AccountId, [{Entity, EntityId} | Remaining]) ->
    amqp_util:bind_q_to_kapps(Q, ?EVENT(AccountId, Entity, EntityId, <<"*">>)),
    bind_q(Q, AccountId, Remaining);
bind_q(_Q, _AccountId, _) ->
    'ok'.

-spec unbind_q(ne_binary(), kz_proplist()) -> 'ok'.
unbind_q(Q, Props) ->
    AccountId = props:get_value('account_id', Props, <<"*">>),
    Entities = props:get_value('entities', [{<<"*">>, <<"*">>}]),
    unbind_q(Q, AccountId, Entities).
unbind_q(Q, AccountId, [{Entity, EntityId} | Remaining]) ->
    amqp_util:unbind_q_to_kapps(Q, ?EVENT(AccountId, Entity, EntityId, <<"*">>)),
    unbind_q(Q, AccountId, Remaining);
unbind_q(_Q, _AccountId, _) ->
    'ok'.

%%--------------------------------------------------------------------
%% @doc
%% declare the exchanges used by this API
%% @end
%%--------------------------------------------------------------------
%% TODO: Consider changing exchange
-spec declare_exchanges() -> 'ok'.
declare_exchanges() ->
    amqp_util:kapps_exchange().

extra_props(Props) ->
   [{<<"Event-ID">>, kz_datamgr:get_uuid()}
   %% Should this really be here?
   %% TODO: Investigate AMQP props - hope for timestamp
   ,{<<"Timestamp">>, timestamp()} | Props].

-spec timestamp() -> integer().
timestamp() ->
    {Mega, Sec, Micro} = os:timestamp(),
    (Mega*1000000 + Sec)*1000 + round(Micro/1000).

%%--------------------------------------------------------------------
-define(DIALED_EVENT_NAME, <<"dialed">>).
-define(DIALED_HEADERS, [<<"Number">>
                        ,<<"User-ID">>
                        ,<<"Device-ID">>
                        | ?DEFAULT_HEADERS]).
-define(OPTIONAL_DIALED_HEADERS, ?USER_HEADERS ++ ?DEVICE_HEADERS).
-define(DIALED_VALUES, [{<<"Event-Name">>, ?DIALED_EVENT_NAME}
                       | ?DEFAULT_VALUES]).
-define(DIALED_TYPES, []).

-spec dialed(api_terms()) -> {'ok', iolist()} | {'error', string()}.
dialed(Prop) when is_list(Prop) ->
    case dialed_v(Prop) of
        'true' -> kz_api:build_message(Prop, ?DIALED_HEADERS, ?OPTIONAL_DIALED_HEADERS);
        'false' -> {'error', "Proplist failed validation"}
    end;
dialed(JObj) -> dialed(kz_json:to_proplist(JObj)).

-spec dialed_v(api_terms()) -> boolean().
dialed_v(Prop) when is_list(Prop) ->
    kz_api:validate(Prop, ?DIALED_HEADERS, ?DIALED_VALUES, ?DIALED_TYPES);
dialed_v(JObj) -> dialed_v(kz_json:to_proplist(JObj)).

-spec publish_dialed(api_terms()) -> 'ok'.
publish_dialed(Props) ->
    NewProps = extra_props(Props),
    maybe_send_entity_event('user', NewProps, ?DIALED_VALUES, fun dialed/1, ?DIALED_EVENT_NAME),
    maybe_send_entity_event('device', NewProps, ?DIALED_VALUES, fun dialed/1, ?DIALED_EVENT_NAME).
%%--------------------------------------------------------------------
%%--------------------------------------------------------------------
-define(EXECUTING_CALLFLOW_ELEMENT_EVENT_NAME, <<"executing_callflow_element">>).
-define(EXECUTING_CALLFLOW_ELEMENT_HEADERS, [<<"User-ID">>
                                            ,<<"Device-ID">>
                                            ,<<"Module">>
                                            ,<<"Module-Data">>
                                            | ?DEFAULT_HEADERS]).
-define(OPTIONAL_EXECUTING_CALLFLOW_ELEMENT_HEADERS, ?USER_HEADERS ++ ?DEVICE_HEADERS).
-define(EXECUTING_CALLFLOW_ELEMENT_VALUES, [{<<"Event-Name">>, ?EXECUTING_CALLFLOW_ELEMENT_EVENT_NAME}
                                           | ?DEFAULT_VALUES]).
-define(EXECUTING_CALLFLOW_ELEMENT_TYPES, []).

-spec executing_callflow_element(api_terms()) -> {'ok', iolist()} | {'error', string()}.
executing_callflow_element(Prop) when is_list(Prop) ->
    case executing_callflow_element_v(Prop) of
        'true' -> kz_api:build_message(Prop, ?EXECUTING_CALLFLOW_ELEMENT_HEADERS, ?OPTIONAL_EXECUTING_CALLFLOW_ELEMENT_HEADERS);
        'false' -> {'error', "Proplist failed validation"}
    end;
executing_callflow_element(JObj) -> executing_callflow_element(kz_json:to_proplist(JObj)).

-spec executing_callflow_element_v(api_terms()) -> boolean().
executing_callflow_element_v(Prop) when is_list(Prop) ->
    kz_api:validate(Prop, ?EXECUTING_CALLFLOW_ELEMENT_HEADERS, ?EXECUTING_CALLFLOW_ELEMENT_VALUES, ?EXECUTING_CALLFLOW_ELEMENT_TYPES);
executing_callflow_element_v(JObj) -> executing_callflow_element_v(kz_json:to_proplist(JObj)).

-spec publish_executing_callflow_element(api_terms()) -> 'ok'.
publish_executing_callflow_element(Props) ->
    NewProps = extra_props(Props),
    maybe_send_entity_event('user', NewProps, ?EXECUTING_CALLFLOW_ELEMENT_VALUES, fun executing_callflow_element/1, ?EXECUTING_CALLFLOW_ELEMENT_EVENT_NAME),
    maybe_send_entity_event('device', NewProps, ?EXECUTING_CALLFLOW_ELEMENT_VALUES, fun executing_callflow_element/1, ?EXECUTING_CALLFLOW_ELEMENT_EVENT_NAME).
%%--------------------------------------------------------------------
