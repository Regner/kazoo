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

-export([dialed/1, dialed_v/1]).
-export([publish_dialed/1]).

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

-define(DIALED_HEADERS, [<<"Number">>, <<"Account-ID">>, <<"User-ID">>, <<"Device-ID">>]).
-define(OPTIONAL_DIALED_HEADERS, []).
%% Maybe make this say whether it is a user, device, callflow, etc
-define(DIALED_VALUES, [{<<"Event-Category">>, <<"spewer">>}
                       ,{<<"Event-Name">>, <<"dialed">>}
                       ,{<<"App-Name">>, ?APP_NAME}
                       ,{<<"App-Version">>, ?APP_VERSION}
                       ]).
-define(DIALED_TYPES, []).

-spec bind_q(ne_binary(), kz_proplist()) -> 'ok'.
bind_q(Q, Props) ->
    AccountId = props:get_value('account_id', Props, <<"*">>),
    Entities = props:get_value('entities', [{<<"*">>, <<"*">>}]),
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

%%--------------------------------------------------------------------
%% @doc A number was dialed
%% Takes proplist, creates JSON iolist or error
%% @end
%%--------------------------------------------------------------------
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

%%--------------------------------------------------------------------
%% @doc Publish the JSON iolist() to the proper Exchange
%% @end
%%--------------------------------------------------------------------
-spec publish_dialed(api_terms()) -> 'ok'.
publish_dialed(Event) ->
    {'ok', Payload} = kz_api:prepare_api_payload(Event, ?DIALED_VALUES, fun dialed/1),
    amqp_util:kapps_publish(?DEVICE_EVENT(Payload, <<"dialed">>), Event),
    %% TODO: Handle no user
    amqp_util:kapps_publish(?USER_EVENT(Payload, <<"dialed">>), Event).
