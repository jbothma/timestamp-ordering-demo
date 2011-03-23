#!/bin/bash

#
# client:start('server@localhost').
# server:start().


gnome-terminal -t server -e 'erl -sname server@localhost -setcookie abc -run server start'
sleep 1
gnome-terminal -t client1 -e 'erl -sname client_1@localhost -setcookie abc -run client start_local'
gnome-terminal -t client2 -e 'erl -sname client_2@localhost -setcookie abc -run client start_local'
