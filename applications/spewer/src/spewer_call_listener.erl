%%%-------------------------------------------------------------------
%%% @copyright (C) 2016
%%% @doc
%%% @end
%%% @contributors
%%%   Max Lay
%%%-------------------------------------------------------------------
-module(spewer_call_listener).

-behaviour(gen_listener).

-export([start_link/1]).
-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,handle_event/2
        ,terminate/2
        ,code_change/3
        ]).
-export([handle_call_event/2
        ,handle_spewer_event/2
        ]).

-include("spewer.hrl").

-record(state, {call :: kapps_call:call()
               ,account_id :: ne_binary()
               ,account_db :: ne_binary()
               ,caller_call_id :: ne_binary()
               ,caller_user_id :: ne_binary()
               ,caller_device_id :: ne_binary()
               ,callflow_id :: ne_binary()
               ,callflow_module :: ne_binary()
               %% TODO: Fix step
               ,called_legs :: map()
               }).
-type state() :: #state{}.

%% By convention, we put the options here in macros, but not required.
-define(BINDINGS(CallID), [{'call', [{'callid', CallID}]}
                          ,{'spewer_message', [{'callid', CallID}]}
                          ,{'self', []}
                          ]).
-define(RESPONDERS, [{{?MODULE, 'handle_call_event'}
                     ,[{<<"call_event">>, <<"*">>}]
                     }
                    ,{{?MODULE, 'handle_spewer_event'}
                     ,[{<<"spewer_message">>, <<"*">>}]
                     }
                    ]).
-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).

%%--------------------------------------------------------------------
%% @doc
%% Starts the listener and binds to the call channel destroy events
%% @end
%%--------------------------------------------------------------------
-spec start_link(kapps_call:call()) -> startlink_ret().
start_link(Call) ->
    CallId = kapps_call:call_id(Call),
    gen_listener:start_link(?MODULE, [{'bindings', ?BINDINGS(CallId)}
                                     ,{'responders', ?RESPONDERS}
                                     ,{'queue_name', ?QUEUE_NAME}
                                     ,{'queue_options', ?QUEUE_OPTIONS}
                                     ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], [Call]).

%%--------------------------------------------------------------------
%% @doc
%% Handles call events (typically triggerred by a freeswitch event)
%% @end
%%--------------------------------------------------------------------
-spec handle_call_event(kz_json:object(), kz_proplist()) -> any().
handle_call_event(JObj, Props) ->
    {<<"call_event">>, Event} = kz_util:get_event_type(JObj),
    gen_listener:cast(props:get_value('server', Props), {'call', Event, JObj}).

-spec handle_spewer_event(kz_json:object(), kz_proplist()) -> any().
handle_spewer_event(JObj, Props) ->
    {<<"spewer_message">>, Event} = kz_util:get_event_type(JObj),
    gen_listener:cast(props:get_value('server', Props), {'spewer', Event, JObj}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the listener, and sends the init hook
%%--------------------------------------------------------------------
-spec init([kapps_call:call()]) -> {'ok', state()}.
init([Call]) ->
    lager:debug("started spewer call listener"),
    DeviceId = case kapps_call:authorizing_type(Call) of
                     <<"device">> -> kapps_call:authorizing_id(Call);
                     _ -> 'undefined'
               end,
    {'ok', #state{call=Call
                 ,account_id=kapps_call:account_id(Call)
                 ,account_db=kapps_call:account_db(Call)
                 ,caller_call_id=kapps_call:call_id(Call)
                 ,caller_user_id=kapps_call:owner_id(Call)
                 ,caller_device_id=DeviceId
                 ,called_legs=#{}
                 }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handle call messages
%% @end
%%--------------------------------------------------------------------
-spec handle_call(any(), any(), state()) ->
                         {'reply', {'error', 'not_implemented'}, state()}.
handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_implemented'}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handle cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(any(), state()) -> {'noreply', state()} |
                                     {'stop', 'normal', state()}.

handle_cast({'spewer', <<"executing_callflow_element">>, JObj}, #state{}=State) ->
    <<"cf_", Element/binary>> = kz_json:get_binary_value(<<"Module">>, JObj),
    Msg = [{<<"Module">>, Element}
          ,{<<"Module-Data">>, kz_json:get_value(<<"Module-Data">>, JObj)}
          | build_generic_proplist(State)],
    kapi_spewer:publish_executing_callflow_element(Msg),
    {'noreply', State#state{callflow_module=Element}};

handle_cast({'spewer', <<"entered_callflow">>, JObj}, #state{account_db=AccountDB}=State) ->
    CallflowId = kz_json:get_binary_value(<<"Callflow-ID">>, JObj),
    {'ok', CallflowData} = kz_datamgr:open_cache_doc(AccountDB, CallflowId),
    NewState = State#state{callflow_id=CallflowId},
    Msg = [{<<"Callflow-Data">>, kz_json:public_fields(CallflowData)}
          | build_generic_proplist(NewState)],
    kapi_spewer:publish_entered_callflow(Msg),
    {'noreply', NewState};

%%handle_cast({'call', <<"DTMF">>, JObj}, #state{}=State) ->
%%    _DTMF = kz_json:get_value(<<"DTMF-Digit">>, JObj),
%%    %% Props = build_generic_proplist(State),
%%    %% kapi_callflow_event:publish_calling_endpoint(Props),
%%    {'noreply', State};

handle_cast({'call', <<"LEG_CREATED">>, JObj}, #state{account_id=AccountId, called_legs=Legs}=State) ->
    %% Needs to handle: same account. different account. offnet
    %% Need to check this for delayed ring group
    lager:debug("LEG CREATED ~p", [kz_json:encode(JObj)]),
    OtherCallId = kz_call_event:other_leg_call_id(JObj),
    case build_other_leg_proplist(AccountId, JObj, State) of
        'undefined' -> 'ok';
        Msg -> kapi_spewer:publish_calling(Msg)
    end,
    {'noreply', State#state{called_legs=Legs#{OtherCallId => JObj}}};

handle_cast({'call', <<"CHANNEL_BRIDGE">>, JObj}, #state{account_id=AccountId, called_legs=Legs}=State) ->
    %% Find the leg created event
    OtherCallId = kz_call_event:other_leg_call_id(JObj),
    case maps:find(OtherCallId, Legs) of
        {'ok', LegCreatedJObj} ->
            case build_other_leg_proplist(AccountId, LegCreatedJObj, State) of
                'undefined' -> 'ok';
                Msg -> kapi_spewer:publish_answered(Msg)
            end;
        _ ->
            lager:error("Bridge to a leg we haven't seen ~p", [JObj])
    end,
    {'noreply', State};

handle_cast({'call', <<"CHANNEL_DESTROY">>, JObj}, #state{account_id=AccountId, called_legs=Legs}=State) ->
    OtherCallId = kz_call_event:other_leg_call_id(JObj),
    case maps:find(OtherCallId, Legs) of
        {'ok', LegCreatedJObj} ->
            case build_other_leg_proplist(AccountId, LegCreatedJObj, State) of
                'undefined' -> 'ok';
                %% Should be hangup - just a test
                Msg -> kapi_spewer:publish_answered(Msg)
            end;
        _ ->
            lager:error("Bridge to a leg we haven't seen ~p", [JObj])
    end,
    %%case {kz_json:get_value(<<"Hangup-Cause">>, JObj), kz_json:get_value(<<"Disposition">>, JObj)} of
    %%    {<<"ORIGINATOR_CANCEL">>, _} -> kapi_callflow_event:publish_cancel(Props);
    %%    {_, <<"NO_ANSWER">>} -> kapi_callflow_event:publish_no_answer(Props);
    %%    _ -> kapi_callflow_event:publish_hangup(Props)
    %%end,
    {'stop', 'normal', State};

handle_cast(_Msg, State) ->
    lager:error("unhandled cast: ~p", [_Msg]),
    {'noreply', State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_info(any(), state()) -> {'noreply', state()}.
handle_info(Info, State) ->
    lager:debug("unhandled message: ~p", [Info]),
    {'noreply', State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Allows listener to pass options to handlers
%% @end
%%--------------------------------------------------------------------
-spec handle_event(kz_json:object(), state()) -> {'reply', []}.
handle_event(_JObj, _State) ->
    {'reply', []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, _State) ->
    lager:debug("spewer call listener terminating: ~p", [_Reason]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec build_generic_proplist(state()) -> kz_proplist().
build_generic_proplist(#state{account_id=AccountId
                             ,caller_call_id=CallerCallId
                             ,caller_user_id=CallerUserId
                             ,caller_device_id=CallerDeviceId
                             ,callflow_id=CallflowId}) ->
    %% Maybe remove undefined?
    props:filter_undefined([{<<"Account-ID">>, AccountId}
                           ,{<<"Callflow-ID">>, CallflowId}
                           ,{<<"Caller-Call-ID">>, CallerCallId}
                           ,{<<"Caller-User-ID">>, CallerUserId}
                           ,{<<"Caller-Device-ID">>, CallerDeviceId}
                            | kz_api:default_headers(?APP_NAME, ?APP_VERSION)]).

build_other_leg_proplist(AccountId, JObj, State) ->
    OtherUserId = kz_call_event:owner_id(JObj),
    OtherCallId = kz_call_event:other_leg_call_id(JObj),
    OtherDeviceId = case kz_call_event:authorizing_type(JObj) of
                          <<"device">> -> kz_call_event:authorizing_id(JObj);
                          _ -> 'undefined'
                    end,
    %% Check that this actually is what we want
    case kz_call_event:account_id(JObj) of
        AccountId ->
            [{<<"Type">>, <<"internal">>}
            ,{<<"Callee-User-ID">>, OtherUserId}
            ,{<<"Callee-Device-ID">>, OtherDeviceId}
            ,{<<"Callee-Call-ID">>, OtherCallId}
            | build_generic_proplist(State)];
        'undefined' ->
             lager:debug("offnet?"),
             'undefined';
        OtherAccount ->
             lager:debug("other account ~p", [OtherAccount]),
             'undefined'
    end.
