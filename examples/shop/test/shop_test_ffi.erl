-module(shop_test_ffi).
-export([temp_dir/0, write_file/2, remove_dir/1]).

%% A new, empty directory.
temp_dir() ->
    Base = case os:getenv("TMPDIR") of
        false -> "/tmp";
        "" -> "/tmp";
        Dir -> Dir
    end,
    Name = io_lib:format("shop-test-~s-~b",
                         [os:getpid(), erlang:unique_integer([positive])]),
    Path = filename:join(Base, lists:flatten(Name)),
    ok = file:make_dir(Path),
    unicode:characters_to_binary(Path).

%% Writes a file, creating its directory.
write_file(Path, Text) ->
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Text),
    nil.

remove_dir(Path) ->
    _ = file:del_dir_r(Path),
    nil.
