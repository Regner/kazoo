%%%-------------------------------------------------------------------
%%% @doc
%%% Used to send messages TO spewer
%%% @end
%%% @contributors
%%%   Max Lay
%%%-------------------------------------------------------------------
-module(kapi_spewer_message).

-include_lib("spewer.hrl").
%-include_lib("amqp_util.hrl").


-export([bind_q/2
        ,unbind_q/2
        ]).
-export([declare_exchanges/0]).
-export([executing_callflow_element/1, executing_callflow_element_v/1, publish_executing_callflow_element/1]).
-export([entered_callflow/1, entered_callflow_v/1, publish_entered_callflow/1]).

-spec bind_q(ne_binary(), kz_proplist()) -> 'ok'.
bind_q(Q, Props) ->
    CallId = props:get_value('callid', Props, <<"*">>),
    amqp_util:bind_q_to_kapps(Q, <<"spewer_message.", (amqp_util:encode(CallId))/binary, ".*">>).

-spec unbind_q(ne_binary(), kz_proplist()) -> 'ok'.
unbind_q(Q, Props) ->
    CallId = props:get_value('callid', Props, <<"*">>),
    amqp_util:unbind_q_from_kapps(Q, <<"spewer_message.", (amqp_util:encode(CallId))/binary, ".*">>).

call_id(JObj) when is_list(JObj) ->
    props:get_value(<<"Call-ID">>, JObj);
call_id(JObj) ->
    kz_json:get_value(<<"Call-ID">>, JObj).

%%--------------------------------------------------------------------
%% @doc
%% declare the exchanges used by this API
%% @end
%%--------------------------------------------------------------------
-spec declare_exchanges() -> 'ok'.
declare_exchanges() ->
    amqp_util:kapps_exchange().


%%-----------------------------------------------------------------------------------------------
-define(EXECUTING_CALLFLOW_ELEMENT(CallId), <<"spewer_message.", (amqp_util:encode(CallId))/binary
                                             ,".executing_element">>).
-define(EXECUTING_CALLFLOW_ELEMENT_HEADERS, [<<"Call-ID">>, <<"Module">>, <<"Module-Data">>]).
-define(OPTIONAL_EXECUTING_CALLFLOW_ELEMENT_HEADERS, []).
-define(EXECUTING_CALLFLOW_ELEMENT_VALUES, [{<<"Event-Category">>, <<"spewer_message">>}
                                           ,{<<"Event-Name">>, <<"executing_callflow_element">>}
                                           ]).
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
publish_executing_callflow_element(JObj) ->
    {'ok', Payload} = kz_api:prepare_api_payload(JObj, ?EXECUTING_CALLFLOW_ELEMENT_VALUES, fun executing_callflow_element/1),
    amqp_util:kapps_publish(?EXECUTING_CALLFLOW_ELEMENT(call_id(JObj)), Payload).
%%-----------------------------------------------------------------------------------------------
%%-----------------------------------------------------------------------------------------------
-define(ENTERED_CALLFLOW(CallId), <<"spewer_message.", (amqp_util:encode(CallId))/binary
                                   ,".entered_callflow">>).
-define(ENTERED_CALLFLOW_HEADERS, [<<"Call-ID">>, <<"Callflow-ID">>]).
-define(OPTIONAL_ENTERED_CALLFLOW_HEADERS, []).
-define(ENTERED_CALLFLOW_VALUES, [{<<"Event-Category">>, <<"spewer_message">>}
                                 ,{<<"Event-Name">>, <<"entered_callflow">>}
                                 ]).
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
publish_entered_callflow(JObj) ->
    {'ok', Payload} = kz_api:prepare_api_payload(JObj, ?ENTERED_CALLFLOW_VALUES, fun entered_callflow/1),
    amqp_util:kapps_publish(?ENTERED_CALLFLOW(call_id(JObj)), Payload).
%%-----------------------------------------------------------------------------------------------
