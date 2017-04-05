%%%-------------------------------------------------------------------
%%% @copyright (C) 2013-2017, 2600Hz INC
%%% @doc
%%%
%%% @end
%%% @contributors

%%%-------------------------------------------------------------------
-module('cb_presence').

-export([init/0
        ,authenticate/1
        ,authorize/1
        ,allowed_methods/0, allowed_methods/1
        ,resource_exists/0, resource_exists/1
        ,content_types_provided/2
        ,validate/1, validate/2
        ,post/1, post/2
        ]).

-include("crossbar.hrl").

-define(MOD_CONFIG_CAT, <<(?CONFIG_CAT)/binary, ".presence">>).

-define(PRESENTITY_KEY, <<"include_presentity">>).
-define(PRESENTITY_CFG_KEY, <<"query_include_presentity">>).

-define(PRESENCE_QUERY_TIMEOUT_KEY, <<"query_presence_timeout">>).
-define(PRESENCE_QUERY_DEFAULT_TIMEOUT, 5000).
-define(PRESENCE_QUERY_TIMEOUT, kapps_config:get_integer(?MOD_CONFIG_CAT
                                                        ,?PRESENCE_QUERY_TIMEOUT_KEY
                                                        ,?PRESENCE_QUERY_DEFAULT_TIMEOUT
                                                        )
       ).
-define(REPORT_CONTENT_TYPE, [{'send_file', [{<<"application">>, <<"json">>}]}]).
-define(REPORT_PREFIX, "report-").
-define(MATCH_REPORT_PREFIX(ReportId), <<?REPORT_PREFIX, ReportId/binary>>).
-define(MATCH_REPORT_PREFIX, <<?REPORT_PREFIX, _ReportId/binary>>).

-define(MANUAL_PRESENCE_DOC, <<"manual_presence">>).

-define(CONFIRMED, <<"confirmed">>).
-define(EARLY, <<"early">>).
-define(TERMINATED, <<"terminated">>).
-define(PRESENCE_STATES, [?CONFIRMED, ?EARLY, ?TERMINATED]).

-type search_result() :: {'ok', kz_json:object()} | {'error', any()}.

%%%===================================================================
%%% API
%%%===================================================================

-spec init() -> ok.
init() ->
    Bindings = [{<<"*.allowed_methods.presence">>, 'allowed_methods'}
               ,{<<"*.authenticate">>, 'authenticate'}
               ,{<<"*.authorize">>, 'authorize'}
               ,{<<"*.resource_exists.presence">>, 'resource_exists'}
               ,{<<"*.content_types_provided.presence">>, 'content_types_provided'}
               ,{<<"*.validate.presence">>, 'validate'}
               ,{<<"*.execute.post.presence">>, 'post'}
               ],
    _ = cb_modules_util:bind(?MODULE, Bindings),
    ok.

-spec authenticate(cb_context:context()) -> boolean().
authenticate(Context) ->
    authenticate(Context, cb_context:req_nouns(Context), cb_context:req_verb(Context)).

-spec authenticate(cb_context:context(), req_nouns(), http_method()) -> boolean().
authenticate(Context, [{<<"presence">>,[?MATCH_REPORT_PREFIX]}], ?HTTP_GET) ->
    cb_context:magic_pathed(Context);
authenticate(_Context, _Nouns, _Verb) -> 'false'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec authorize(cb_context:context()) -> boolean().
authorize(Context) ->
    authorize(Context, cb_context:req_nouns(Context), cb_context:req_verb(Context)).

-spec authorize(cb_context:context(), req_nouns(), http_method()) -> boolean().
authorize(Context, [{<<"presence">>,[?MATCH_REPORT_PREFIX]}], ?HTTP_GET) ->
    cb_context:magic_pathed(Context);
authorize(_Context, _Nouns, _Verb) -> 'false'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines the verbs that are appropriate for the
%% given Nouns.  IE: '/accounts/' can only accept GET and PUT
%%
%% Failure here returns 405
%% @end
%%--------------------------------------------------------------------
-spec allowed_methods() -> http_methods().
-spec allowed_methods(path_token()) -> http_methods().
allowed_methods() ->
    [?HTTP_GET, ?HTTP_POST].
allowed_methods(?MATCH_REPORT_PREFIX) -> [?HTTP_GET];
allowed_methods(?CONFIRMED) -> [?HTTP_POST];
allowed_methods(?EARLY) -> [?HTTP_POST];
allowed_methods(?TERMINATED) -> [?HTTP_POST];
allowed_methods(_Extension) ->
    [?HTTP_GET, ?HTTP_POST].

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the provided list of Nouns are valid.
%%
%% Failure here returns 404
%% @end
%%--------------------------------------------------------------------
-spec resource_exists() -> 'true'.
-spec resource_exists(path_token()) -> 'true'.
resource_exists() -> 'true'.
resource_exists(_Extension) -> 'true'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function allows report to be downloaded.
%%
%% @end
%%--------------------------------------------------------------------
-spec content_types_provided(cb_context:context(), path_token()) -> cb_context:context().
content_types_provided(Context, ?MATCH_REPORT_PREFIX(Report)) ->
    content_types_provided_for_report(Context, Report);
content_types_provided(Context, _) -> Context.

-spec content_types_provided_for_report(cb_context:context(), ne_binary()) -> cb_context:context().
content_types_provided_for_report(Context, Report) ->
    File = <<"/tmp/", Report/binary, ".json">>,
    case filelib:is_file(File) of
        'false' -> Context;
        'true' -> cb_context:set_content_types_provided(Context, ?REPORT_CONTENT_TYPE)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the parameters and content are correct
%% for this request
%%
%% Failure here returns 400
%% @end
%%--------------------------------------------------------------------
-spec validate(cb_context:context()) ->
                      cb_context:context().
-spec validate(cb_context:context(), path_token()) ->
                      cb_context:context().
validate(Context) ->
    validate_thing(Context, cb_context:req_verb(Context)).

validate(Context, ?MATCH_REPORT_PREFIX(Report)) ->
    load_report(Context, Report);
validate(Context, StateOrExtension) ->
    case lists:member(StateOrExtension, ?PRESENCE_STATES) of
        'true' -> validate_presence_thing(Context, fun(C) -> C end);
        'false' -> search_detail(Context, StateOrExtension)
    end.

-spec validate_thing(cb_context:context(), http_method()) ->
                            cb_context:context().
validate_thing(Context, ?HTTP_GET) ->
    search_summary(Context);
validate_thing(Context, ?HTTP_POST) ->
    validate_presence_thing(Context, fun validate_is_reset_request/1).

-spec search_summary(cb_context:context()) -> cb_context:context().
search_summary(Context) ->
    search_result(Context, search_req(Context, <<"summary">>)).

-spec search_detail(cb_context:context(), ne_binary()) -> cb_context:context().
search_detail(Context, Extension) ->
    search_result(Context, search_req(Context, <<"detail">>, Extension)).

-spec search_result(cb_context:context(), search_result()) -> cb_context:context().
search_result(Context, {'ok', JObj}) ->
    Routines = [{fun cb_context:set_resp_data/2, JObj}
               ,{fun cb_context:set_resp_status/2, 'success'}
               ],
    cb_context:setters(Context, Routines);
search_result(Context, {'error', Error}) ->
    cb_context:add_system_error(Error, Context).

-spec search_req(cb_context:context(), ne_binary()) -> search_result().
search_req(Context, SearchType) ->
    search_req(Context, SearchType, 'undefined').

-spec search_req(cb_context:context(), ne_binary(), api_binary()) -> search_result().
search_req(Context, SearchType, Username) ->
    Req = [{<<"Realm">>, cb_context:account_realm(Context)}
          ,{<<"Username">>, Username}
          ,{<<"Search-Type">>, SearchType}
          ,{<<"Event-Package">>, cb_context:req_param(Context, <<"event">>)}
          ,{<<"System-Log-ID">>, cb_context:req_id(Context)}
          ,{<<"Msg-ID">>, kz_binary:rand_hex(16)}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
          ],
    Count = kz_nodes:whapp_count(<<"kamailio">>, 'true'),
    lager:debug("requesting presence ~s from ~B servers", [SearchType, Count]),
    case kz_amqp_worker:call_collect(Req
                                    ,fun kapi_presence:publish_search_req/1
                                    ,{fun collect_results/2, {0, Count}}
                                    )
    of
        {'error', _R}=Err -> Err;
        {'ok', JObjs} -> process_responses(JObjs, SearchType, 'null');
        {'timeout', JObjs} -> process_responses(JObjs, SearchType, 'true')
    end.

-type collect_params() :: {integer(), integer()}.
-type collect_result() :: 'true' | {'false', collect_params()}.

-spec collect_results(kz_json:objects(), collect_params()) -> collect_result().
collect_results([Response | _], {Count, Max}) ->
    case Count + search_resp_value(kz_api:event_name(Response)) of
        Max -> 'true';
        V -> {'false', {V, Max}}
    end.

-spec search_resp_value(ne_binary()) -> 0..1.
search_resp_value(<<"search_resp">>) -> 1;
search_resp_value(_) -> 0.

-type acc_function() :: fun((kz_json:object(), kz_json:object()) -> kz_json:object()).

-spec accumulator_fun(ne_binary()) -> acc_function().
accumulator_fun(<<"summary">>) -> fun kz_json:sum/2;
accumulator_fun(<<"detail">>) -> fun kz_json:merge_recursive/2.

-spec process_responses(kz_json:objects(), ne_binary(), atom()) -> {'ok', kz_json:object()}.
process_responses(JObjs, SearchType, Timeout) ->
    Fun = accumulator_fun(SearchType),
    Subscriptions = extract_subscriptions(JObjs, Fun),
    {'ok', kz_json:set_value(<<"timeout">>, Timeout, Subscriptions)}.


-spec extract_subscriptions(kz_json:objects(), acc_function()) -> kz_json:object().
extract_subscriptions(JObjs, Fun) ->
    lists:foldl(fun(JObj, Acc) -> Fun(kz_api:remove_defaults(JObj), Acc) end, kz_json:new(), JObjs).

-type on_success_fun() :: fun((cb_context:context()) -> cb_context:context()).

-spec validate_presence_thing(cb_context:context(), on_success_fun()) -> cb_context:context().
validate_presence_thing(Context, OnSuccess) ->
    validate_presence_thing(Context, OnSuccess, cb_context:req_nouns(Context)).
validate_presence_thing(Context, OnSuccess, [{<<"presence">>, _}
                                            ,{<<"devices">>, [DeviceId]}
                                            ,{<<"accounts">>, [_AccountId]}
                                            ]) ->
    execute_on_success(load_device(Context, DeviceId), OnSuccess);
validate_presence_thing(Context, OnSuccess, [{<<"presence">>, _}
                                            ,{<<"users">>, [UserId]}
                                            ,{<<"accounts">>, [_AccountId]}
                                            ]) ->
    execute_on_success(load_presence_for_user(Context, UserId), OnSuccess);
validate_presence_thing(Context, _OnSuccess, _ReqNouns) ->
    crossbar_util:response_faulty_request(Context).

-spec execute_on_success(cb_context:context(), on_success_fun()) -> cb_context:context().
execute_on_success(Context, OnSuccess) ->
    case cb_context:resp_status(Context) of
        'success' -> OnSuccess(Context);
        _ -> Context
    end.

-spec load_device(cb_context:context(), ne_binary()) -> cb_context:context().
load_device(Context, ThingId) ->
    %% validating device
    crossbar_doc:load(ThingId, Context, ?TYPE_CHECK_OPTION(kz_device:type())).

-spec load_presence_for_user(cb_context:context(), ne_binary()) -> cb_context:context().
load_presence_for_user(Context, UserId) ->
    %% load the user_doc if it has a presence_id set, otherwise load all the user's devices
    Context1 = crossbar_doc:load(UserId, Context, ?TYPE_CHECK_OPTION(kzd_user:type())),
    execute_on_success(Context1, fun maybe_load_user_devices/1).

-spec maybe_load_user_devices(cb_context:context()) -> cb_context:context().
maybe_load_user_devices(Context) ->
    User = cb_context:doc(Context),
    case kzd_user:presence_id(User) of
        'undefined' -> load_user_devices(Context);
        _PresenceId -> Context
    end.

-spec load_user_devices(cb_context:context()) -> cb_context:context().
load_user_devices(Context) ->
    User = cb_context:doc(Context),
    Devices = kzd_user:devices(User),
    cb_context:set_doc(Context, Devices).

-spec validate_is_reset_request(cb_context:context()) -> cb_context:context().
validate_is_reset_request(Context) ->
    case kz_term:is_true(cb_context:req_value(Context, <<"reset">>)) of
        'true' -> Context;
        'false' -> reset_validation_error(Context)
    end.

-spec reset_validation_error(cb_context:context()) -> cb_context:context().
reset_validation_error(Context) ->
    cb_context:add_validation_error(<<"reset">>
                                   ,<<"required">>
                                   ,kz_json:from_list(
                                      [{<<"message">>, <<"Field must be set to true">>}
                                      ,{<<"target">>, <<"required">>}
                                      ]
                                     )
                                   ,Context
                                   ).

-spec post(cb_context:context()) -> cb_context:context().
post(Context) ->
    Things = cb_context:doc(Context),
    _ = collect_report(Context, Things),
    send_command(Context, fun publish_presence_reset/2, Things).

-spec post(cb_context:context(), ne_binary()) -> cb_context:context().
post(Context, StateOrExtension) ->
    case lists:member(StateOrExtension, ?PRESENCE_STATES) of
        'true' -> post_presence_state(Context, StateOrExtension);
        'false' -> post_extension(Context, StateOrExtension)
    end.

-spec post_presence_state(cb_context:context(), ne_binary()) -> cb_context:context().
post_presence_state(Context, State) ->
    Things = cb_context:doc(Context),
    send_command(Context, fun(C, Id) -> publish_presence_update(C, Id, State) end, Things).

-spec post_extension(cb_context:context(), ne_binary()) -> cb_context:context().
post_extension(Context, Extension) ->
    _ = collect_report(Context, Extension),
    publish_presence_reset(Context, Extension),
    crossbar_util:response_202(<<"reset command sent for extension ", Extension/binary>>, Context).

-type presence_command_fun() :: fun((cb_context:context(), api_binary()) -> any()).

-spec send_command(cb_context:context(), presence_command_fun(), kz_json:object() | kz_json:objects()) ->
                          cb_context:context().
send_command(Context, _CommandFun, []) ->
    lager:debug("nothing to send command to"),
    crossbar_util:response(<<"nothing to send command to">>, Context);
send_command(Context, CommandFun, [_|_]=Things) ->
    lists:foreach(fun(Thing) -> CommandFun(Context, find_presence_id(Thing)) end, Things),
    crossbar_util:response_202(<<"command sent">>, Context);
send_command(Context, CommandFun, Thing) ->
    send_command(Context, CommandFun, [Thing]).

-spec publish_presence_reset(cb_context:context(), api_binary()) -> 'ok'.
publish_presence_reset(_Context, 'undefined') -> 'ok';
publish_presence_reset(Context, PresenceId) ->
    Realm = cb_context:account_realm(Context),
    lager:debug("resetting ~s@~s", [PresenceId, Realm]),
    API = [{<<"Realm">>, Realm}
          ,{<<"Username">>, PresenceId}
          ,{<<"Msg-ID">>, kz_util:get_callid()}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
          ],
    kz_amqp_worker:cast(API, fun kapi_presence:publish_reset/1).

-spec publish_presence_update(cb_context:context(), api_binary(), ne_binary()) -> 'ok'.
publish_presence_update(_Context, 'undefined', _PresenceState) -> 'ok';
publish_presence_update(Context, PresenceId, PresenceState) ->
    Realm = cb_context:account_realm(Context),
    AccountDb = cb_context:account_db(Context),
    lager:debug("updating presence for ~s@~s to state ~s", [PresenceId, Realm, PresenceState]),
    %% persist presence setting
    {'ok', _} = kz_datamgr:update_doc(AccountDb, ?MANUAL_PRESENCE_DOC, [{PresenceId, PresenceState}]),
    PresenceString = <<PresenceId/binary, "@", Realm/binary>>,
    API = [{<<"Presence-ID">>, PresenceString}
          ,{<<"Call-ID">>, kz_term:to_hex_binary(crypto:hash('md5', PresenceString))}
          ,{<<"State">>, PresenceState}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
          ],
    kz_amqp_worker:cast(API, fun kapi_presence:publish_update/1).

-spec find_presence_id(kz_json:object()) -> api_binary().
find_presence_id(JObj) ->
    case kz_device:is_device(JObj) of
        'true' -> kz_device:presence_id(JObj);
        'false' -> kzd_user:presence_id(JObj)
    end.

-spec load_report(cb_context:context(), path_token()) -> cb_context:context().
load_report(Context, Report) ->
    File = <<"/tmp/", Report/binary, ".json">>,
    case filelib:is_file(File) of
        'true' -> set_report(Context, File);
        'false' ->
            lager:error("invalid file while fetching report file ~s", [File]),
            cb_context:add_system_error('bad_identifier', kz_json:from_list([{<<"cause">>, Report}]), Context)
    end.

-spec set_report(cb_context:context(), ne_binary()) -> cb_context:context().
set_report(Context, File) ->
    Name = kz_term:to_binary(filename:basename(File)),
    Headers = [{<<"Content-Disposition">>, <<"attachment; filename=", Name/binary>>}],
    cb_context:setters(Context,
                       [{fun cb_context:set_resp_file/2, File}
                       ,{fun cb_context:set_resp_etag/2, 'undefined'}
                       ,{fun cb_context:add_resp_headers/2, Headers}
                       ,{fun cb_context:set_resp_status/2, 'success'}
                       ]
                      ).

-spec collect_report(cb_context:context(), ne_binary() | kz_json:object() | kz_json:objects()) -> any().
collect_report(_Context, []) ->
    lager:debug("nothing to collect");
collect_report(Context, Param) ->
    lager:debug("collecting report for ~s", [Param]),
    kz_util:spawn(fun send_report/2, [search_detail(Context, Param), Param]).

-spec send_report(cb_context:context(), ne_binary() | kz_json:object() | kz_json:objects()) -> 'ok'.
send_report(Context, Extension)
  when is_binary(Extension) ->
    Msg = <<"presence reset received for extension ", Extension/binary>>,
    format_and_send_report(Context, Msg);
send_report(Context, Things)
  when is_list(Things) ->
    Format = "presence reset received for user_id ~s~n~ndevices:~p",
    Ids = list_to_binary([io_lib:format("~n~s", [kz_doc:id(Thing)])  || Thing <- Things]),
    Msg = io_lib:format(Format, [cb_context:user_id(Context), Ids]),
    format_and_send_report(Context, Msg);
send_report(Context, Thing) ->
    Format = "presence reset received for ~s : ~s",
    Msg = io_lib:format(Format, [kz_doc:type(Thing), kz_doc:id(Thing)]),
    format_and_send_report(Context, Msg).

-spec format_and_send_report(cb_context:context(), iodata()) -> 'ok'.
format_and_send_report(Context, Msg) ->
    lager:debug("formatting and sending report"),
    {ReportId, URL} = save_report(Context),
    Subject = io_lib:format("presence reset for account ~s", [cb_context:account_id(Context)]),
    Props = [{<<"Report-ID">>, ReportId}
            ,{<<"Node">>, node()}
            ],
    Headers = [{<<"Attachment-URL">>, URL}
              ,{<<"Account-ID">>, cb_context:account_id(Context)}
              ,{<<"Request-ID">>, cb_context:req_id(Context)}
              ],
    kz_notify:detailed_alert(Subject, Msg, Props, Headers).

-spec save_report(cb_context:context()) -> {ne_binary(), ne_binary()}.
save_report(Context) ->
    JObj = kz_json:encode(cb_context:resp_data(Context)),
    Report = kz_binary:rand_hex(16),
    File = <<"/tmp/", Report/binary, ".json">>,
    'ok' = file:write_file(File, JObj),
    Args = [cb_context:api_version(Context)
           ,cb_context:account_id(Context)
           ,?MATCH_REPORT_PREFIX(Report)
           ],
    Path = io_lib:format("/~s/accounts/~s/presence/~s", Args),
    MagicPath = kapps_util:to_magic_hash(Path),
    HostURL = cb_context:host_url(Context),
    URL = <<HostURL/binary, "/", MagicPath/binary>>,
    {Report, URL}.
