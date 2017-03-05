%%%-------------------------------------------------------------------
%%% @copyright (C) 2016
%%% @doc
%%% @end
%%% @contributors
%%%   Max Lay
%%%-------------------------------------------------------------------
-module(callflow_event_listener).

-behaviour(gen_listener).

-export([start_link/1
        ,handle_call_event/2
        ,set_pid/2, get_pid/1
        ]).
-export([route_win/2
        ,executing_element/3
        ,branch/2
        ]).
-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,handle_event/2
        ,terminate/2
        ,code_change/3
        ]).

-include("callflow.hrl").

-record(state, {call :: kapps_call:call()
               ,callflow_id :: ne_binary()
               ,callflow_element :: ne_binary()
               ,flow :: kz_json:object()
               }).
-type state() :: #state{}.

%% By convention, we put the options here in macros, but not required.
-define(BINDINGS(CallID), [{'call', [{'callid', CallID}
                                    %%,{'restrict_to',
                                    %%  [<<"CHANNEL_DESTROY">>
                                    %%  ,<<"CHANNEL_TRANSFEREE">>
                                    %%  ,<<"CHANNEL_TRANSFEROR">>
                                    %%  ]}
                                    ]}
                          ,{'self', []}
                          ]).
-define(RESPONDERS, [{{?MODULE, 'handle_call_event'}
                     ,[{<<"*">>, <<"*">>}]
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
    gen_listener:start_link(?MODULE, [{'bindings', ?BINDINGS(kapps_call:call_id(Call))}
                                     ,{'responders', ?RESPONDERS}
                                     ,{'queue_name', ?QUEUE_NAME}       % optional to include
                                     ,{'queue_options', ?QUEUE_OPTIONS} % optional to include
                                     ,{'consume_options', ?CONSUME_OPTIONS} % optional to include
                                     ], [Call]).

%%--------------------------------------------------------------------
%% @doc
%% Handles call events (typically triggerred by a freeswitch event)
%% @end
%%--------------------------------------------------------------------
-spec handle_call_event(kz_json:object(), kz_proplist()) -> any().
handle_call_event(JObj, Props) ->
    case kz_util:get_event_type(JObj) of
        %{<<"call_event">>, <<"CHANNEL_ANSWER">>} ->
        %    gen_listener:cast(props:get_value('server', Props), {'answered', JObj});
        {<<"call_event">>, <<"CHANNEL_DESTROY">>} ->
            gen_listener:cast(props:get_value('server', Props), {'end_call', JObj});
        {<<"call_event">>, <<"LEG_CREATED">>} ->
            gen_listener:cast(props:get_value('server', Props), {'leg_created', JObj});
        {<<"call_event">>, <<"CHANNEL_BRIDGE">>} ->
            %% Pretty sure this is always answered
            gen_listener:cast(props:get_value('server', Props), {'bridged', JObj});
        {<<"call_event">>, <<"DTMF">>} ->
            gen_listener:cast(props:get_value('server', Props), {'dtmf', JObj});
        {<<"call_event">>, <<"RECORD_START">>} ->
            %% Call is being recorded. Voicemail or call recording? Can figure out from state
            'ok';
        {<<"call_event">>, <<"RECORD_STOP">>} ->
            'ok';
        {<<"call_event">>, <<"CHANNEL_TRANSFEREE">>} ->
            lager:debug("transferee"),
            gen_listener:cast(props:get_value('server', Props), {'transfer', JObj});
        {<<"call_event">>, <<"CHANNEL_TRANSFEROR">>} ->
            lager:debug("transferee"),
            gen_listener:cast(props:get_value('server', Props), {'transfer', JObj});
        {Name, Event} ->
            lager:error("ignore event ~p ~p ~p", [Name, Event, kz_json:encode(JObj)])
    end.

-spec get_pid(kapps_call:call()) -> pid().
get_pid(Call) ->
    kapps_call:kvs_fetch('callflow_event_listener_pid', Call).

-spec set_pid(kapps_call:call(), pid()) -> kapps_call:call().
set_pid(Call, Pid) ->
    kapps_call:kvs_store('callflow_event_listener_pid', Pid, Call).

-spec route_win(kapps_call:call(), kz_json:object()) -> any().
route_win(Call, Callflow) ->
    gen_listener:cast(get_pid(Call), {'route_win', Call, Callflow}).

-spec executing_element(kapps_call:call(), kz_json:object(), ne_binary()) -> any().
executing_element(Call, Flow, CfModule) ->
    gen_listener:cast(get_pid(Call), {'executing_element', Call, Flow, CfModule}).

-spec branch(kapps_call:call(), kz_json:object()) -> any().
branch(Call, BranchedCallflow) ->
    gen_listener:cast(get_pid(Call), {'branch', Call, BranchedCallflow}).

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
    gen_listener:cast(self(), {'init'}),
    lager:debug("started callflow event listener"),
    CallflowId = kapps_call:kvs_fetch('cf_flow_id', Call),
    {'ok', #state{call=Call, callflow_id=CallflowId}}.

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
handle_cast({'init'}, #state{call=_Call}=State) ->
    {'noreply', State};

handle_cast({'executing_element', Call, Flow, Module}, #state{}=State) ->
    <<"cf", Element/binary>> = kz_term:to_binary(Module),
    NewState = State#state{callflow_element=Element, call=Call, flow=Flow},
    %% Could use new state to build proplist?
    %% Req = build_generic_proplist(NewState),
    {'noreply', NewState};

handle_cast({'route_win', Call, Flow}, #state{}=State) ->
    NewState = State#state{call=Call, flow=Flow},
    Req = [{<<"Called-Number">>, kapps_call:request_user(Call)}
           | build_generic_proplist(NewState)
          ],
    kz_amqp_worker:cast(Req, fun kapi_callflow_event:publish_callflow_entered/1),
    {'noreply', NewState};

handle_cast({'bridged', _JObj}, #state{}=State) ->
    Req = build_generic_proplist(State),
    kz_amqp_worker:cast(Req, fun kapi_callflow_event:publish_answered/1),
    {'noreply', State};

handle_cast({'branch', Call, BranchedCallflow}, #state{callflow_id=CallflowId}=State) ->
    NewState = State#state{call=Call},
    BranchedCallflowId = kz_doc:id(BranchedCallflow),
    Req = [{<<"Branched-Callflow-ID">>, CallflowId}
           | build_generic_proplist(NewState)
          ],
    kz_amqp_worker:cast(Req, fun kapi_callflow_event:publish_callflow_entered/1),
    {'noreply', NewState#state{callflow_id=BranchedCallflowId}};

handle_cast({'end_call', JObj}, #state{}=State) ->
    Props = build_generic_proplist(State),
    case {kz_json:get_value(<<"Hangup-Cause">>, JObj), kz_json:get_value(<<"Disposition">>, JObj)} of
        {<<"ORIGINATOR_CANCEL">>, _} -> kapi_callflow_event:publish_cancel(Props);
        {_, <<"NO_ANSWER">>} -> kapi_callflow_event:publish_no_answer(Props);
        _ -> kapi_callflow_event:publish_hangup(Props)
    end,
    {'stop', 'normal', State};

handle_cast({'dtmf', JObj}, #state{}=State) ->
    _DTMF = kz_json:get_value(<<"DTMF-Digit">>, JObj),
    %% Props = build_generic_proplist(State),
    %% kapi_callflow_event:publish_calling_endpoint(Props),
    {'noreply', State};

handle_cast({'leg_created', _JObj}, #state{}=State) ->
    %% Props = build_generic_proplist(State),
    %% kapi_callflow_event:publish_calling_endpoint(Props),
    {'noreply', State};

handle_cast({'transfer', _JObj}, #state{}=State) ->
    Props = build_generic_proplist(State),
    kapi_callflow_event:publish_transferred(Props),
    {'noreply', State};

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
    lager:debug("callflow event listener terminating: ~p", [_Reason]).

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
build_generic_proplist(#state{call=Call}) ->
    AccountId = case kapps_call:account_id(Call) of
                    Id when is_list(Id) -> Id;
                    _ -> kapps_call:custom_channel_var(<<"Account-ID">>, Call)
                end,
    [{<<"Account-ID">>, AccountId}
    %% ,{<<"Callflow-ID">>, kapps_call:current_callflow_id(Call)}
    ,{<<"Call-ID">>, kapps_call:call_id(Call)}
    %% ,{<<"Group-ID">>, kapps_call:monster_group_id(Call)}
    ,{<<"Timestamp">>, get_timestamp()}
     | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
    ].

-spec get_timestamp() -> integer().
get_timestamp() ->
    {Mega, Sec, Micro} = os:timestamp(),
    (Mega*1000000 + Sec)*1000 + round(Micro/1000).
