-module(docuconf_test_ffi).
-export([shell/1, target/0, read_file/1, remember/1, recall/0]).

target() -> <<"erlang">>.

%% Runs a shell command; returns {ExitStatus, Output}.
shell(Cmd) ->
    Out = os:cmd(binary_to_list(<<Cmd/binary, "\necho \"__exit=$?\"">>)),
    Bin = unicode:characters_to_binary(Out),
    case binary:split(Bin, <<"__exit=">>, [global]) of
        [Before, Code] ->
            {binary_to_integer(string:trim(Code)), Before};
        _ ->
            {-1, Bin}
    end.

%% Reads a file as UTF-8 text.
read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, _} -> {error, nil}
    end.

%% A list of strings kept in the process dictionary, for callbacks.
remember(S) ->
    put(docuconf_remembered, [S | recall_raw()]),
    nil.

recall() ->
    L = lists:reverse(recall_raw()),
    erase(docuconf_remembered),
    L.

recall_raw() ->
    case get(docuconf_remembered) of
        undefined -> [];
        L -> L
    end.
