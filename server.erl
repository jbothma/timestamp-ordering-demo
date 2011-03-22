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
    % initial TrnHist is []
    % initial Checking is []
    server_loop([], StorePid, 0, [], []).
%%%%%%%%%%%%%%%%%%%%%%% STARTING SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% - The server maintains a list of all connected clients and a store holding
%% the values of the global variable a, b, c and d 
%% TrnCnt is Transaction Count, incremented in start_transaction
server_loop(ClientList, StorePid, TrnCnt, TrnHist, Checking) ->
    %io:format("ClientList: ~p~n", [ClientList]),
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
        io:format("confirm from ~p~n", [Client]),
        [_, TS, DEP, _] = find_client(Client, ClientList),
        CheckingPid = spawn(fun() -> do_commit_loop(TS, DEP, TrnHist, self()) end),
        NewChecking = [CheckingPid|Checking],
	    server_loop(ClientList, StorePid, TrnCnt, TrnHist, NewChecking);
	{action, Client, Act} ->
	    io:format("Received ~p from client ~p.~n", [Act, Client]),
        handle_action(Act, Client),
	    server_loop(ClientList, StorePid, TrnCnt, TrnHist, Checking);
    {abort, TS, ChkPid} ->
        %set status in history to aborted
        NewTrnHist = lists:keyreplace(TS, 1, TrnHist, {TS, aborted}),
        NewChecking = Checking--[ChkPid],
        %send client abort
        Client = lists:keyfind(TS, 2, ClientList),
	    Client ! {abort, self()},
        % send all Checking transactions a "someone_completed" with updated transaction history
        lists:map(fun(CheckingPid) -> CheckingPid ! someone_committed end, Checking),
        % transaction has ended
        NewClientList = end_transaction(ClientList, Client),
        server_loop(NewClientList, StorePid, TrnCnt, NewTrnHist, NewChecking);
    {commit, TS, ChkPid} ->
        % set status in history to committed
        NewTrnHist = lists:keyreplace(TS, 1, TrnHist, {TS, committed}),
        NewChecking = Checking--[ChkPid],
        % send client commit
        Client = lists:keyfind(TS, 2, ClientList),
	    Client ! {committed, self()},
        % send all Checking transactions a "someone_completed" with updated transaction history
        lists:map(fun(CheckingPid) -> CheckingPid ! someone_committed end, Checking),
        % transaction has ended
        NewClientList = end_transaction(ClientList, Client),
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
	    store_loop(ServerPid,Database)
    end.

% spawned as separate process from server_loop.
% each loop, check status of each transaction DEP.
% Wait for a 'someone_completed' from server_loop each 
% time a running transaction is encountered in DEP.
% restart loop with up-to-date history upon 'someone_completed'
do_commit_loop(TS, DEP, TrnHist, ServerPid) ->    
    io:format("checking: DEP=~p   TrnHist=~p~n", [DEP, TrnHist]),
    CommitCheck = check_history(TrnHist, DEP),
    io:format("here~n"),
    case CommitCheck of
        wait ->
            io:format("checking: wait~n"),
            receive 
            {someone_completed, NewTrnHist} ->
                do_commit_loop(TS, DEP, NewTrnHist, ServerPid)
            end;
        abort ->
            io:format("checking: abort~n"),
            ServerPid ! {abort, TS, self()};
        commit ->
            io:format("checking: commit~n"),
            ServerPid ! {commit, TS, self()}
    end.

%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%check_history(History, DEP) -> commit or abort or wait
check_history([], _) -> io:format("our_error_empty_history~n");
check_history(_, []) -> commit;
check_history(History, [TS|Rest]) ->
    {_, Status} = lists:keyfind(TS, 1, History),
    case Status of 
        aborted ->
            abort;
        running ->
            wait;
        committed ->
            check_history(History, Rest)
    end.

handle_action({write, Idx, Val}, Client) ->
    io:format("Must write val ~p to idx ~p for client ~p~n", [Val, Idx, Client]);
handle_action({read, Idx}, Client) ->
    io:format("Must read idx ~p for client ~p~n", [Idx, Client]).
    

% Return new client list where the client tuple has been replaced with
% one where all values are the same except for the new transaction number.
% !!!NOTE!!! it assumes each client only ever attempts one transaction at a time!
start_transaction(TrnCnt, ClientList, Client) ->
    NewTrnCnt           = TrnCnt + 1,
    [_, _, DEP, OLD]    = find_client(Client, ClientList),
    TempClientList      = remove_client(Client, ClientList),
    NewClientData       = [Client, NewTrnCnt, DEP, OLD],
    NewClientList       = [NewClientData|TempClientList],
    {NewTrnCnt, NewClientList}.

end_transaction(ClientList, Client) ->
    [_, _, DEP, OLD]    = find_client(Client, ClientList),
    TempClientList      = remove_client(Client, ClientList),
    NewClientData       = [Client, nil, DEP, OLD],
    [NewClientData|TempClientList].

%% - Low level function to handle lists
add_client(C,ClientList) -> [new_client(C)|ClientList].

new_client(C) -> [C, nil, [],[]].

% remove anything from empty list returns empty list
remove_client(_,[]) -> [];
% if client is first, return rest
remove_client(C, [ [C|_] | T ]) -> T;
% falling through when client wasn't first, 
% recurse down and return first and rest with client removed from in-between
remove_client(C, [H|T]) -> [H|remove_client(C,T)].

find_client(C, [ [C,TS,DEP,OLD] ]) -> [C,TS,DEP,OLD];
find_client(C, [ [C,TS,DEP,OLD] | _ ]) -> [C,TS,DEP,OLD];
find_client(C, [_|T]) -> find_client(C,T).

all_gone([]) -> true;
all_gone(_) -> false.
