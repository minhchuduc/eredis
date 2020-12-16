-module(eredis_tls_expire_SUITE).

%% Test framework
-export([ init_per_suite/1
        , end_per_suite/1
        , all/0
        , suite/0
        ]).
%% Test cases
-export([ t_tls_connect/1
        ]).


-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").


-define(TLS_PORT, 6380).

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

all() -> [F || {F, _A} <- module_info(exports),
               case atom_to_list(F) of
                   "t_" ++ _ -> true;
                   _         -> false
               end].

suite() -> [{timetrap, {minutes, 3}}].

%% Tests

t_tls_connect(Config) when is_list(Config) ->
    C1 = c_tls(),
    C2 = c_tls(),
    io:format(user, "Connecting with ok certs~n", []),
    ?assertEqual({ok, <<"OK">>}, eredis:q(C1, ["SET", foo, bar])),
    ?assertEqual({ok, <<"bar">>}, eredis:q(C2, ["GET", foo])),
    ?assertMatch(ok, eredis:stop(C2)),
    io:format(user, "Wait certs to expire..~n", []),
    timer:sleep(70*1000),
    io:format(user, "Connect should fail..~n", []),
    C3 = c_tls(),
    ?assertEqual({error, no_connection}, eredis:q(C3, ["GET", foo])),

    io:format(user, "Update cert files in redis..~n", []),
    Self = self(),
    Pid = spawn_link(fun() -> start_my_port(Self) end),
    receive ready -> ok after 10000 -> error(timeout) end,
    timer:sleep(1000),
    unlink(Pid),
    os:cmd("killall update-server-cert.sh"),

    io:format(user, "Access using new client..but failing~n", []),
    C4 = c_tls(),
    ?assertEqual({error, no_connection}, eredis:q(C4, ["GET", foo])),

    io:format(user, "Reload config~n", []),
    ?assertMatch({ok, _}, eredis:q(C1, ["config", "set", "tls-cert-file", "/conf/server/redis.crt"])),

    io:format(user, "Access using new client..~n", []),
    C5 = c_tls(),
    ?assertEqual({ok, <<"bar">>}, eredis:q(C5, ["GET", foo])).

start_my_port(Pid) ->
    Port = open_port(
             {spawn, "/home/bjorn/git/eredis/priv/update-server-cert.sh server"},
             [{line, 10000}, binary]),
    Pid ! ready,
    receive_infinity(Port, []).

receive_infinity(Port, Acc) ->
    receive
        {Port, {data, {eol, Line}}} ->
            ct:log("~ts", [Line]),
            io:format(user, ">~s~n", [Line]),
            receive_infinity(Port, [Line|Acc]);
        {Port, Reason={exit_status, _}} ->
            exit({shutdown, Reason})
    end.

%%
%% Helpers
%%
c_tls() ->
    c_tls([]).

c_tls(ExtraOptions) ->
    c_tls(ExtraOptions, "tls").

c_tls(ExtraOptions, CertDir) ->
    c_tls(ExtraOptions, CertDir, []).

c_tls(ExtraOptions, CertDir, ExtraTlSOptions) ->
    Dir = filename:join([code:priv_dir(eredis), "configs", CertDir]),
    Options = [{tls, [{cacertfile, filename:join([Dir, "ca.crt"])},
                      {certfile,   filename:join([Dir, "client.crt"])},
                      {keyfile,    filename:join([Dir, "client.key"])},
                      {verify,                 verify_peer},
                      {server_name_indication, "Server"}] ++ ExtraTlSOptions}],
    Res = eredis:start_link("127.0.0.1", ?TLS_PORT, Options ++ ExtraOptions),
    ?assertMatch({ok, _}, Res),
    {ok, C} = Res,
    C.
