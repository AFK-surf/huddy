-module(huddy_test_ffi).
-export([putenv/2, tmp_dir/0, write_file/2]).

putenv(Name, Value) ->
    os:putenv(binary_to_list(Name), binary_to_list(Value)),
    nil.

%% A fresh, empty directory for one test.
tmp_dir() ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; T -> T end,
    Dir = filename:join(Base, "huddy-test-" ++ integer_to_list(erlang:unique_integer([positive]))
                              ++ "-" ++ os:getpid()),
    ok = filelib:ensure_path(Dir),
    unicode:characters_to_binary(Dir).

write_file(Path, Data) ->
    ok = file:write_file(Path, Data),
    nil.
