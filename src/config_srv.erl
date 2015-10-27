-module(config_srv).
-author('komm@siphost.su').

-behaviour(gen_server).

-include_lib("kernel/include/file.hrl").

-define(SERVER, ?MODULE).
-define(DEFAULT_APP, nconfig).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0, start_link/1, get_config/0, get_config/1, get_config/2, read_config/1, update_config/1, save_config/1, apply/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
  gen_server:start_link({global, ?SERVER}, ?MODULE, [], [])
.

start_link(local)->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], [])
;
start_link(NormalazeFun) ->
  gen_server:start_link({global, ?SERVER}, ?MODULE, [NormalazeFun], [])
.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([])->
  Config=read_config(file),
  {ok, Config}
;
init([NormalazeFun])->
  Config=NormalazeFun(read_config(file)),
  {ok, Config}
.

handle_call(all, _From, Config) ->
  {reply, Config, Config};



handle_call({get,Val}, _From, Config) when is_binary(Val)->
  {reply, pp(Val,Config), Config}
;
handle_call({get, []}, _From, Config) -> {reply, Config, Config};
handle_call({get, [H|T]}, From, Config) ->
  [KeyValue | Filters] = H,

  FunFilter=
  fun(_Fun, [], _Cfg)->
     true;
     (Fun, [{[$?|FilterKey], FilterValue}|NextFilter], Cfg)->
      FilterValueAtom = list_to_binary(FilterValue),
      case pp(list_to_binary(FilterKey), Cfg) of
      []->
        Fun(Fun, NextFilter, Cfg)
      ;
      FilterValueAtomList when is_list(FilterValueAtomList) -> 
        case lists:member(FilterValueAtom, FilterValueAtomList) of
        true->
            Fun(Fun, NextFilter, Cfg);
        false->
            false
        end
      ;
      _Res-> 
        false
      end

     ;
     (Fun, [{FilterKey, FilterValue}|NextFilter], Cfg)->
      %%io:format('FilterKey=~w,  FilterValue=~w, NextFilter=~w~n~n', [FilterKey, FilterValue, NextFilter]),
      FilterValueAtom = list_to_binary(FilterValue),
      case pp(list_to_binary(FilterKey), Cfg) of
      FilterValueAtomList when is_list(FilterValueAtomList) -> 
        case lists:member(FilterValueAtom, FilterValueAtomList) of
        true->
            Fun(Fun, NextFilter, Cfg);
        false->
            false
        end
      ;
      _Res->  
        false
      end
  end, %%([list_to_tuple(string:tokens(XXX,"=")) || XXX<-Filters]),

  case pp(list_to_binary(KeyValue), Config) of
  [Config1] when is_binary(Config1) ->
      case T of
      []->
          case FunFilter(FunFilter, [list_to_tuple(string:tokens(XXX,"=")) || XXX<-Filters], Config) of
          true->
              {reply, Config1, Config};
          false->
              {reply, [], Config}
          end;
      _-> 
          {reply, [], Config}
      end
  ;
  Config1 when is_list(Config1)->
      case FunFilter(FunFilter, [list_to_tuple(string:tokens(XXX,"=")) || XXX<-Filters], Config) of
      true->
          Result = [fun({reply, Resp, _})-> Resp end(handle_call({get, T}, From, CCC)) || CCC <- Config1],
          {reply, Result -- lists:duplicate(length(Result), []), Config};
          %%{reply, lists:flatten(Result), Config};
      false->
          {reply, [], Config}
      end
  end
;



handle_call({update_config, file} ,_From, Config)->
   NewConfig = case catch read_config(file) of
   {'EXIT', Error} -> 
        error_logger:error_report([{?MODULE, handle_call}, {'FAIL', {update_config, file}}, Error]),
        Config
   ;
   Other -> Other
   end,
   {reply,ok, NewConfig}
;
handle_call({update_config, json, Json} ,_From, _Config)->
   NewConfig = mochijson2:decode(Json),
   Fun =
   fun(Fun, {struct, Array})-> 
        lists:flatten(
        [case is_list(X) of 
         true -> 
            [{Name, Fun(Fun, V)} || V <-X]
         ;
         false -> 
            {Name, Fun(Fun, X)} 
         end
        || {Name, X} <- Array ]);
      
      (Fun, Array) when is_list(Array)-> [Fun(Fun, Y) || Y<-Array]; 
      (_, Int) when is_integer(Int)-> Int; 
      (_, Bin) when is_binary(Bin)-> Bin
   end,
   {reply,ok, Fun(Fun, NewConfig)}
.


handle_cast(_Msg, Config) ->
  {noreply, Config}.

handle_info(_Info, Config) ->
  {noreply, Config}.

terminate(_Reason, _Config) ->
  ok.

code_change(_OldVsn, Config, _Extra) ->
  {ok, Config}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec pp(Value :: term(), Config :: list()) -> false | term().
pp(_, [])->
    [];
pp(Val, [{Val, R}|T])->
    [R] ++ pp(Val, T);
pp(Val, [_|T])->
    pp(Val, T)
.

-spec compare(Key :: list(), Template :: list()) -> Result :: list().
compare([],_)->[];
compare([HeadConfig|Tail], Template)->
	{BlockName, Value} = HeadConfig,
	RequredParameter = pp(BlockName, Template),
	Diff = [ X || {X, _} <- RequredParameter] -- [X || {X, _} <- Value],
	[{BlockName, Value ++ [lists:keyfind(X,1,RequredParameter) || X <- Diff ]}] ++ compare(Tail, Template)

.

-spec read_config( http ) -> none;
        ( json ) -> none;
        ( file ) -> Config :: list();
        ( {file, Path :: list()} ) -> Config :: list().
read_config({file, Path})->
  case file:read_file_info(Path) of
  {error, Reason}->
    error_logger:error_report([{?MODULE, read_config}, {error_read_file, Reason}, {file, Path}, "Load default parameters"])
  ;
  {ok, #file_info{type = Type, access = Access}} when (Access==read) or (Access==read_write), (Type==regular) or (Type==symlink)->
      case catch emd_config:file(Path) of
      {'EXIT', _}->
          error_logger:error_report([{?MODULE, read_config}, {error_read_file}, {file, Path}, "Load default parameters"]),
          default()
      ;
      {_, BadString, BadValue}->
          error_logger:error_report([{?MODULE, read_config}, {error_read_file, BadString, BadValue}, "Load default parameters"]),
          default()
      ;
      Config when is_list(Config)-> 
          compare(Config, default())
      end
  end
;
read_config(file)->
  case {os:getenv("NCONFIG"), init:get_argument(conf), init:get_argument(nconfig)} of
  {false, error, error}->
     default()
  ;
  {false, {ok, [[Path]]}, _} ->
     read_config({file, Path})
  ;
  {false, error, {ok, [[Path]]}} ->
     read_config({file, Path})
  ;
  {Path, _,_ }->
     read_config({file, Path})
  end
;
read_config(http)->none;
read_config(json)->none.

-spec default() -> Config :: list().
default()->
	application:get_all_env(?DEFAULT_APP) -- [{included_applications,[]}]
.

-spec save_config( file )            -> ok;
		 ( raw )             -> Config :: list();
		 ( Value :: term() ) -> error.
save_config(raw)-> 
      lists:flatten(
      [io_lib:format('~s{\n~s}\n',[X, 
		[case C of 
                 argv -> io_lib:format('\t~s = "~s";\n',[C, V]);
                 _ -> io_lib:format('\t~s = ~s;\n',[C, V])
                 end
                || {C, V} <- Y] ]) 
      || {X,Y} <- get_config()])
;
save_config(file)-> 
  Argx=init:get_arguments(),
  case lists:keyfind(conf,1,Argx) of
    false-> error;
    {conf,Path}->
      Data = iolist_to_binary(encode_config(get_config())),
      file:write_file(Path,Data),
      ok
  end
;
save_config(_)->
  error
.

get_tabs(Level)->
    [$\t || _ <- lists:seq(1,Level)]
.

encode_config(Config)->
    encode_config(Config,0)
.
encode_config([],_Level)->
    ""
;
encode_config([{Key,Value}|Tail],Level) when is_binary(Value) ->
    io_lib:format('~s~s = "~s";\n',[get_tabs(Level),Key, Value]) ++ encode_config(Tail,Level)
;
encode_config([{Key,Value}|Tail],Level) when is_list(Value) ->
    Tabs = get_tabs(Level),
    io_lib:format('~s~s{\n~s~s}\n',[Tabs, Key, encode_config(Value,Level+1),Tabs]) ++ encode_config(Tail,Level)
.

-spec update_config( Value :: term() ) -> ok. 
update_config(file)->
  gen_server:call({global, ?MODULE}, {update_config, file}),
  ok
;
update_config({json, Json})->
  gen_server:call({global, ?MODULE}, {update_config, json, Json}),
  ok
.

-spec apply(App :: list()) -> ok | error.
apply(App)->
  case get_config(App) of
   false -> error;
   [List] when is_list(List) ->
     [application:set_env(App, list_to_atom(binary_to_list(Value)), list_to_atom(binary_to_list(Parameter))) || {Value, Parameter} <- List],
     ok
  end
.

-spec get_config() -> term(). 
get_config()->
   gen_server:call({global, ?MODULE}, all).

get_config(json)->
   Config = get_config(),
   Fun =
   fun(_Fun,[],Res) -> Res;
      (Fun,[{Key,Value}|Tail],Res) when is_binary(Value) -> 
        Fun(Fun, Tail, Res ++ [{Key, Value}]);
      (Fun,[{Key,Value}|Tail],Res) when is_list(Value) -> 
        NewRes = 
        case lists:keyfind(Key,1,Res) of
        false -> 
            Res ++ [{Key,{struct, Fun(Fun, Value,[])}}]
        ;
        {Key, Val} when is_list(Val) ->
            NewVal = Val ++ [{struct, Fun(Fun, Value,[])}],
            lists:keyreplace(Key,1,Res, {Key, NewVal})
        ;
        {Key, Val} ->
            NewVal = [Val] ++ [{struct, Fun(Fun, Value,[])}],
            lists:keyreplace(Key,1,Res, {Key, NewVal})
        end,
        Fun(Fun, Tail, NewRes);
      (Fun,[List],Res) when is_list(List) -> [Fun(Fun, List, [])]
   end,
   Fun(Fun, Config, [])
;
get_config(Val) when is_atom(Val)->
   get_config(list_to_binary(atom_to_list(Val)))
;
%% search section "/section1/section2&node=node@hostname&?role=master/.../sectionN"
get_config(Val) when is_list(Val)->
   Val1 = re:replace(Val, [92,92,$/], [172], [{return,list}, global]),
   %%Path = [ string:tokens(X, "&") || X<-string:tokens(Val1, "/")],
   Path = [ [re:replace(Y, [172], "/", [{return,list}, global]) || Y<-string:tokens(X, "&")] || X<-string:tokens(Val1, "/")],
   gen_server:call({global, ?MODULE}, {get, Path})
;
get_config(Val) when is_binary(Val)->
   case gen_server:call({global, ?MODULE}, {get, Val}) of
     false -> application:get_all_env(Val);
     List -> List ++ application:get_all_env(Val)
   end
.

get_config(global, Val) ->
    get_config(Val)
;
get_config(local, Val) when is_atom(Val)->
   get_config(local, list_to_binary(atom_to_list(Val)))
;
get_config(local, Val) when is_list(Val)->
   Val1 = re:replace(Val, [92,92,$/], [172], [{return,list}, global]),
   %%Path = [ string:tokens(X, "&") || X<-string:tokens(Val1, "/")],
   Path = [ [re:replace(Y, [172], "/", [{return,list}, global]) || Y<-string:tokens(X, "&")] || X<-string:tokens(Val1, "/")],
   gen_server:call(?MODULE, {get, Path})
;
get_config(local, Val) when is_binary(Val)->
   case gen_server:call(?MODULE, {get, Val}) of
     false -> application:get_all_env(Val);
     List -> List ++ application:get_all_env(Val)
   end
.
    
