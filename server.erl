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
    server_loop([],StorePid).
%%%%%%%%%%%%%%%%%%%%%%% STARTING SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% - The server maintains a list of all connected clients and a store holding
%% the values of the global variable a, b, c and d 
server_loop(ClientList,StorePid) ->
    receive
	{login, MM, Client} -> 
	    MM ! {ok, self()},
	    io:format("New client has joined the server:~p.~n", [Client]),
	    StorePid ! {print, self()},
	    server_loop(add_client(Client,ClientList),StorePid);
	{close, Client} -> 
	    io:format("Client~p has left the server.~n", [Client]),
	    StorePid ! {print, self()},
	    server_loop(remove_client(Client,ClientList),StorePid);
	{request, Client} -> 
	    Client ! {proceed, self()},
	    server_loop(ClientList,StorePid);
	{confirm, Client} -> 
	    Client ! {abort, self()},
	    server_loop(ClientList,StorePid);
	{action, Client, Act} ->
	    io:format("Received~p from client~p.~n", [Act, Client]),
    	StorePid ! {act, Act, self()},
	    server_loop(ClientList,StorePid)
    after 50000 ->
	case all_gone(ClientList) of
	    true -> exit(normal);    
	    false -> server_loop(ClientList,StorePid)
	end
    end.

%% - The values are maintained here
store_loop(ServerPid, Database) -> 
    receive
	{print, ServerPid} -> 
	    io:format("Database status:~n~p.~n",[Database]),
	    store_loop(ServerPid,Database);
	{act, Act, ServerPid} -> 
        Op  = element(1, Act),
        Key = element(2, Act),
        case Op of
            'read' ->
                OldVal = element(2, lists:keyfind(Key, 1, Database)),
                io:format("Read ~p as ~p~n", [Key, OldVal]);
            'write' ->
                NewVal = element(3, Act),
                NewDatabase = lists:keyreplace(Key, 1, Database, {Key, NewVal}),
                io:format("Write ~p as ~p~n", [Key, NewVal]),
        	    io:format("Database status:~n~p.~n",[NewDatabase]),
        	    store_loop(ServerPid,NewDatabase)
        end,
	    io:format("Database status:~n~p.~n",[Database]),
	    store_loop(ServerPid,Database)
    end.
%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



%% - Low level function to handle lists
add_client(C,T) -> [C|T].

remove_client(_,[]) -> [];
remove_client(C, [C|T]) -> T;
remove_client(C, [H|T]) -> [H|remove_client(C,T)].

all_gone([]) -> true;
all_gone(_) -> false.
    
