-module(docuconf_test_ffi).
-export([shell/1, target/0]).

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
