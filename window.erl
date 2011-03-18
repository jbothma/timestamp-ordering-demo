%% - Window module
%% - A window implements all needed functions in order to interact with the client 
%% (indirectly with the server).
%% - The window provides a graphical way to the user in order to enter his transactions
%% - A transaction is list of commands of the form [read a, write b 200, read d, read b, 
%%   write d 300]
%%
%% The clients is supposed to enter the commands one by one then once he enters the run 
%% command the transaction will be sent to the server.
%% In case the transaction has been successfull, the user will get the values of the 
%% variables back and 
%% the temporary transaction will be reset. Otherwise (if it is aborted) the user can 
%% request again by 
%% entering the run command.
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% IMPORTANT!! DO NOT MODIFY THIS FILE
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


-module(window).

-export([start/1, set_title/2, set_prompt/2, insert_str/2]).

-import(parser,[parse/1]).

start(ClientPID) ->
    gs:start(),
    spawn_link(fun() -> widget(ClientPID) end).

set_title(Pid, Str) -> Pid ! {title, Str}.
insert_str(Pid, Str) -> Pid ! {insert, Str}.
set_prompt(Pid, Str) -> Pid ! {prompt, Str}.
    
%% Starts a window
%% Do not bother trying to understand this code.
widget(ClientPID) ->
    Size=[{width, 500}, {height, 200}],
    Win = gs:window(gs:start(), [{map, true}, {configure, true}, {title, "window"}|Size]),
    gs:frame(packer, Win, [{packer_x, [{stretch, 1, 500}]}, {packer_y, [{stretch, 10, 120, 100}, {stretch, 1, 15, 15}]}]),
    gs:create(editor, editor, packer, [{pack_x, 1}, {pack_y, 1}, {vscroll, right}]),
    gs:create(entry, entry, packer, [{pack_x, 1}, {pack_y, 2}, {keypress, true}]),
    gs:config(packer, Size),
    Prompt = " > ",
    Transaction = [],
    loop(Win, ClientPID, Prompt, Transaction).

loop(Win, ClientPID, Prompt, Transaction) ->
    receive
	{title, Str} ->
	    gs:config(Win, [{title, Str}]),
	    loop(Win, ClientPID, Prompt, Transaction);
	{insert, Str} ->
	    gs:config(editor, {insert, {'end', Str}}),
	    scroll_to_show_last_line(),
	    loop(Win, ClientPID, Prompt, Transaction);
	{gs,_,destroy,_,_} ->
	    %%io:format("Destroyed~n",[]),
	    exit(windowDestroyed);
	{prompt, Str} ->
	    %%io:format("Received new prompt ~p.~n",[Str]),
	    gs:config(entry, {delete, {0, last}}),
	    gs:config(entry, {insert, {0, Str}}),
	    loop(Win, ClientPID, Str, Transaction);
	{gs, entry,keypress,_,['Return'|_]} ->
	    Text = gs:read(entry, text),
	    %%io:format("Read:~p~n", [Text]),
	    gs:config(entry, {delete, {0, last}}),
	    gs:config(entry, {insert, {0, Prompt}}),
	    self() ! {insert, Text ++ ["\n"]},
	    try parse(Text) of 
		{run} -> case Transaction of
			     [] -> self() ! {insert, "Nothing to be done\n"};
			     _ -> ClientPID ! {request, self(), Transaction}
			 end;

		{reset} -> loop(Win, ClientPID, Prompt, []);
		Com -> loop(Win, ClientPID, Prompt, Transaction ++ [Com])
	    catch
		throw:Error ->
		    self() ! {insert, Error ++ "\n"}
	    end,
            loop(Win, ClientPID, Prompt, Transaction);
        {gs,_,configure,[],[W,H,_,_]} ->
            gs:config(packer, [{width,W},{height,H}]),
            loop(Win, ClientPID, Prompt,  Transaction);
        {gs, entry,keypress,_,_} ->
            loop(Win, ClientPID, Prompt, Transaction);
        Any ->
            io:format("Discarded:~p~n",[Any]),
            loop(Win, ClientPID, Prompt, Transaction)
    end.

scroll_to_show_last_line() ->
    Size = gs:read(editor, size),
    Height = gs:read(editor, height),
    CharHeight = gs:read(editor, char_height),
    TopRow = Size - Height/CharHeight,
    if TopRow > 0 ->
	    gs:config(editor, {vscrollpos, TopRow});
       true ->
	    gs:config(editor, {vscrollpos, 0})
    end.

