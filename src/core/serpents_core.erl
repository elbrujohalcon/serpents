%%% @doc The core of the game
-module(serpents_core).
-author('elbrujohalcon@inaka.net').

-behavior(gen_fsm).

-type state() :: #{ game => serpents_games:game()
                  , dispatcher => pid()
                  }.

-export(
  [ register_player/1
  , create_game/0
  , create_game/1
  , join_game/2
  , start_game/1
  , turn/3
  , fetch_game/1
  , game_dispatcher/1
  ]).

-export([start_link/1]).
-export(
  [ created/3
  , created/2
  , started/2
  , init/1
  , handle_event/3
  , handle_sync_event/4
  , handle_info/3
  , terminate/3
  , code_change/4
  ]).

-type options() :: #{ rows => pos_integer()
                    , cols => pos_integer()
                    }.
-type row() :: pos_integer().
-type col() :: pos_integer().
-type position() :: {row(), col()}.
-type direction() :: left | right | up | down.
-export_type(
  [ options/0
  , position/0
  , direction/0
  ]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% EXPORTED FUNCTIONS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc Registers a new player
-spec register_player(serpents_players:name()) -> serpents_players:player().
register_player(Name) ->
  serpents_players_repo:register(Name).

%% @equiv create_game(#{}).
-spec create_game() -> serpents_games:game().
create_game() -> create_game(#{}).

%% @doc Creates a new game
-spec create_game(options()) -> serpents_games:game().
create_game(Options) ->
  Game = serpents_games_repo:create(Options),
  {ok, Pid} = serpents_game_sup:start_child(Game),
  serpents_games:process(Game, Pid).

%% @doc PlayerId joins GameId
-spec join_game(serpents_games:id(), serpents_players:id()) -> position().
join_game(GameId, PlayerId) ->
  call(GameId, {join, PlayerId}).

%% @doc Closes the joining period for the game and starts it
-spec start_game(serpents_games:id()) -> ok.
start_game(GameId) ->
  cast(GameId, start).

%% @doc a player changes direction
-spec turn(serpents_games:id(), serpents_players:id(), direction()) -> ok.
turn(GameId, PlayerId, Direction) ->
  cast(GameId, {turn, PlayerId, Direction}).

%% @doc Retrieves the status of a game
-spec fetch_game(serpents_games:id()) -> serpents_games:game().
fetch_game(GameId) ->
  call(GameId, fetch).

%% @doc Retrieves the pid for the event dispatcher associated with a game.
%%      It's a gen_event dispatcher.
-spec game_dispatcher(serpents_games:id()) -> pid().
game_dispatcher(GameId) ->
  call(GameId, dispatcher).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% PRIVATELY EXPORTED FUNCTIONS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec start_link(serpents_games:game()) -> {ok, pid()} | {error, term()}.
start_link(Game) ->
  Process = process_name(serpents_games:id(Game)),
  gen_fsm:start_link({local, Process}, ?MODULE, Game, []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% FSM CALLBACKS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec init(serpents_games:game()) -> {ok, created, state()}.
init(Game) ->
  {ok, Dispatcher} = gen_event:start_link(),
  {ok, created, #{game => Game, dispatcher => Dispatcher}}.

-spec handle_event(Event, atom(), state()) ->
  {stop, {unexpected, Event}, state()}.
handle_event(Event, _StateName, State) -> {stop, {unexpected, Event}, State}.

-spec handle_sync_event
  (fetch, _From, atom(), state()) ->
    {reply, serpents_games:game(), atom(), state()};
  (dispatcher, _From, atom(), state()) ->
    {reply, pid(), atom(), state()}.
handle_sync_event(fetch, _From, StateName, State) ->
  #{game := Game} = State,
  {reply, {ok, Game}, StateName, State};
handle_sync_event(dispatcher, _From, StateName, State) ->
  #{dispatcher := Dispatcher} = State,
  {reply, {ok, Dispatcher}, StateName, State}.

-spec handle_info(term(), atom(), state()) -> {next_state, atom(), state()}.
handle_info(Info, StateName, State) ->
  lager:notice("~p received at ~p", [Info, StateName]),
  {next_state, StateName, State}.

-spec terminate(term(), atom(), state()) -> ok.
terminate(Reason, StateName, State) ->
  #{dispatcher := Dispatcher} = State,
  catch gen_event:stop(Dispatcher),
  lager:notice("Terminating in ~p with reason ~p", [StateName, Reason]).

-spec code_change(term() | {down, term()}, atom(), state(), term()) ->
    {ok, atom(), state()}.
code_change(_, StateName, State, _) -> {ok, StateName, State}.

-spec created({join, serpents_players:id()}, _From, state()) ->
  {reply, {ok, position()} | {error, term()}, created, state()}.
created({join, PlayerId}, _From, State) ->
  {reply, {error, not_implemented}, created, State}.

-spec created(start, state()) -> {next_state, started, state()}.
created(start, State) ->
  {next_state, started, State}.

-spec started({turn, serpents_players:id(), direction()}, state()) ->
  {next_state, started | finished, state()}.
started({turn, PlayerId, Direction}, State) ->
  {next_state, started, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% INTERNAL FUNCTIONS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
call(GameId, Event) ->
  Process = process_name(GameId),
  try do_call(Process, Event) of
    ok -> ok;
    {ok, Result} -> Result;
    {error, Error} -> throw(Error)
  catch
    _:Exception ->
      lager:error(
        "Couldn't send ~p to ~p (~p): ~p~nStack: ~p",
        [Event, GameId, Process, Exception, erlang:get_stacktrace()]),
      throw(Exception)
  end.

do_call(Process, fetch) ->
  gen_fsm:sync_send_all_state_event(Process, fetch);
do_call(Process, dispatcher) ->
  gen_fsm:sync_send_all_state_event(Process, dispatcher);
do_call(Process, Event) ->
  gen_fsm:sync_send_event(Process, Event).

cast(GameId, Event) ->
  gen_fsm:send_event(process_name(GameId), Event).

process_name(GameId) ->
  binary_to_atom(<<?MODULE_STRING, $:, GameId/binary>>, utf8).
