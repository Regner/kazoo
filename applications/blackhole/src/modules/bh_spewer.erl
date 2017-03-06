%%%-------------------------------------------------------------------
%%% @doc
%%%
%%% @end
%%% @contributors
%%% Max Lay
%%%-------------------------------------------------------------------
-module(bh_spewer).

-export([init/0
        ,validate/2
        ,bindings/2
        ]).

-include("blackhole.hrl").

-define(ENTITIES, [<<"user">>, <<"device">>, <<"callflow">>]).

-spec init() -> any().
init() ->
    _ = blackhole_bindings:bind(<<"blackhole.events.validate.spewer">>, ?MODULE, 'validate'),
    blackhole_bindings:bind(<<"blackhole.events.bindings.spewer">>, ?MODULE, 'bindings').

-spec validate(bh_context:context(), map()) -> bh_context:context().
validate(Context, #{keys := [Entity, _EntityId, _Event]=Keys}) ->
    %% TODO: Check event
    case lists:member(Entity, [<<"*">> | ?ENTITIES]) of
        'true' -> Context;
        'false' -> invalid_keys(Context, Keys)
    end;
validate(Context, #{keys := Keys}) ->
    invalid_keys(Context, Keys).

invalid_keys(Context, Keys) ->
    bh_context:add_error(Context, <<"invalid format for spewer subscription : ", (kz_binary:join(Keys))/binary>>).

-spec bindings(bh_context:context(), map()) -> map().
bindings(_Context, #{account_id := AccountId
                    ,keys := [Entity, EntityId, Event]
                    }=Map) ->
    Requested = <<"spewer.", Entity/binary, ".", EntityId/binary, ".", Event/binary>>,
    Subscribed = [<<"spewer.", AccountId/binary, ".", Entity/binary, ".", EntityId/binary, ".", Event/binary>>],
    Listeners = [{'amqp', 'spewer', skel_bind_options(AccountId, Entity, EntityId, Event)}],
    Map#{requested => Requested
        ,subscribed => Subscribed
        ,listeners => Listeners
        }.

-spec skel_bind_options(ne_binary(), ne_binary(), ne_binary(), ne_binary()) -> gen_listener:bindings().
skel_bind_options(AccountId, Entity, EntityId, _Event) ->
    [{'account_id', AccountId}
    ,{'entities', [{Entity, EntityId}]}
    ].
