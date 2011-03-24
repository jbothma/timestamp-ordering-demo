%% - Server module
%% - The server module creates a parallel registered process by spawning a process which 
%% evaluates initialize(). 
%% The function initialize() does the following: 
%%      1/ It makes the current process as a system process in order to trap exit.
%%      2/ It creates a process evaluating the store_loop() function.
%%      4/ It executes the server_loop() function.

-module(server).

-export([start/0]).

%%%%%%%%%%%%%%%%%%%%%%% STARTING SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
start() -> 
    register(transaction_server, spawn(fun() ->
					       process_flag(trap_exit, true),
					       Val= (catch initialize()),
					       io:format("Server terminated with:~p~n",[Val])
				       end)).

initialize() ->
    process_flag(trap_exit, true),
    Initialvals = [{a,0,0,0},{b,0,0,0},{c,0,0,0},{d,0,0,0}], %% All variables are set to 0
    ServerPid = self(),
    StorePid = spawn_link(fun() -> store_loop(ServerPid,Initialvals) end),
    % initial TrnCnt is 0
    TrnHist = [{0, committed}], % hack for initial RTS and WTS
    % initial Checking is []
    server_loop([], StorePid, 0, TrnHist, []).
%%%%%%%%%%%%%%%%%%%%%%% STARTING SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% - The server maintains a list of all connected clients and a store holding
%% the values of the global variable a, b, c and d 
%% TrnCnt is Transaction Count, incremented in start_transaction
server_loop(ClientList, StorePid, TrnCnt, TrnHist, Checking) ->
    %io:format("Server: ClientList=~p~n", [ClientList]),
    receive
	{login, MM, Client} -> 
	    MM ! {ok, self()},
	    io:format("New client has joined the server:~p.~n", [Client]),
	    StorePid ! {print, self()},
	    server_loop(add_client(Client,ClientList), StorePid, TrnCnt, TrnHist, Checking);
	{close, Client} -> 
	    io:format("Client ~p has left the server.~n", [Client]),
	    StorePid ! {print, self()},
	    server_loop(remove_client(Client,ClientList), StorePid, TrnCnt, TrnHist, Checking);
	{request, Client} -> 
	    Client ! {proceed, self()},
        io:format("request from ~p, starting new transaction.~n", [Client]),
        {NewTrnCnt, NewClientList} = start_transaction(TrnCnt, ClientList, Client),
        NewTrnHist = [{NewTrnCnt, running}|TrnHist],
        io:format("New transaction count stands at ~p~n", [NewTrnCnt]),
	    server_loop(NewClientList, StorePid, NewTrnCnt, NewTrnHist, Checking);
	{confirm, Client} -> 
        ServerPid = self(),
        io:format("confirm from ~p~n", [Client]),
        {_, TS, DEP, _} = lists:keyfind(Client, 1, ClientList),
        CheckingPid = spawn(fun() -> check_commit_loop(TS, DEP, TrnHist, ServerPid) end),
        NewChecking = [CheckingPid|Checking],
	    server_loop(ClientList, StorePid, TrnCnt, TrnHist, NewChecking);
	{action, Client, Act} ->
	    %io:format("Received ~p from client ~p.~n", [Act, Client]),
        TS = get_transaction(ClientList, Client),
        StorePid ! {Act, TS, self()},
        receive
            {read_ok, Idx, Val, WTS} ->  % do DEP(T_i).add(WTS(O_j))
                io:format("Server: Trn ~p read ~p allowed: ~p.~n", [TS, Idx, Val]),
                NewClientList = add_to_DEP(ClientList, TS, WTS);
            {write_ok, Idx, OldObject} ->  % Let server do OLD(T_i).add( O_j, WTS(O_j) )                
                io:format("Server: Trn ~p write ~p allowed.~n", [TS, Idx]),
                NewClientList = add_to_Old(ClientList, TS, OldObject);
            {abort, TS, Reason} ->
                io:format("Server: DB said abort trn ~p. Reason: ~p.~n", [TS, Reason]),
                {NewClientList, NewTrnHist, NewChecking} = 
                    abort(TS, -1, ClientList, StorePid, TrnHist,Checking, self()),
                server_loop(NewClientList, StorePid, TrnCnt, NewTrnHist, NewChecking)
        end,
	    server_loop(NewClientList, StorePid, TrnCnt, TrnHist, Checking);
    {abort, TS, Reason, ChkPid} ->
        io:format("Server: check trn ~p said ABORT. Reason: ~p.~n", [TS,Reason]),
        {NewClientList, NewTrnHist, NewChecking} = 
            abort(TS, ChkPid, ClientList, StorePid, TrnHist,Checking, self()),
        server_loop(NewClientList, StorePid, TrnCnt, NewTrnHist, NewChecking);
    {commit, TS, ChkPid} ->
        % set status in history to committed
        NewTrnHist  = lists:keyreplace(TS, 1, TrnHist, {TS, committed}),
        NewChecking = Checking--[ChkPid],
        Client      = element(1, lists:keyfind(TS, 2, ClientList)),
        NewClientList = end_transaction(ClientList, Client),
	    Client ! {committed, self()},
        announce_completion(Checking),
        server_loop(NewClientList, StorePid, TrnCnt, NewTrnHist, NewChecking)
    after 50000 ->
	case all_gone(ClientList) of
	    true -> exit(normal);    
	    false -> server_loop(ClientList, StorePid, TrnCnt, TrnHist, Checking)
	end
    end.

%% - The values are maintained here
store_loop(ServerPid, Database) -> 
    receive
	{print, ServerPid} -> 
	    io:format("Database status:~n~p.~n",[Database]),
	    store_loop(ServerPid,Database);
    {{write, Idx, Val}, TS, ServerPid} ->
        io:format("DB: Must write val ~p to idx ~p for trn ~p~n", [Val, Idx, TS]),
        WTS = get_WTS(Database, Idx),
        RTS = get_RTS(Database, Idx),
        if
			%http://en.wikipedia.org/wiki/Talk:Timestamp-based_concurrency_control#Thomas_Write_Rule
            (WTS > TS) or (RTS > TS) ->
				Reason = "WTS " ++ integer_to_list(WTS) ++  " > TS " ++ integer_to_list(TS) ++
					" or RTS " ++ integer_to_list(RTS) ++ " > TS " ++ integer_to_list(TS),
                ServerPid ! {abort, TS, Reason},
                NewDatabase = Database;
            true ->
                OldObject = lists:keyfind(Idx, 1, Database),
                %set WTS(O_j) = TS(T_i)
                %do write
                NewDatabase = do_write(Database, Idx, Val, TS),
                ServerPid ! {write_ok, Idx, OldObject}  % Let server do OLD(T_i).add( O_j, WTS(O_j) )
        end,
	    io:format("Database status:~n~p.~n",[NewDatabase]),
	    store_loop(ServerPid,NewDatabase);
    {{read, Idx}, TS, ServerPid} ->
        io:format("DB: Must read idx ~p for trn ~p~n", [Idx, TS]),
%        WTS = get_WTS(Database, Idx),
		{_, Val, RTS, WTS} = lists:keyfind(Idx, 1, Database),
        if
            WTS > TS ->
				Reason = "WTS" ++ integer_to_list(WTS) ++ "TS" ++ integer_to_list(TS),
                ServerPid ! {abort, TS, Reason},
                NewDatabase = Database;
            true ->                 
                ServerPid ! {read_ok, Idx, Val, WTS},     % Let server do DEP(T_i).add(WTS(O_j))
%                RTS = get_RTS(Database, Idx),
                NewDatabase = set_RTS(Database, Idx, erlang:max(RTS, TS))
        end,
	    io:format("Database status:~n~p.~n",[NewDatabase]),
	    store_loop(ServerPid, NewDatabase);
    {rollback, TS, OLD, ServerPid} ->
        io:format("DB: rolling back OLD=~p~n", [OLD]),
        NewDatabase = rollback(Database, TS, OLD),
        ServerPid ! rollback_complete,  % TODO server blocks until this is done but not sure it's necesary
	    io:format("Database status:~n~p.~n",[NewDatabase]),
        store_loop(ServerPid, NewDatabase)
    end.

% spawned as separate process from server_loop.
% each loop, check status of each transaction DEP.
% Wait for a 'someone_completed' from server_loop each 
% time a running transaction is encountered in DEP.
% restart loop with up-to-date history upon 'someone_completed'
check_commit_loop(TS, DEP, TrnHist, ServerPid) ->
    %io:format("checking trn ~p: DEP=~p   TrnHist=~p~n", [TS, sets:to_list(DEP), TrnHist]),
    CommitCheck = check_history(TS, TrnHist, sets:to_list(DEP)),
    case CommitCheck of
        {wait, Reason} ->
            io:format("checking: wait...~p.~n", [Reason]),
            receive 
            {someone_completed, NewTrnHist} ->
                check_commit_loop(TS, DEP, NewTrnHist, ServerPid)
            end;
        {abort, Reason} ->
            %io:format("checking: abort~n"),
            ServerPid ! {abort, TS, Reason, self()};
        commit ->
            %io:format("checking: commit~n"),
            ServerPid ! {commit, TS, self()}
    end.

%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

abort(TS, ChkPid, ClientList, StorePid, TrnHist, Checking, ServerPid)  ->
    {Client, _, _, OLD} = lists:keyfind(TS, 2, ClientList),
    StorePid ! {rollback, TS, OLD, ServerPid},
    %set status in history to aborted
    NewTrnHist      = lists:keyreplace(TS, 1, TrnHist, {TS, aborted}),
    NewChecking     = Checking--[ChkPid],
    NewClientList   = end_transaction(ClientList, Client),
    Client ! {abort, self()},
    announce_completion(Checking),
    {NewClientList, NewTrnHist, NewChecking}.



%        for each (oldO_j, oldWTS(O_j)) in OLD(T_i):     // make sure nothing persists from this aborting transaction:
%            If WTS(Oj) equals TS(Ti):                   // if current value is what this transaction wrote to it
%                O_j = oldO_j                            // restore old value
%                WTS(O_j) = oldWTS(O_j)                  // restore old value
% usage:  NewDatabase = rollback(Database, TS, OLD)
rollback(Database, _, []) -> Database;
rollback(Database, TS, [ {Idx,OldVal,_,OldWTS} |RestOLD]) ->
    WTS = get_WTS(Database, Idx),
    RTS = get_RTS(Database, Idx),
    if
        WTS == TS ->
            NewDatabase = lists:keyreplace(Idx, 1, Database, {Idx, OldVal, RTS, OldWTS}),
            rollback(NewDatabase, TS, RestOLD);
        true ->
            Database
    end.

get_WTS(DB, Idx) ->
    element(4, lists:keyfind(Idx, 1, DB)).

%set_WTS(DB, Idx, NewWTS) ->
%    {_, Val, RTS, _} = lists:keyfind(Idx, 1, DB),
%    lists:keyreplace(Idx, 1, DB, {Idx, Val, RTS, NewWTS}).

get_RTS(DB, Idx) ->
    element(3, lists:keyfind(Idx, 1, DB)).

set_RTS(DB, Idx, NewRTS) ->
    {_, Val, _, WTS} = lists:keyfind(Idx, 1, DB),
    lists:keyreplace(Idx, 1, DB, {Idx, Val, NewRTS, WTS}).

add_to_DEP(ClientList, TS, DependOnTS) ->
    {Client, _, DEP, OLD} = lists:keyfind(TS, 2, ClientList),
    lists:keyreplace(TS, 2, ClientList, {Client, TS, sets:add_element(DependOnTS, DEP), OLD}).

% add OldObject to OLD list if there isn't an earlier copy already
add_to_Old(ClientList, TS, OldObject) ->
    {Client, _, DEP, OLD} = lists:keyfind(TS, 2, ClientList),
    case lists:keyfind(element(1,OldObject), 1, OLD) of
        false ->
            lists:keyreplace(TS, 2, ClientList, {Client, TS, DEP, [OldObject|OLD]});
        _Other ->
            ClientList
    end.

do_write(DB, Idx, Val, TS) ->
    lists:keyreplace(Idx, 1, DB, {Idx, Val, get_RTS(DB, Idx), TS}).

% send all Checking transactions a "someone_completed" with updated transaction history
announce_completion(Checking) ->
    lists:map(fun(CheckingPid) -> CheckingPid ! someone_committed end, Checking).

%check_history(Committer, History, DEP) -> commit or abort or wait
check_history(_, [], _) -> io:format("our_error_empty_history~n");
check_history(_, _, []) -> commit;
check_history(Committer, History, [Committer|Rest]) -> check_history(Committer, History, Rest);  % skip self
check_history(Committer, History, [TS|Rest]) ->
    {_, Status} = lists:keyfind(TS, 1, History),
    case Status of 
        aborted ->
            {abort, integer_to_list(TS) ++ " aborted"};
        running ->
            {wait, integer_to_list(TS) ++ " is running"};
        committed ->
            check_history(Committer, History, Rest)
    end.

%handle_action({write, Idx, Val}, TS) ->
%    io:format("Must write val ~p to idx ~p for client ~p~n", [Val, Idx, TS]);
%handle_action({read, Idx}, TS) ->
%    io:format("Must read idx ~p for client ~p~n", [Idx, TS]).
    

% Return new client list where the client tuple has been replaced with
% one where all values are the same except for the new transaction number.
% !!!NOTE!!! it assumes each client only ever attempts one transaction at a time!
start_transaction(TrnCnt, ClientList, Client) ->
    NewTrnCnt           = TrnCnt + 1,
    {_, _, DEP, OLD}    = lists:keyfind(Client, 1, ClientList),
    {NewTrnCnt, lists:keyreplace(Client, 1, ClientList, {Client, NewTrnCnt, DEP, OLD})}.

end_transaction(ClientList, Client) ->
    lists:keyreplace(Client, 1, ClientList, {Client, nil, sets:new(), []}).

get_transaction(ClientList, Client) -> 
    TS = element(2, lists:keyfind(Client, 1, ClientList)),
    case TS of
        TS when is_integer(TS)  -> TS;
        _Else                   -> io:format("no TS for client ~p in ~p~n", [Client,ClientList])
    end.

%% - Low level function to handle lists
add_client(C,ClientList) -> [new_client(C)|ClientList].

new_client(C) -> {C, nil, sets:new(),[]}.

% remove anything from empty list returns empty list
remove_client(_,[]) -> [];
% if client is first, return rest
remove_client(C, [ {C,_,_,_} | T ]) -> T;
% falling through when client wasn't first, 
% recurse down and return first and rest with client removed from in-between
remove_client(C, [H|T]) -> [H|remove_client(C,T)].

all_gone([]) -> true;
all_gone(_) -> false.
