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
-export([entered_callflow/1, entered_callflow_v/1, publish_entered_callflow/1]).
-export([calling/1, calling_v/1, publish_calling/1]).
-export([answered/1, answered_v/1, publish_answered/1]).
-export([hangup/1, hangup_v/1, publish_hangup/1]).
-export([callee_busy/1, callee_busy_v/1, publish_callee_busy/1]).

-define(EVENT(AccountId, Entity, EntityId, Event), <<"spewer.", (kz_term:to_binary(AccountId))/binary
                                                    ,".", (kz_term:to_binary(Entity))/binary, ".", (kz_term:to_binary(EntityId))/binary
                                                    ,".", (kz_term:to_binary(Event))/binary>>).

-define(DEFAULT_HEADERS, [<<"Account-ID">>, <<"Timestamp">>, <<"Event-ID">>, <<"Entity-Type">>, <<"Entity-ID">>, <<"Caller-Call-ID">>]).
-define(DEFAULT_VALUES, [{<<"Event-Category">>, <<"spewer">>}]).

-define(USER_ID_HEADERS, [<<"Caller-User-ID">>, <<"Callee-User-ID">>]).
-define(DEVICE_ID_HEADERS, [<<"Caller-Device-ID">>, <<"Callee-Device-ID">>]).
-define(CALLFLOW_ID_HEADERS, [<<"Callflow-ID">>]).

%%-type entity() :: binary(). %% <<"device">> | <<"user">> | <<"callflow">>.

entity_id_fields(<<"user">>) -> ?USER_ID_HEADERS;
entity_id_fields(<<"device">>) -> ?DEVICE_ID_HEADERS;
entity_id_fields(<<"callflow">>) -> ?CALLFLOW_ID_HEADERS.

send_entity_events(Entity, Props, Values, BuildFun, Name) ->
    send_entity_events(Entity, Props, Values, BuildFun, Name, entity_id_fields(Entity)).
send_entity_events(_Entity, _Props, _Values, _BuildFun, _Name, []) ->
    'ok';
send_entity_events(Entity, Props, Values, BuildFun, Name, [Field | Rest]) ->
    case props:get_value(Field, Props) of
        'undefined' ->
            'ok';
        EntityId ->
            AccountId = props:get_value(<<"Account-ID">>, Props),
            NewProps = [{<<"Entity-Type">>, Entity}
                       ,{<<"Entity-ID">>, EntityId}
                       | Props],
            {'ok', Payload} = kz_api:prepare_api_payload(NewProps, Values, BuildFun),
            amqp_util:kapps_publish(?EVENT(AccountId, Entity, EntityId, Name), Payload)
    end,
    send_entity_events(Entity, Props, Values, BuildFun, Name, Rest).

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
                        | ?DEFAULT_HEADERS]).
-define(OPTIONAL_DIALED_HEADERS, ?USER_ID_HEADERS ++ ?DEVICE_ID_HEADERS).
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
    send_entity_events(<<"user">>, NewProps, ?DIALED_VALUES, fun dialed/1, ?DIALED_EVENT_NAME),
    send_entity_events(<<"device">>, NewProps, ?DIALED_VALUES, fun dialed/1, ?DIALED_EVENT_NAME).
%%--------------------------------------------------------------------
%%--------------------------------------------------------------------
-define(EXECUTING_CALLFLOW_ELEMENT_EVENT_NAME, <<"executing_callflow_element">>).
-define(EXECUTING_CALLFLOW_ELEMENT_HEADERS, [<<"Callflow-Module">>
                                            ,<<"Callflow-Module-Data">>
                                            ,<<"Callflow-ID">>
                                            | ?DEFAULT_HEADERS]).
-define(OPTIONAL_EXECUTING_CALLFLOW_ELEMENT_HEADERS, ?USER_ID_HEADERS ++ ?DEVICE_ID_HEADERS).
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
    send_entity_events(<<"user">>, NewProps, ?EXECUTING_CALLFLOW_ELEMENT_VALUES, fun executing_callflow_element/1, ?EXECUTING_CALLFLOW_ELEMENT_EVENT_NAME),
    send_entity_events(<<"device">>, NewProps, ?EXECUTING_CALLFLOW_ELEMENT_VALUES, fun executing_callflow_element/1, ?EXECUTING_CALLFLOW_ELEMENT_EVENT_NAME),
    send_entity_events(<<"callflow">>, NewProps, ?EXECUTING_CALLFLOW_ELEMENT_VALUES, fun executing_callflow_element/1, ?EXECUTING_CALLFLOW_ELEMENT_EVENT_NAME).
%%--------------------------------------------------------------------
%%--------------------------------------------------------------------
-define(ENTERED_CALLFLOW_EVENT_NAME, <<"entered_callflow">>).
-define(ENTERED_CALLFLOW_HEADERS, [<<"Callflow-ID">>
                                  ,<<"Callflow-Data">>
                                  | ?DEFAULT_HEADERS]).
-define(OPTIONAL_ENTERED_CALLFLOW_HEADERS, ?USER_ID_HEADERS ++ ?DEVICE_ID_HEADERS).
-define(ENTERED_CALLFLOW_VALUES, [{<<"Event-Name">>, ?ENTERED_CALLFLOW_EVENT_NAME}
                                 | ?DEFAULT_VALUES]).
-define(ENTERED_CALLFLOW_TYPES, []).

-spec entered_callflow(api_terms()) -> {'ok', iolist()} | {'error', string()}.
entered_callflow(Prop) when is_list(Prop) ->
    case entered_callflow_v(Prop) of
        'true' -> kz_api:build_message(Prop, ?ENTERED_CALLFLOW_HEADERS, ?OPTIONAL_ENTERED_CALLFLOW_HEADERS);
        'false' -> {'error', "Proplist failed validation"}
    end;
entered_callflow(JObj) -> entered_callflow(kz_json:to_proplist(JObj)).

-spec entered_callflow_v(api_terms()) -> boolean().
entered_callflow_v(Prop) when is_list(Prop) ->
    kz_api:validate(Prop, ?ENTERED_CALLFLOW_HEADERS, ?ENTERED_CALLFLOW_VALUES, ?ENTERED_CALLFLOW_TYPES);
entered_callflow_v(JObj) -> entered_callflow_v(kz_json:to_proplist(JObj)).

-spec publish_entered_callflow(api_terms()) -> 'ok'.
publish_entered_callflow(Props) ->
    NewProps = extra_props(Props),
    send_entity_events(<<"user">>, NewProps, ?ENTERED_CALLFLOW_VALUES, fun entered_callflow/1, ?ENTERED_CALLFLOW_EVENT_NAME),
    send_entity_events(<<"device">>, NewProps, ?ENTERED_CALLFLOW_VALUES, fun entered_callflow/1, ?ENTERED_CALLFLOW_EVENT_NAME),
    send_entity_events(<<"callflow">>, NewProps, ?ENTERED_CALLFLOW_VALUES, fun entered_callflow/1, ?ENTERED_CALLFLOW_EVENT_NAME).
%%--------------------------------------------------------------------
%%--------------------------------------------------------------------
-define(CALLING_EVENT_NAME, <<"calling">>).
-define(CALLING_HEADERS, [<<"Type">>
                         ,<<"Callee-Call-ID">>
                         | ?DEFAULT_HEADERS]).
-define(OPTIONAL_CALLING_HEADERS, [<<"Callee-User-ID">>
                                  ,<<"Callee-Device-ID">>
                                  | ?USER_ID_HEADERS ++ ?DEVICE_ID_HEADERS]).
-define(CALLING_VALUES, [{<<"Event-Name">>, ?CALLING_EVENT_NAME}
                        | ?DEFAULT_VALUES]).
-define(CALLING_TYPES, []).

-spec calling(api_terms()) -> {'ok', iolist()} | {'error', string()}.
calling(Prop) when is_list(Prop) ->
    case calling_v(Prop) of
        'true' -> kz_api:build_message(Prop, ?CALLING_HEADERS, ?OPTIONAL_CALLING_HEADERS);
        'false' -> {'error', "Proplist failed validation"}
    end;
calling(JObj) -> calling(kz_json:to_proplist(JObj)).

-spec calling_v(api_terms()) -> boolean().
calling_v(Prop) when is_list(Prop) ->
    kz_api:validate(Prop, ?CALLING_HEADERS, ?CALLING_VALUES, ?CALLING_TYPES);
calling_v(JObj) -> calling_v(kz_json:to_proplist(JObj)).

-spec publish_calling(api_terms()) -> 'ok'.
publish_calling(Props) ->
    NewProps = extra_props(Props),
    send_entity_events(<<"user">>, NewProps, ?CALLING_VALUES, fun calling/1, ?CALLING_EVENT_NAME),
    send_entity_events(<<"device">>, NewProps, ?CALLING_VALUES, fun calling/1, ?CALLING_EVENT_NAME),
    send_entity_events(<<"callflow">>, NewProps, ?CALLING_VALUES, fun calling/1, ?CALLING_EVENT_NAME).
%%--------------------------------------------------------------------
%%--------------------------------------------------------------------
-define(ANSWERED_EVENT_NAME, <<"answered">>).
-define(ANSWERED_HEADERS, [<<"Type">>
                          ,<<"Callee-Call-ID">>
                          | ?DEFAULT_HEADERS]).
-define(OPTIONAL_ANSWERED_HEADERS, [<<"Callee-User-ID">>
                                   ,<<"Callee-Device-ID">>
                                   | ?USER_ID_HEADERS ++ ?DEVICE_ID_HEADERS]).
-define(ANSWERED_VALUES, [{<<"Event-Name">>, ?ANSWERED_EVENT_NAME}
                         | ?DEFAULT_VALUES]).
-define(ANSWERED_TYPES, []).

-spec answered(api_terms()) -> {'ok', iolist()} | {'error', string()}.
answered(Prop) when is_list(Prop) ->
    case answered_v(Prop) of
        'true' -> kz_api:build_message(Prop, ?ANSWERED_HEADERS, ?OPTIONAL_ANSWERED_HEADERS);
        'false' -> {'error', "Proplist failed validation"}
    end;
answered(JObj) -> answered(kz_json:to_proplist(JObj)).

-spec answered_v(api_terms()) -> boolean().
answered_v(Prop) when is_list(Prop) ->
    kz_api:validate(Prop, ?ANSWERED_HEADERS, ?ANSWERED_VALUES, ?ANSWERED_TYPES);
answered_v(JObj) -> answered_v(kz_json:to_proplist(JObj)).

-spec publish_answered(api_terms()) -> 'ok'.
publish_answered(Props) ->
    NewProps = extra_props(Props),
    send_entity_events(<<"user">>, NewProps, ?ANSWERED_VALUES, fun answered/1, ?ANSWERED_EVENT_NAME),
    send_entity_events(<<"device">>, NewProps, ?ANSWERED_VALUES, fun answered/1, ?ANSWERED_EVENT_NAME),
    send_entity_events(<<"callflow">>, NewProps, ?ANSWERED_VALUES, fun answered/1, ?ANSWERED_EVENT_NAME).
%%--------------------------------------------------------------------
%%--------------------------------------------------------------------
-define(HANGUP_EVENT_NAME, <<"hangup">>).
-define(HANGUP_HEADERS, [<<"Reason">>
                            %%,<<"Callee-Call-ID">>
                            | ?DEFAULT_HEADERS]).
-define(OPTIONAL_HANGUP_HEADERS, [<<"Callee-User-ID">>
                                     ,<<"Callee-Device-ID">>
                                     | ?USER_ID_HEADERS ++ ?DEVICE_ID_HEADERS]).
-define(HANGUP_VALUES, [{<<"Event-Name">>, ?HANGUP_EVENT_NAME}
                           | ?DEFAULT_VALUES]).
-define(HANGUP_TYPES, []).

-spec hangup(api_terms()) -> {'ok', iolist()} | {'error', string()}.
hangup(Prop) when is_list(Prop) ->
    case hangup_v(Prop) of
        'true' -> kz_api:build_message(Prop, ?HANGUP_HEADERS, ?OPTIONAL_HANGUP_HEADERS);
        'false' -> {'error', "Proplist failed validation"}
    end;
hangup(JObj) -> hangup(kz_json:to_proplist(JObj)).

-spec hangup_v(api_terms()) -> boolean().
hangup_v(Prop) when is_list(Prop) ->
    kz_api:validate(Prop, ?HANGUP_HEADERS, ?HANGUP_VALUES, ?HANGUP_TYPES);
hangup_v(JObj) -> hangup_v(kz_json:to_proplist(JObj)).

-spec publish_hangup(api_terms()) -> 'ok'.
publish_hangup(Props) ->
    NewProps = extra_props(Props),
    send_entity_events(<<"user">>, NewProps, ?HANGUP_VALUES, fun hangup/1, ?HANGUP_EVENT_NAME),
    send_entity_events(<<"device">>, NewProps, ?HANGUP_VALUES, fun hangup/1, ?HANGUP_EVENT_NAME),
    send_entity_events(<<"callflow">>, NewProps, ?HANGUP_VALUES, fun hangup/1, ?HANGUP_EVENT_NAME).
%%--------------------------------------------------------------------
%%--------------------------------------------------------------------
-define(CALLEE_BUSY_EVENT_NAME, <<"callee_busy">>).
-define(CALLEE_BUSY_HEADERS, %%,<<"Callee-Call-ID">>
                             ?DEFAULT_HEADERS).
-define(OPTIONAL_CALLEE_BUSY_HEADERS, [<<"Callee-User-ID">>
                                      ,<<"Callee-Device-ID">>
                                      | ?USER_ID_HEADERS ++ ?DEVICE_ID_HEADERS]).
-define(CALLEE_BUSY_VALUES, [{<<"Event-Name">>, ?CALLEE_BUSY_EVENT_NAME}
                           | ?DEFAULT_VALUES]).
-define(CALLEE_BUSY_TYPES, []).

-spec callee_busy(api_terms()) -> {'ok', iolist()} | {'error', string()}.
callee_busy(Prop) when is_list(Prop) ->
    case callee_busy_v(Prop) of
        'true' -> kz_api:build_message(Prop, ?CALLEE_BUSY_HEADERS, ?OPTIONAL_CALLEE_BUSY_HEADERS);
        'false' -> {'error', "Proplist failed validation"}
    end;
callee_busy(JObj) -> callee_busy(kz_json:to_proplist(JObj)).

-spec callee_busy_v(api_terms()) -> boolean().
callee_busy_v(Prop) when is_list(Prop) ->
    kz_api:validate(Prop, ?CALLEE_BUSY_HEADERS, ?CALLEE_BUSY_VALUES, ?CALLEE_BUSY_TYPES);
callee_busy_v(JObj) -> callee_busy_v(kz_json:to_proplist(JObj)).

-spec publish_callee_busy(api_terms()) -> 'ok'.
publish_callee_busy(Props) ->
    NewProps = extra_props(Props),
    send_entity_events(<<"user">>, NewProps, ?CALLEE_BUSY_VALUES, fun callee_busy/1, ?CALLEE_BUSY_EVENT_NAME),
    send_entity_events(<<"device">>, NewProps, ?CALLEE_BUSY_VALUES, fun callee_busy/1, ?CALLEE_BUSY_EVENT_NAME),
    send_entity_events(<<"callflow">>, NewProps, ?CALLEE_BUSY_VALUES, fun callee_busy/1, ?CALLEE_BUSY_EVENT_NAME).
%%--------------------------------------------------------------------

