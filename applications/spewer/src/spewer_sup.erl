%%%-------------------------------------------------------------------
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   Max Lay
%%%-------------------------------------------------------------------
-module(spewer_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-include("spewer.hrl").

-define(SERVER, ?MODULE).

-define(CHILDREN, [?WORKER('spewer_listener')]).

%% ===================================================================
%% API functions
%% ===================================================================

-spec start_link() -> startlink_ret().
start_link() ->
    supervisor:start_link({'local', ?SERVER}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================
-spec init(any()) -> sup_init_ret().
init([]) ->
    kz_util:set_startup(),

    RestartStrategy = 'one_for_one',
    MaxRestarts = 5,
    MaxSecondsBetweenRestarts = 5,

    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},

    {'ok', {SupFlags, ?CHILDREN}}.
