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
    %% Initial values and RTS and WTS are 0
    Initialvals = [{a,0,0,0},{b,0,0,0},{c,0,0,0},{d,0,0,0}], 
    ServerPid   = self(),
    StorePid    = spawn_link(fun() -> store_loop(ServerPid,Initialvals) end),

    ClientList  = [],
    TrnCnt      = 0,
    % TrnHist starts with fake transaction 0 for comparisons against initial RTS and WTS
    TrnHist     = [{0, committed}], 
    Checking    = [],
    server_loop(ClientList, StorePid, TrnCnt, TrnHist, Checking).
%%%%%%%%%%%%%%%%%%%%%%% STARTING SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% - The server maintains a list of all connected clients and a store holding
%% the values of the global variable a, b, c and d 
%% TrnCnt is Transaction Count, incremented in start_transaction
server_loop(ClientList, StorePid, TrnCnt, TrnHist, Checking) ->
    receive
    {login, MM, Client} ->  % client joining server
        MM ! {ok, self()},
        io:format("New client has joined the server:~p.~n", [Client]),
        StorePid ! {print, self()},
        server_loop(add_client(Client,ClientList), StorePid, TrnCnt, TrnHist, Checking);

    {close, Client} ->      % client leaving server
        io:format("Client ~p has left the server.~n", [Client]),
        StorePid ! {print, self()},
        server_loop(remove_client(Client,ClientList), StorePid, TrnCnt, TrnHist, Checking);

    {request, Client} ->    % client initiating a transaction
        TS = get_transaction(ClientList, Client),
        if
            is_integer(TS) ->
                % re-queue client's request if it already has a transaction open:   
                % Anything delaying completion of the transaction will eventually
                % get through the queue and the next transaction can start.
                % The current client waits for abort or confirm before starting a new
                % transaction, but since this server implementation assumes this, it's
                % good to enforce the assumption.
                self() ! {request, Client},
                server_loop(ClientList, StorePid, TrnCnt, TrnHist, Checking);
            true ->
                Client ! {proceed, self()},
                io:format("Server: Request from client ~p, starting new transaction.~n", [Client]),
                {NewTrnCnt, NewClientList} = start_transaction(TrnCnt, ClientList, Client),
                NewTrnHist = [{NewTrnCnt, running}|TrnHist],
                io:format("    New transaction count stands at ~p~n", [NewTrnCnt]),
                server_loop(NewClientList, StorePid, NewTrnCnt, NewTrnHist, Checking)
        end;

    {confirm, Client} ->    % client asking to complete a transaction
        ServerPid = self(),
        io:format("Server: confirm from client ~p.~n", [Client]),
        {_, TS, DEP, _} = lists:keyfind(Client, 1, ClientList),
        if
            is_integer(TS) ->
                CheckingPid = spawn(fun() -> check_commit_loop(TS, DEP, TrnHist, ServerPid) end),
                NewChecking = [CheckingPid|Checking],
                server_loop(ClientList, StorePid, TrnCnt, TrnHist, NewChecking);
            true -> %TS isn't an int, it's probably nil which means no transaction for this client.
                io:format("Server: Client ~p sent confirm but has no transaction open.~n", [Client]),
                server_loop(ClientList, StorePid, TrnCnt, TrnHist, Checking)
        end;

    {action, Client, Act} ->    % client sending one action in a transaction
        TS = get_transaction(ClientList, Client),
        if
            is_integer(TS) ->
                StorePid ! {Act, TS, self()},
                receive % block until DB responds with <op>_ok or abort

                {read_ok, Idx, Val, WTS} ->  % do DEP(T_i).add(WTS(O_j))
                    io:format("Server: Trn ~p read ~p allowed: ~p.~n", [TS, Idx, Val]),
                    NewClientList = add_to_DEP(ClientList, TS, WTS);

                {write_ok, Idx, OldObject} ->  % Let server do OLD(T_i).add( O_j, WTS(O_j) )                
                    io:format("Server: Trn ~p write ~p allowed.~n", [TS, Idx]),
                    NewClientList = add_to_OLD(ClientList, TS, OldObject);

                {abort, TS, Reason} ->
                    io:format("Server: DB said abort trn ~p. Reason: ~p.~n", [TS, Reason]),
                    {NewClientList, NewTrnHist, NewChecking} = 
                        abort(TS, -1, ClientList, StorePid, TrnHist,Checking, self()),
                    server_loop(NewClientList, StorePid, TrnCnt, NewTrnHist, NewChecking)
                end,
                server_loop(NewClientList, StorePid, TrnCnt, TrnHist, Checking);
            true -> %TS isn't an int, it's probably nil which means no transaction for this client.
                io:format("Server: Client ~p sent action ~p but has no transaction open.~n", [Client, Act]),
                server_loop(ClientList, StorePid, TrnCnt, TrnHist, Checking)
        end;

    {abort, TS, Reason, ChkPid} ->  % comfirm check process rejecting transaction
        io:format("Server: check trn ~p said ABORT. Reason: ~p.~n", [TS,Reason]),
        {NewClientList, NewTrnHist, NewChecking} = 
            abort(TS, ChkPid, ClientList, StorePid, TrnHist,Checking, self()),
        server_loop(NewClientList, StorePid, TrnCnt, NewTrnHist, NewChecking);

    {commit, TS, ChkPid} ->         % confirm check process approving transaction
        io:format("Server: check trn ~p said COMMIT.~n", [TS]),

        % set status in history to committed
        NewTrnHist      = lists:keyreplace(TS, 1, TrnHist, {TS, committed}),

        % The commit check proc finished upon commit. It shouldn't get commit 
        % notifications any more, so remove from Checking list.
        NewChecking     = Checking--[ChkPid],

        Client          = element(1, lists:keyfind(TS, 2, ClientList)),
        NewClientList   = end_transaction(ClientList, Client),

        % inform client
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
        io:format("DB status: ~p.~n",[Database]),
        store_loop(ServerPid,Database);

    {{write, Idx, Val}, TS, ServerPid} ->   % action from client matched as WRITE
        io:format("DB: Must write val ~p to idx ~p for trn ~p~n", [Val, Idx, TS]),
        WTS = get_WTS(Database, Idx),
        RTS = get_RTS(Database, Idx),
        if
            % abort if written by later transaction instead of applying "ignore obsolete write"
            % because rollback of a later transaction can make application of this rule invalid.
            (WTS > TS) or (RTS > TS) ->
                Reason = "WTS " ++ integer_to_list(WTS) ++  " > TS " ++ integer_to_list(TS) ++
                    " or RTS " ++ integer_to_list(RTS) ++ " > TS " ++ integer_to_list(TS),
                ServerPid ! {abort, TS, Reason},
                NewDatabase = Database;
            true -> % else: write is allowed
                OldObject = lists:keyfind(Idx, 1, Database),
                %do the write and set WTS(O_j) = TS(T_i)
                NewDatabase = do_write(Database, Idx, Val, TS),
                ServerPid ! {write_ok, Idx, OldObject}  % Let server do OLD(T_i).add( O_j, WTS(O_j) )
        end,
        io:format("DB status: ~p.~n",[NewDatabase]),
        store_loop(ServerPid,NewDatabase);

    {{read, Idx}, TS, ServerPid} ->     % action from client matched as READ
        io:format("DB: Must read idx ~p for trn ~p~n", [Idx, TS]),
        {_, Val, RTS, WTS} = lists:keyfind(Idx, 1, Database),
        if
            WTS > TS ->
                Reason = "WTS " ++ integer_to_list(WTS) ++ " > TS " ++ integer_to_list(TS),
                ServerPid ! {abort, TS, Reason},
                NewDatabase = Database;
            true ->      % else: read is allowed
                NewDatabase = set_RTS(Database, Idx, erlang:max(RTS, TS)),
                ServerPid ! {read_ok, Idx, Val, WTS}     % Let server do DEP(T_i).add(WTS(O_j))
        end,
        io:format("DB status: ~p.~n",[NewDatabase]),
        store_loop(ServerPid, NewDatabase);

    {rollback, TS, OLD, ServerPid} ->   % server said to rollback writes by trn TS with values in OLD
        io:format("DB: rolling back OLD=~p~n", [OLD]),
        NewDatabase = rollback(Database, TS, OLD),
        io:format("DB status: ~p.~n",[NewDatabase]),
        ServerPid ! rollback_complete,
        store_loop(ServerPid, NewDatabase)
    end.


% Process checking whether transaction can complete,
% spawned from server_loop.
%
% Each loop, check status of each transaction DEP.
%
% Wait for a 'someone_completed' from server_loop each 
% time a running transaction is encountered in DEP.
%
% Restart loop with more recent history upon 'someone_completed' msg from server.
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

    % set status in history to aborted
    NewTrnHist      = lists:keyreplace(TS, 1, TrnHist, {TS, aborted}),
    
    % checking proc will have ended, stop sending completion messages
    NewChecking     = Checking--[ChkPid],

    NewClientList   = end_transaction(ClientList, Client),

    % inform client that trn was aborted
    Client ! {abort, self()},

    announce_completion(Checking),
    {NewClientList, NewTrnHist, NewChecking}.



%for each (oldO_j, oldWTS(O_j)) in OLD(T_i):    // make sure nothing persists from this aborting transaction:
%   If WTS(Oj) equals TS(Ti):                   // if current value is what this transaction wrote to it
%       O_j = oldO_j                            // restore old value
%       WTS(O_j) = oldWTS(O_j)                  // restore old value
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

get_RTS(DB, Idx) ->
    element(3, lists:keyfind(Idx, 1, DB)).

set_RTS(DB, Idx, NewRTS) ->
    {_, Val, _, WTS} = lists:keyfind(Idx, 1, DB),
    lists:keyreplace(Idx, 1, DB, {Idx, Val, NewRTS, WTS}).

add_to_DEP(ClientList, TS, DependOnTS) ->
    {Client, _, DEP, OLD} = lists:keyfind(TS, 2, ClientList),
    lists:keyreplace(TS, 2, ClientList, {Client, TS, sets:add_element(DependOnTS, DEP), OLD}).


% add OldObject to OLD list if there isn't an earlier copy already
add_to_OLD(ClientList, TS, OldObject) ->
    {Client, _, DEP, OLD} = lists:keyfind(TS, 2, ClientList),
    case lists:keyfind(element(1,OldObject), 1, OLD) of
        false ->
            lists:keyreplace(TS, 2, ClientList, {Client, TS, DEP, [OldObject|OLD]});
        _Other ->
            ClientList
    end.

% update value and WTS
do_write(DB, Idx, Val, TS) ->
    lists:keyreplace(Idx, 1, DB, {Idx, Val, get_RTS(DB, Idx), TS}).


% send all Checking transactions a "someone_completed" with updated transaction history
announce_completion(Checking) ->
    lists:map(fun(CheckingPid) -> CheckingPid ! someone_committed end, Checking).


%Usage: check_history(Committer, History, DEP) -> commit OR abort OR wait
check_history(_, [], _) -> io:format("our_error_empty_history~n");
check_history(_, _, []) -> commit;
check_history(Committer, History, [Committer|Rest]) -> 
    check_history(Committer, History, Rest);  % skip self
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
    

% new transaction count and client list with client's transaction timestamp/ID updated
start_transaction(TrnCnt, ClientList, Client) ->
    NewTrnCnt           = TrnCnt + 1,
    {_, _, DEP, OLD}    = lists:keyfind(Client, 1, ClientList),
    {NewTrnCnt, lists:keyreplace(Client, 1, ClientList, {Client, NewTrnCnt, DEP, OLD})}.

end_transaction(ClientList, Client) ->
    lists:keyreplace(Client, 1, ClientList, {Client, nil, sets:new(), []}).

get_transaction(ClientList, Client) -> 
    element(2, lists:keyfind(Client, 1, ClientList)).


new_client(C) -> {C, nil, sets:new(),[]}.

%% - Low level function to handle lists
add_client(C,ClientList) -> [new_client(C)|ClientList].

% remove anything from empty list returns empty list
remove_client(_,[]) -> [];
remove_client(C, [ {C,_,_,_} | T ]) -> T;
remove_client(C, [H|T]) -> [H|remove_client(C,T)].


all_gone([]) -> true;
all_gone(_) -> false.
