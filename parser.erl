%% - Parser module
%% - Simple module to parse user commands:
%%
%% Parser part:
%% The parser acceptes the following grammar:
%%               read name | write name value | write name | run | reset
%% (write name will write 0 by default)
%%
%% Lexer part:
%% The language is as follows: {read, write, run, reset, name, value},
%% where a name can be {a, b, c, d} and a value is any integer.
%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% IMPORTANT!! DO NOT MODIFY THIS FILE
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


-module(parser).

-export([parse/1]).

%% main function
parse(Str) -> 
    case parse_expression(skip_to_prompt(Str),{}) of
	{error, Why} -> throw(Why);
	Com -> Com
    end.

%% function to parse expression
parse_expression(T,{}) ->
    case get_token(T) of 
	{token_action, Action, Tail} -> parse_expression(Tail,{Action});
	_ -> {error, "Expected read, write, run or reset command"}
    end;
parse_expression(T,{run}) ->
    case get_token(T) of 
	{token_end} -> {run};
	_ -> {error, "Command run takes no argument"}
    end;
parse_expression(T,{reset}) ->
    case get_token(T) of 
	{token_end} -> {reset};
	_ -> {error, "Command reset takes no argument"}
    end;
parse_expression(T,{Action}) ->
    case get_token(T) of 
	{token_name, Name, Tail} -> parse_expression(Tail, {Action, Name});
	_ -> {error, "Expected variable name {a,b,c,d}"}
    end;
parse_expression(T,{read, Name}) -> 
    case get_token(T) of 
	{token_end} -> {read,Name};
	_ -> {error, "Wrong number of arguments"}
    end;
parse_expression(T,{write, Name}) ->
    case get_token(T) of 
	{token_end} -> {write,Name,0};
	{token_value, Val, Tail} -> parse_expression(Tail, {write,Name,Val});
	_ -> {error, "Expected number"}
    end;
parse_expression(T,{write,Name,Val}) ->
    case get_token(T) of
	{token_end} -> {write,Name,Val};
	_ -> {error, "Wrong number of arguments"}
    end. 

%% function to read the tokens
get_token(" " ++ T) -> get_token(T);
get_token([]) -> {token_end};
get_token("read " ++ T) -> {token_action, read, T};
get_token("write " ++ T) -> {token_action, write, T};
get_token("run" ++ T) -> {token_action, run, T};
get_token("reset" ++ T) -> {token_action, reset, T};
get_token("a" ++ T) -> {token_name, a, T};
get_token("b" ++ T) -> {token_name, b, T};
get_token("c" ++ T) -> {token_name, c, T};
get_token("d" ++ T) -> {token_name, d, T};
get_token(T) -> read_number(0,T).

read_number(Val, []) -> {token_value, Val, []};
read_number(Val, " " ++ T) -> {token_value, Val, T};
read_number(Val,[H|T]) ->
    if (H < 48) or (H > 57) -> {error, "Unknown entry"};
    true -> read_number(Val*10+H-48,T)
    end.

%% Low level function which removes the front characters up-to a the prompt
skip_to_prompt(">" ++ T) -> T;
skip_to_prompt([_|T]) -> skip_to_prompt(T);
skip_to_prompt([]) -> [].
