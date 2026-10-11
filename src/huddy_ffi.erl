-module(huddy_ffi).

-export([now_ms/0, os_pid/0, getenv/1, atomic_write/2, read_file/1, delete_file/1,
         file_exists/1, ensure_dir/1, list_dir/1, acquire_lock/1, release_lock/1,
         lock_identity/1,
         utc_date_compact/1, rfc2822_date/1, getaddrs/1, send_email/5,
         limiter_init/0, rate_take/4, file_size/1, halt/1, rescue/1,
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

file_size(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} -> element(2, Info);
        _ -> 0
    end.

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

%% Single-instance lock: create Lock exclusively and write our identity into it:
%% "<os pid> <process start time> <boot id>" (the last two from /proc on Linux).
%% The lock is live only while that exact process is still running. A bare pid
%% would not do: after a reboot or container restart the recorded pid is often
%% reused by an unrelated process (with small, deterministic pids in a fresh VM
%% or container), and huddy would refuse to start until the lock was removed.
%% Legacy locks holding only a pid fall back to the plain /proc/<pid> check.
acquire_lock(Lock) ->
    Me = lock_identity(os_pid()),
    case file:open(Lock, [write, exclusive, raw, binary]) of
        {ok, Fd} ->
            ok = file:write(Fd, Me),
            ok = file:sync(Fd),
            ok = file:close(Fd),
            {ok, nil};
        {error, eexist} ->
            case file:read_file(Lock) of
                {ok, Other} ->
                    case lock_holder_alive(Other) of
                        {true, OtherPid} ->
                            {error, <<"another huddy process (pid ", OtherPid/binary,
                                      ") holds ", Lock/binary>>};
                        false ->
                            _ = file:delete(Lock),
                            acquire_lock(Lock)
                    end;
                {error, Reason} -> {error, reason_to_binary(Reason)}
            end;
        {error, Reason} -> {error, reason_to_binary(Reason)}
    end.

lock_identity(Pid) ->
    iolist_to_binary(lists:join(<<" ">>, [Pid, proc_start_time(Pid), boot_id()])).

lock_holder_alive(Content) ->
    Me = os_pid(),
    Fields = binary:split(string:trim(Content), [<<" ">>, <<"\n">>], [global, trim_all]),
    Alive = case Fields of
        [] -> false;
        [Me | _] -> false;
        [Pid] -> filelib:is_dir(<<"/proc/", Pid/binary>>);
        [Pid, Start | Rest] ->
            SameBoot = case Rest of
                [Boot | _] -> Boot =:= boot_id();
                [] -> true
            end,
            SameBoot andalso proc_start_time(Pid) =:= Start
    end,
    case Alive of
        true -> {true, hd(Fields)};
        false -> false
    end.

%% Field 22 of /proc/<pid>/stat (start time in clock ticks since boot), or <<>>.
proc_start_time(Pid) ->
    case file:read_file(<<"/proc/", Pid/binary, "/stat">>) of
        {ok, Stat} ->
            %% the command name (field 2) may contain spaces; skip past its ")"
            case binary:split(Stat, <<")">>, [global]) of
                [_ | _] = Parts ->
                    Fields = binary:split(lists:last(Parts), <<" ">>, [global, trim_all]),
                    case length(Fields) >= 20 of
                        true -> lists:nth(20, Fields);
                        false -> <<>>
                    end;
                _ -> <<>>
            end;
        {error, _} -> <<>>
    end.

boot_id() ->
    case file:read_file(<<"/proc/sys/kernel/random/boot_id">>) of
        {ok, Id} -> string:trim(Id);
        {error, _} -> <<>>
    end.

release_lock(Lock) ->
    _ = file:delete(Lock),
    nil.

utc_date_compact(Ms) ->
    {{Y, M, D}, _} = calendar:system_time_to_universal_time(Ms, millisecond),
    list_to_binary(io_lib:format("~4..0B~2..0B~2..0B", [Y, M, D])).

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
