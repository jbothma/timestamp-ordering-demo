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
%% TrnCnt is Transaction Count - next new transaction TS will be TrnCnt + 1
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
        NewTrnCnt = TrnCnt + 1,
        io:format("request from ~p, starting transaction ~p~n", [Client, NewTrnCnt]),
	    server_loop(ClientList, StorePid, NewTrnCnt);
	{confirm, Client} -> 
        io:format("confirm from ~p~n", [Client]),
	    Client ! {abort, self()},
	    server_loop(ClientList, StorePid, TrnCnt);
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



%% - Low level function to handle lists
add_client(C,ClientList) -> [new_client(C)|ClientList].

new_client(C) -> [C, nil, [],[]].

% remove anything form empty list returns empty list
remove_client(_,[]) -> [];
% if client is first, return rest
remove_client(C, [ [C|_] | T ]) -> T;
% falling through when client wasn't first, 
% recurse down and return first and rest with client removed from in-between
remove_client(C, [H|T]) -> [H|remove_client(C,T)].

all_gone([]) -> true;
all_gone(_) -> false.
