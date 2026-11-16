-module(shop_ffi).
-export([read_file/1, exit/1]).

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

%% halt/1 flushes stdout and stderr first.
exit(Status) -> erlang:halt(Status).
