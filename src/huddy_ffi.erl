-module(huddy_ffi).

-include_lib("kernel/include/file.hrl").
-include_lib("stdlib/include/zip.hrl").

-export([now_ms/0, os_pid/0, getenv/1, atomic_write/2, read_file/1, delete_file/1,
         file_exists/1, ensure_dir/1, list_dir/1,
         zip_extract/3, zip_create/1, zip_read/2,
         zip_cache_init/0, zip_cache_get/1, zip_cache_put/3, zip_cache_delete/1,
         utc_date_compact/1, amz_date/1, rfc2822_date/1, getaddrs/1, send_email/5,
         limiter_init/0, rate_take/4, halt/1, rescue/1,
         configure_proxy/0]).

now_ms() -> erlang:system_time(millisecond).

os_pid() -> list_to_binary(os:getpid()).

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% Atomically replace Path with Data:
%%   write <Path>.tmp (same directory), fsync it, set mode 0600, rename over Path.
%% A crash at any point leaves either the old or the new complete file.
atomic_write(Path, Data) ->
    Tmp = <<Path/binary, ".tmp">>,
    Result =
        case file:open(Tmp, [write, raw, binary]) of
            {ok, Fd} ->
                R1 = file:write(Fd, Data),
                R2 = case R1 of ok -> file:sync(Fd); E1 -> E1 end,
                R3 = file:close(Fd),
                case {R2, R3} of
                    {ok, ok} ->
                        _ = file:change_mode(Tmp, 8#600),
                        file:rename(Tmp, Path);
                    {ok, E3} -> E3;
                    {E2, _} -> E2
                end;
            E0 -> E0
        end,
    case Result of
        ok -> {ok, nil};
        {error, Reason} ->
            _ = file:delete(Tmp),
            {error, reason_to_binary(Reason)}
    end.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, enoent} -> {error, <<"enoent">>};
        {error, Reason} -> {error, reason_to_binary(Reason)}
    end.

delete_file(Path) ->
    case file:delete(Path) of
        ok -> {ok, nil};
        {error, enoent} -> {ok, nil};
        {error, Reason} -> {error, reason_to_binary(Reason)}
    end.

file_exists(Path) -> filelib:is_regular(Path).

ensure_dir(Dir) ->
    case filelib:ensure_path(Dir) of
        ok -> {ok, nil};
        {error, Reason} -> {error, reason_to_binary(Reason)}
    end.

list_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} -> {ok, [unicode:characters_to_binary(N) || N <- Names]};
        {error, Reason} -> {error, reason_to_binary(Reason)}
    end.

%% The files in a zip archive held in memory, as [{Name, Data}] (directory
%% entries are left out). Refuses archives that declare more than MaxFiles
%% files or MaxBytes in total, and inflates in a separate process whose
%% memory is capped, so an archive that lies about its sizes cannot exhaust
%% the node.
zip_extract(Bin, MaxFiles, MaxBytes) ->
    try zip:list_dir(Bin) of
        {ok, Listing} ->
            Files = [{Name, Size} || #zip_file{name = Name, info = #file_info{size = Size}} <- Listing,
                                     not is_dir_entry(Name)],
            Total = lists:sum([S || {_, S} <- Files]),
            Unsafe = [N || #zip_file{name = N} <- Listing, unsafe_name(N)],
            if
                Unsafe =/= [] ->
                    {error, <<"unsafe_name:", (unicode:characters_to_binary(hd(Unsafe)))/binary>>};
                length(Files) > MaxFiles -> {error, <<"too_many_files">>};
                Total > MaxBytes -> {error, <<"too_large">>};
                true -> unzip_capped(Bin, MaxBytes)
            end;
        {error, _} -> {error, <<"not_a_zip">>}
    catch _:_ -> {error, <<"not_a_zip">>}
    end.

%% Absolute paths, ".." segments and backslashes (zip would rewrite them
%% when extracting, with a logged error; refuse them instead).
unsafe_name([$/ | _]) -> true;
unsafe_name(Name) ->
    lists:member($\\, Name) orelse lists:member("..", string:split(Name, "/", all)).

is_dir_entry([]) -> true;
is_dir_entry(Name) -> lists:last(Name) =:= $/.

unzip_capped(Bin, MaxBytes) ->
    Words = (3 * MaxBytes + byte_size(Bin)) div erlang:system_info(wordsize) + 4000000,
    Parent = self(),
    Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(
                   fun() ->
                           process_flag(max_heap_size, #{size => Words, kill => true,
                                                         error_logger => false,
                                                         include_shared_binaries => true}),
                           %% foldl hands over names exactly as stored (unzip
                           %% would quietly rewrite unsafe ones); the caller
                           %% validates them.
                           Collect = fun(Name, _Info, GetBin, Acc) -> [{Name, GetBin()} | Acc] end,
                           Result = try zip:foldl(Collect, [], {"upload.zip", Bin}) of
                                        {ok, Entries} -> {ok, lists:reverse(Entries)};
                                        {error, _} -> {error, <<"not_a_zip">>}
                                    catch _:_ -> {error, <<"not_a_zip">>}
                                    end,
                           Parent ! {Ref, Result}
                   end),
    receive
        {Ref, {ok, Entries}} ->
            erlang:demonitor(Mon, [flush]),
            Files = [{unicode:characters_to_binary(Name), Data}
                     || {Name, Data} <- Entries, not is_dir_entry(Name)],
            case lists:sum([byte_size(D) || {_, D} <- Files]) > MaxBytes of
                true -> {error, <<"too_large">>};
                false -> {ok, Files}
            end;
        {Ref, Error} ->
            erlang:demonitor(Mon, [flush]),
            Error;
        {'DOWN', Mon, process, Pid, _} -> {error, <<"too_large">>}
    after 30000 ->
            exit(Pid, kill),
            erlang:demonitor(Mon, [flush]),
            {error, <<"too_large">>}
    end.

%% One entry of a zip archive held in memory, by its name in the archive.
%% Archives are checked by zip_extract/3 before they are stored, so names
%% are safe and sizes are within limits.
zip_read(Zip, Name) ->
    try zip:unzip(Zip, [memory, {file_list, [unicode:characters_to_list(Name)]}]) of
        {ok, [{_, Data}]} -> {ok, Data};
        {ok, []} -> {error, <<"enoent">>};
        {error, Reason} -> {error, reason_to_binary(Reason)}
    catch Class:Reason -> {error, reason_to_binary({Class, Reason})}
    end.

%% A cache of recently read document zips, so that serving the images of a
%% page reads its zip from storage once. Keys are storage keys, which never
%% change content. The table belongs to a process of its own, so it outlives
%% whoever created it.
zip_cache_init() ->
    case ets:info(huddy_zip_cache) of
        undefined ->
            Parent = self(),
            spawn(fun() ->
                          ets:new(huddy_zip_cache, [named_table, public, set]),
                          Parent ! huddy_zip_cache_ready,
                          receive after infinity -> ok end
                  end),
            receive huddy_zip_cache_ready -> nil after 5000 -> nil end;
        _ -> nil
    end.

zip_cache_get(Key) ->
    try ets:lookup(huddy_zip_cache, Key) of
        [{_, Zip, _}] ->
            ets:update_element(huddy_zip_cache, Key, {3, erlang:monotonic_time()}),
            {ok, Zip};
        [] -> {error, nil}
    catch error:badarg -> {error, nil}
    end.

%% Insert, then evict the least recently used zips until the cache holds at
%% most MaxBytes.
zip_cache_put(Key, Zip, MaxBytes) ->
    try
        ets:insert(huddy_zip_cache, {Key, Zip, erlang:monotonic_time()}),
        Entries = lists:keysort(3, ets:tab2list(huddy_zip_cache)),
        Total = lists:sum([byte_size(Z) || {_, Z, _} <- Entries]),
        evict(Entries, Total, MaxBytes)
    catch error:badarg -> ok
    end,
    nil.

evict([{Key, Zip, _} | Rest], Total, Max) when Total > Max ->
    ets:delete(huddy_zip_cache, Key),
    evict(Rest, Total - byte_size(Zip), Max);
evict(_, _, _) -> ok.

zip_cache_delete(Key) ->
    try ets:delete(huddy_zip_cache, Key) catch error:badarg -> ok end,
    nil.

%% A zip archive (in memory) holding the given [{Path, Data}] files.
zip_create(Files) ->
    Entries = [{unicode:characters_to_list(Path), Data} || {Path, Data} <- Files],
    case zip:zip("document.zip", Entries, [memory]) of
        {ok, {_, Zip}} -> {ok, Zip};
        {error, Reason} -> {error, reason_to_binary(Reason)}
    end.

utc_date_compact(Ms) ->
    {{Y, M, D}, _} = calendar:system_time_to_universal_time(Ms, millisecond),
    list_to_binary(io_lib:format("~4..0B~2..0B~2..0B", [Y, M, D])).

%% ISO 8601 basic format, as AWS Signature Version 4 wants: 20130524T000000Z.
amz_date(Ms) ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Ms, millisecond),
    list_to_binary(io_lib:format("~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0BZ", [Y, Mo, D, H, Mi, S])).

rfc2822_date(Ms) ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Ms, millisecond),
    Day = element(calendar:day_of_the_week(Y, Mo, D),
                  {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}),
    Mon = element(Mo, {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug",
                       "Sep", "Oct", "Nov", "Dec"}),
    list_to_binary(io_lib:format("~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B +0000",
                                 [Day, D, Mon, Y, H, Mi, S])).

%% Resolve a host name to all its IPv4 and IPv6 addresses, as lists of integers.
getaddrs(Host) ->
    H = binary_to_list(Host),
    V4 = case inet:getaddrs(H, inet) of {ok, A} -> A; _ -> [] end,
    V6 = case inet:getaddrs(H, inet6) of {ok, B} -> B; _ -> [] end,
    case V4 ++ V6 of
        [] -> {error, nil};
        All -> {ok, [tuple_to_list(T) || T <- All]}
    end.

%% Send a plain-text mail through SMTP using gen_smtp.
%% Opts is a map: host, port, username, password, tls (<<"starttls">> | <<"tls">> | <<"none">>).
send_email(Opts, From, To, Subject, Body) ->
    Host = binary_to_list(maps:get(host, Opts)),
    Tls = maps:get(tls, Opts),
    TlsOptions = [{verify, verify_peer},
                  %% gen_smtp defaults to {depth, 0}, which rejects any chain
                  %% with an intermediate CA (i.e. nearly every public server).
                  {depth, 10},
                  {cacerts, public_key:cacerts_get()},
                  {server_name_indication, Host},
                  {customize_hostname_check,
                   [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
    Auth = case maps:get(username, Opts) of
               <<>> -> [{auth, never}];
               User -> [{auth, always}, {username, binary_to_list(User)},
                        {password, binary_to_list(maps:get(password, Opts))}]
           end,
    TlsMode = case Tls of
                  <<"tls">> -> [{ssl, true}, {sockopts, TlsOptions}];
                  <<"none">> -> [{tls, never}];
                  _ -> [{tls, always}, {tls_options, TlsOptions}]
              end,
    Options = [{relay, Host}, {port, maps:get(port, Opts)}, {retries, 1}] ++ Auth ++ TlsMode,
    Message = iolist_to_binary([
        <<"From: ">>, From, <<"\r\n">>,
        <<"To: ">>, To, <<"\r\n">>,
        <<"Subject: ">>, encode_header(Subject), <<"\r\n">>,
        <<"Date: ">>, rfc2822_date(now_ms()), <<"\r\n">>,
        <<"Message-ID: <">>, integer_to_binary(erlang:unique_integer([positive])), <<".">>,
        integer_to_binary(now_ms()), <<"@huddy>\r\n">>,
        <<"MIME-Version: 1.0\r\n">>,
        <<"Content-Type: text/plain; charset=utf-8\r\n">>,
        <<"Content-Transfer-Encoding: 8bit\r\n\r\n">>,
        binary:replace(Body, <<"\n">>, <<"\r\n">>, [global])
    ]),
    Envelope = {extract_address(From), [extract_address(To)], Message},
    try gen_smtp_client:send_blocking(Envelope, Options) of
        Receipt when is_binary(Receipt) -> {ok, nil};
        {error, Type, Detail} -> {error, reason_to_binary({Type, Detail})};
        {error, Reason} -> {error, reason_to_binary(Reason)}
    catch
        Class:Err -> {error, reason_to_binary({Class, Err})}
    end.

encode_header(S) ->
    case lists:all(fun(C) -> C >= 32 andalso C < 127 end, binary_to_list(S)) of
        true -> S;
        false -> <<"=?UTF-8?B?", (base64:encode(S))/binary, "?=">>
    end.

extract_address(S) ->
    case binary:match(S, <<"<">>) of
        nomatch -> S;
        {Start, _} ->
            Rest = binary:part(S, Start + 1, byte_size(S) - Start - 1),
            hd(binary:split(Rest, <<">">>))
    end.

%% Token-bucket rate limiter in a public ETS table owned by the caller of limiter_init/0.
limiter_init() ->
    case ets:info(huddy_limiter) of
        undefined -> ets:new(huddy_limiter, [named_table, public, set]), nil;
        _ -> nil
    end.

rate_take(Key, Capacity, RefillPerMs, Now) ->
    {Tokens0, Last} = case ets:lookup(huddy_limiter, Key) of
                          [{_, T, L}] -> {T, L};
                          [] -> {float(Capacity), Now}
                      end,
    Tokens = min(float(Capacity), Tokens0 + (Now - Last) * RefillPerMs),
    case Tokens >= 1.0 of
        true -> ets:insert(huddy_limiter, {Key, Tokens - 1.0, Now}), true;
        false -> ets:insert(huddy_limiter, {Key, Tokens, Now}), false
    end.

halt(Code) -> erlang:halt(Code).

%% Erlang's httpc ignores HTTPS_PROXY; honour it (and NO_PROXY) for the
%% default httpc profile used by gleam_httpc. Returns the proxy used, if any.
configure_proxy() ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    Proxy = first_env(["HTTPS_PROXY", "https_proxy"]),
    case Proxy =/= false andalso uri_string:parse(Proxy) of
        #{host := Host, port := Port} ->
            NoProxy = no_proxy_list(first_env(["NO_PROXY", "no_proxy"])),
            ok = httpc:set_options([{https_proxy, {{Host, Port}, NoProxy}},
                                    {proxy, {{Host, Port}, NoProxy}}]),
            {ok, unicode:characters_to_binary(Host ++ ":" ++ integer_to_list(Port))};
        _ -> {error, nil}
    end.

first_env([]) -> false;
first_env([Name | Rest]) ->
    case os:getenv(Name) of
        false -> first_env(Rest);
        "" -> first_env(Rest);
        Value -> Value
    end.

%% httpc understands host names, "*.domain" wildcards and IP addresses, but
%% not CIDR ranges; translate ".domain" and drop the rest.
no_proxy_list(false) -> ["localhost", "127.0.0.1"];
no_proxy_list(Value) ->
    Entries = [string:trim(E) || E <- string:split(Value, ",", all)],
    Hosts = lists:filtermap(
              fun("") -> false;
                 ([$. | Domain]) -> {true, "*." ++ Domain};
                 (E) -> case lists:member($/, E) of
                            true -> false;
                            false -> {true, E}
                        end
              end, Entries),
    lists:usort(["localhost", "127.0.0.1" | Hosts]).

%% Run F, turning any exception into {error, Description}.
rescue(F) ->
    try {ok, F()}
    catch Class:Reason -> {error, reason_to_binary({Class, Reason})}
    end.

reason_to_binary(Reason) when is_binary(Reason) -> Reason;
reason_to_binary(Reason) when is_atom(Reason) -> atom_to_binary(Reason);
reason_to_binary(Reason) -> unicode:characters_to_binary(io_lib:format("~0p", [Reason])).
