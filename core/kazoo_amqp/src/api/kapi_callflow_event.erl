%%%-------------------------------------------------------------------
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   Max Lay
%%%-------------------------------------------------------------------
-module(kapi_callflow_event).

-export([build_generic_proplist/3]).
-export([bind_q/2, unbind_q/2]).
-export([declare_exchanges/0]).
-export([event/1, event_v/1, publish_event/2]).
-export([publish_callflow_entered/1]).
-export([publish_user_logged_in/1, publish_user_logged_out/1]).
-export([publish_calling_endpoints/1]).
-export([publish_answered/1]).
-export([publish_no_answer/1]).
-export([publish_unavailable/1]).
-export([publish_hangup/1]).
-export([publish_cancel/1]).
-export([publish_entered_voicemail/1]).
-export([publish_left_voicemail/1]).
-export([publish_transferred/1]).

-include_lib("amqp_util.hrl").

-define(CALLFLOW_EVT_ROUTING_KEY(AccountId, CallflowId, Event), <<"event.", AccountId/binary
                                                                 ,".callflow.", CallflowId/binary
                                                                 ,".", Event/binary>>).

-define(EVENT_HEADERS, [<<"Account-ID">>
                       ,<<"Call-ID">>
                       ,<<"Callflow-ID">>
                       ,<<"Timestamp">>
                       ]).
-define(OPTIONAL_EVENT_HEADERS, [<<"User-ID">>
                                ,<<"Group-ID">>
                                ,<<"Endpoints">>
                                ,<<"Endpoint">>
                                ,<<"Called-Number">>
                                ,<<"Mailbox-ID">>
                                ]).

-define(EVENT_VALUES, [{<<"Event-Category">>, <<"callflow_evt">>}]).
-define(EVENT_TYPES, []).

-spec build_generic_proplist(kapps_call:call(), atom(), atom()) -> kz_proplist().
build_generic_proplist(Call, AppName, AppVersion) ->
    AccountId = case kapps_call:account_id(Call) of
                    Id when is_list(Id) -> Id;
                    _ -> kapps_call:custom_channel_var(<<"Account-ID">>, Call)
                end,
    [{<<"Callflow-ID">>, kapps_call:current_callflow_id(Call)}
    ,{<<"Account-ID">>, AccountId}
    ,{<<"Call-ID">>, kapps_call:call_id(Call)}
    ,{<<"Group-ID">>, kapps_call:monster_group_id(Call)}
    ,{<<"Timestamp">>, get_timestamp()}
     | kz_api:default_headers(AppName, AppVersion)
    ].

-spec get_timestamp() -> integer().
get_timestamp() ->
    {Mega, Sec, Micro} = os:timestamp(),
    (Mega*1000000 + Sec)*1000 + round(Micro/1000).

-spec bind_q(ne_binary(), kz_proplist()) -> 'ok'.
bind_q(Queue, Props) ->
    Events = props:get_value('restrict_to', Props, [<<"*">>]),
    AccountId = props:get_value('account_id', Props, <<"*">>),
    CallflowId = props:get_value('callflow_id', Props, <<"*">>),
    bind_qs(Queue, AccountId, CallflowId, Events).

bind_qs(Q, AccountId, CallflowId, [Event|T]) ->
    _ = amqp_util:bind_q_to_kapps(Q, ?CALLFLOW_EVT_ROUTING_KEY(AccountId, CallflowId, Event)),
    bind_qs(Q, AccountId, CallflowId, T);
bind_qs(_Q, _AccountId, _CallflowId, []) -> 'ok'.

-spec unbind_q(ne_binary(), kz_proplist()) -> 'ok'.
unbind_q(Queue, Props) ->
    Events = props:get_value('restrict_to', Props, [<<"*">>]),
    AccountId = props:get_value('account_id', Props, <<"*">>),
    CallflowId = props:get_value('callflow_id', Props, <<"*">>),
    unbind_q_from(Queue, AccountId, CallflowId, Events).

unbind_q_from(Q, AccountId, CallflowId, [Event|T]) ->
    _ = amqp_util:unbind_q_from_kapps(Q, ?CALLFLOW_EVT_ROUTING_KEY(AccountId, CallflowId, Event)),
    unbind_q_from(Q, AccountId, CallflowId, T);
unbind_q_from(_Q, _AccountId, _CallflowId, []) -> 'ok'.

%%--------------------------------------------------------------------
%% @doc
%% Declare the exchanges used by this API
%% @end
%%--------------------------------------------------------------------
-spec declare_exchanges() -> 'ok'.
declare_exchanges() ->
    amqp_util:kapps_exchange().

%%--------------------------------------------------------------------
%% @doc
%% Callflow has been entered
%% @end
%%--------------------------------------------------------------------
-spec event(api_terms()) -> {'ok', iolist()} | {'error', string()}.
event(Prop) when is_list(Prop) ->
    case event_v(Prop) of
        'true' -> kz_api:build_message(Prop, ?EVENT_HEADERS, ?OPTIONAL_EVENT_HEADERS);
        'false' -> {'error', "Proplist failed validation"}
    end;
event(JObj) -> event(kz_json:to_proplist(JObj)).

-spec event_v(api_terms()) -> boolean().
event_v(Prop) when is_list(Prop) ->
    kz_api:validate(Prop, ?EVENT_HEADERS, ?EVENT_VALUES, ?EVENT_TYPES);
event_v(JObj) -> event_v(kz_json:to_proplist(JObj)).

-spec publish_event(api_binary(), api_terms()) -> 'ok'.
publish_event(Event, JObj) ->
    {'ok', Payload} = kz_api:prepare_api_payload(JObj, ?EVENT_VALUES ++ [{<<"Event-Name">>, Event}], fun ?MODULE:event/1),
    AccountId = proplists:get_value(<<"Account-ID">>, JObj),
    CallflowId = proplists:get_value(<<"Callflow-ID">>, JObj),
    amqp_util:kapps_publish(?CALLFLOW_EVT_ROUTING_KEY(AccountId, CallflowId, Event), Payload).

-spec publish_callflow_entered(api_terms()) -> 'ok'.
publish_callflow_entered(JObj) -> publish_event(<<"entered_callflow">>, JObj).

-spec publish_user_logged_in(api_terms()) -> 'ok'.
publish_user_logged_in(JObj) -> publish_event(<<"user_logged_in">>, JObj).

-spec publish_user_logged_out(api_terms()) -> 'ok'.
publish_user_logged_out(JObj) -> publish_event(<<"user_logged_out">>, JObj).

-spec publish_calling_endpoints(api_terms()) -> 'ok'.
publish_calling_endpoints(JObj) -> publish_event(<<"calling_endpoints">>, JObj).

-spec publish_answered(api_terms()) -> 'ok'.
publish_answered(JObj) -> publish_event(<<"answered">>, JObj).

-spec publish_no_answer(api_terms()) -> 'ok'.
publish_no_answer(JObj) -> publish_event(<<"no_answer">>, JObj).

-spec publish_unavailable(api_terms()) -> 'ok'.
publish_unavailable(JObj) -> publish_event(<<"unavailable">>, JObj).

-spec publish_hangup(api_terms()) -> 'ok'.
publish_hangup(JObj) -> publish_event(<<"hangup">>, JObj).

-spec publish_cancel(api_terms()) -> 'ok'.
publish_cancel(JObj) -> publish_event(<<"cancel">>, JObj).

-spec publish_entered_voicemail(api_terms()) -> 'ok'.
publish_entered_voicemail(JObj) -> publish_event(<<"entered_voicemail">>, JObj).

-spec publish_left_voicemail(api_terms()) -> 'ok'.
publish_left_voicemail(JObj) -> publish_event(<<"left_voicemail">>, JObj).

-spec publish_transferred(api_terms()) -> 'ok'.
publish_transferred(JObj) -> publish_event(<<"transferred">>, JObj).
