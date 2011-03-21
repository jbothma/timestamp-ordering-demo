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
    Initialvals = [{a,0},{b,0},{c,0},{d,0}], %% All variables are set to 0
    ServerPid = self(),
    StorePid = spawn_link(fun() -> store_loop(ServerPid,Initialvals) end),
    server_loop([], StorePid, 0).           %% initial TrnCnt is 0
%%%%%%%%%%%%%%%%%%%%%%% STARTING SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% - The server maintains a list of all connected clients and a store holding
%% the values of the global variable a, b, c and d 
%% TrnCnt is Transaction Count, incremented in start_transaction
server_loop(ClientList, StorePid, TrnCnt) ->
    io:format("ClientList: ~p~n", [ClientList]),
    receive
	{login, MM, Client} -> 
	    MM ! {ok, self()},
	    io:format("New client has joined the server:~p.~n", [Client]),
	    StorePid ! {print, self()},
	    server_loop(add_client(Client,ClientList), StorePid, TrnCnt);
	{close, Client} -> 
	    io:format("Client ~p has left the server.~n", [Client]),
	    StorePid ! {print, self()},
	    server_loop(remove_client(Client,ClientList), StorePid, TrnCnt);
	{request, Client} -> 
	    Client ! {proceed, self()},
        io:format("request from ~p, starting new transaction.~n", [Client]),
        {NewTrnCnt, NewClientList} = start_transaction(TrnCnt, ClientList, Client),
        io:format("New transaction count stands at ~p~n", [NewTrnCnt]),
	    server_loop(NewClientList, StorePid, NewTrnCnt);
	{confirm, Client} -> 
        io:format("confirm from ~p~n", [Client]),
	    Client ! {abort, self()},
        NewClientList = end_transaction(ClientList, Client),
	    server_loop(NewClientList, StorePid, TrnCnt);
	{action, Client, Act} ->
	    io:format("Received ~p from client ~p.~n", [Act, Client]),
	    server_loop(ClientList, StorePid, TrnCnt)
    after 50000 ->
	case all_gone(ClientList) of
	    true -> exit(normal);    
	    false -> server_loop(ClientList, StorePid, TrnCnt)
	end
    end.

%% - The values are maintained here
store_loop(ServerPid, Database) -> 
    receive
	{print, ServerPid} -> 
	    io:format("Database status:~n~p.~n",[Database]),
	    store_loop(ServerPid,Database)
    end.
%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Return new client list where the client tuple has been replaced with
% one where all values are the same except for the new transaction number.
% !!!NOTE!!! it assumes each client only ever attempts one transaction at a time!
start_transaction(TrnCnt, ClientList, Client) ->
    NewTrnCnt           = TrnCnt + 1,
    [_, _, DEP, OLD]    = find_client(Client, ClientList),
    TempClientList      = remove_client(Client, ClientList),
    NewClientData       = [Client, NewTrnCnt, DEP, OLD],
    NewClientList       = TempClientList ++ [NewClientData], % add updated client data to client list
    {NewTrnCnt, NewClientList}.

end_transaction(ClientList, Client) ->
    [_, _, DEP, OLD]    = find_client(Client, ClientList),
    TempClientList      = remove_client(Client, ClientList),
    NewClientData       = [Client, nil, DEP, OLD],
    TempClientList ++ [NewClientData]. % add updated client data to client list

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
