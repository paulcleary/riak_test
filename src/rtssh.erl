-module(rtssh).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").

get_version() ->
    unknown.

get_deps() ->
    Path = relpath(current),
    case filelib:is_dir(Path) of
        true ->
            lists:flatten(io_lib:format("~s/dev/dev1/lib", [Path]));
        false ->
            case rt_config:get(rt_deps, undefined) of
                undefined ->
                    throw("Unable to determine Riak library path");
                _ ->
                    ok
            end,
            ""
    end.

setup_harness(_Test, _Args) ->
    Path = relpath(root),
    Hosts = load_hosts(),
    rt_config:set(rt_hostnames, Hosts),
    %% [io:format("R: ~p~n", [wildcard(Host, "/tmp/*")]) || Host <- Hosts],

    %% Stop all discoverable nodes, not just nodes we'll be using for this test.
    stop_all(Hosts),

    %% Reset nodes to base state
    lager:info("Resetting nodes to fresh state"),
    rt:pmap(fun(Host) ->
                    run_git(Host, Path, "reset HEAD --hard"),
                    run_git(Host, Path, "clean -fd")
            end, Hosts),
    ok.

get_backends() ->
    Hosts = rt_config:get(rtssh_hosts),
    All = [{Host, DevPath} || Host <- Hosts,
                              DevPath <- devpaths()],
    Backends = rt:pmap(fun({Host, DevPath}) ->
                    AllFiles = all_the_files(Host, DevPath, "etc/*.config"),
                    [get_backend(Host, File) || File <- AllFiles]
            end, All),
    lists:usort(lists:flatten(Backends)).

get_backend(Host, AppConfig) ->
    lager:info("get_backend(~s)", [AppConfig]),
    Tokens = lists:reverse(filename:split(AppConfig)),
    Node = host_to_node(Host),
    ConfigFile = case Tokens of
        ["app.config"| _ ] ->
            AppConfig;
        ["advanced.config" | T] ->
            ["etc", [$d, $e, $v | N], "dev" | RPath] = T,
            Path = filename:join(lists:reverse(RPath)),
            %% Why chkconfig? It generates an app.config from cuttlefish
            %% without starting riak.
            {0, Output} = run_riak(Path ++ "/dev/dev" ++ N, Node, "chkconfig"),
            ChkConfigOutput = string:tokens(Output, "\n"),

            ConfigFileOutputLine = lists:last(ChkConfigOutput),

            %% ConfigFileOutputLine looks like this:
            %% -config /path/to/app.config -args_file /path/to/vm.args -vm_args /path/to/vm.args
            Files =[ Filename || Filename <- string:tokens(ConfigFileOutputLine, "\s"),
                                 ".config" == filename:extension(Filename) ],

            case Files of
                [] -> %% No file generated by chkconfig. this isn't great
                    lager:error("Cuttlefish Failure."),
                    lager:info("chkconfig:"),
                    [ lager:info("~s", [Line]) || Line <- ChkConfigOutput ],
                    ?assert(false);
                _ ->
                    File = hd(Files),
                    case filename:pathtype(Files) of
                        absolute -> File;
                        relative ->
                            io_lib:format("~s/dev/dev~s/~s", [Path, N, tl(hd(Files))])
                    end
                end
    end,
    Bin = remote_read_file(Node, ConfigFile),
    Str = binary_to_list(Bin),
    {ok, ErlTok, _} = erl_scan:string(Str),
    {ok, Term} = erl_parse:parse_term(ErlTok),
    rt_backend:get_backend(Term).

cmd(Cmd) ->
    cmd(Cmd, []).

cmd(Cmd, Opts) ->
    wait_for_cmd(spawn_cmd(Cmd, Opts)).

deploy_nodes(NodeConfig) ->
    Hosts = rt_config:get(rtssh_hosts),
    NumNodes = length(NodeConfig),
    NumHosts = length(Hosts),
    case NumNodes > NumHosts of
        true ->
            erlang:error("Not enough hosts available to deploy nodes",
                         [NumNodes, NumHosts]);
        false ->
            Hosts2 = lists:sublist(Hosts, NumNodes),
            deploy_nodes(NodeConfig, Hosts2)
    end.

host_to_node(Host) ->
    list_to_atom("riak@" ++ Host).

node_to_host(Node) ->
    case string:tokens(atom_to_list(Node), "@") of
        ["riak", Host] -> Host;
        _ ->
            throw(io_lib:format("rtssh:node_to_host couldn't figure out the host of ~p", [Node]))
    end.

deploy_nodes(NodeConfig, Hosts) ->
    Path = relpath(root),
    lager:info("Riak path: ~p", [Path]),
    %% NumNodes = length(NodeConfig),
    %% NodesN = lists:seq(1, NumNodes),
    %% Nodes = [?DEV(N) || N <- NodesN],
    Nodes = [host_to_node(Host) || Host <- Hosts],
    HostMap = lists:zip(Nodes, Hosts),

    %% NodeMap = orddict:from_list(lists:zip(Nodes, NodesN)),
    %% TODO: Add code to set initial app.config
    {Versions, Configs} = lists:unzip(NodeConfig),
    VersionMap = lists:zip(Nodes, Versions),

    rt_config:set(rt_hosts,
        orddict:from_list(
            orddict:to_list(rt_config:get(rt_hosts, orddict:new())) ++ HostMap)),
    rt_config:set(rt_versions,
        orddict:from_list(
            orddict:to_list(rt_config:get(rt_versions, orddict:new())) ++ VersionMap)),

    rt:pmap(fun({_, default}) ->
                    ok;
               ({Node, {cuttlefish, Config}}) ->
                    set_conf(Node, Config);
               ({Node, Config}) ->
                    update_app_config(Node, Config)
            end,
            lists:zip(Nodes, Configs)),
    timer:sleep(500),

    case rt_config:get(cuttle, true) of
        false ->
            rt:pmap(fun(Node) ->
                            Host = get_host(Node),
                            %%lager:info("ports ~p", [self()]),
                            Config = [{riak_api,
                                       [{pb, fun([{_, Port}]) ->
                                                     [{Host, Port}]
                                             end},
                                        {pb_ip, fun(_) ->
                                                        Host
                                                end}]},
                                      {riak_core,
                                       [{http, fun([{_, Port}]) ->
                                                       [{Host, Port}]
                                               end}]}],
                            update_app_config(Node, Config)
                    end, Nodes),

            timer:sleep(500),

            rt:pmap(fun(Node) ->
                            update_vm_args(Node,
                                           [{"-name", Node},
                                            {"-zddbl", "65535"},
                                            {"-P", "256000"}])
                    end, Nodes),

            timer:sleep(500);
        true ->
            rt:pmap(fun(Node) ->
                            IP = get_ip(Node),
                            set_conf(Node,
                                     [{"listener.protobuf.internal",
                                       IP ++ ":10017"},
                                      {"listener.http.internal",
                                       IP ++ ":10018"}])
                    end, Nodes),
            timer:sleep(500)
    end,

    create_dirs(Nodes),

    rt:pmap(fun start/1, Nodes),

    %% Ensure nodes started
    [ok = rt:wait_until_pingable(N) || N <- Nodes],

    %% %% Enable debug logging
    %% [rpc:call(N, lager, set_loglevel, [lager_console_backend, debug]) || N <- Nodes],

    %% We have to make sure that riak_core_ring_manager is running before we can go on.
    [ok = rt:wait_until_registered(N, riak_core_ring_manager) || N <- Nodes],

    %% Ensure nodes are singleton clusters
    [ok = rt:check_singleton_node(N) || {N, Version} <- VersionMap,
                                        Version /= "0.14.2"],

    Nodes.

deploy_clusters(ClusterConfigs) ->
    Clusters = rt_config:get(rtssh_clusters, []),
    NumConfig = length(ClusterConfigs),
    case length(Clusters) < NumConfig of
        true ->
            erlang:error("Requested more clusters than available");
        false ->
            Both = lists:zip(lists:sublist(Clusters, NumConfig), ClusterConfigs),
            Deploy =
                [begin
                     NumNodes = length(NodeConfig),
                     NumHosts = length(Hosts),
                     case NumNodes > NumHosts of
                         true ->
                             erlang:error("Not enough hosts available to deploy nodes",
                                          [NumNodes, NumHosts]);
                         false ->
                             Hosts2 = lists:sublist(Hosts, NumNodes),
                             {Hosts2, NodeConfig}
                     end
                 end || {{_,Hosts}, NodeConfig} <- Both],
            [deploy_nodes(NodeConfig, Hosts) || {Hosts, NodeConfig} <- Deploy]
    end.

create_dirs(Nodes) ->
    [ssh_cmd(Node, "mkdir -p " ++ node_path(Node) ++ "/data/snmp/agent/db")
     || Node <- Nodes].

clean_data_dir(Nodes, SubDir) when is_list(Nodes) ->
    [ssh_cmd(Node, "rm -rf " ++ node_path(Node) ++ "/data/" ++ SubDir)
     || Node <- Nodes].

start(Node) ->
    run_riak(Node, "start"),
    ok.

stop(Node) ->
    run_riak(Node, "stop"),
    ok.

upgrade(Node, NewVersion) ->
    upgrade(Node, NewVersion, same).

upgrade(Node, NewVersion, Config) ->
    Version = node_version(Node),
    lager:info("Upgrading ~p : ~p -> ~p", [Node, Version, NewVersion]),
    stop(Node),
    rt:wait_until_unpingable(Node),
    OldPath = node_path(Node, Version),
    NewPath = node_path(Node, NewVersion),

    Commands = [
        io_lib:format("cp -p -P -R \"~s/data\" \"~s\"",
                       [OldPath, NewPath]),
        io_lib:format("rm -rf ~s/data/*",
                       [OldPath]),
        io_lib:format("cp -p -P -R \"~s/etc\" \"~s\"",
                       [OldPath, NewPath])
    ],
    [remote_cmd(Node, Cmd) || Cmd <- Commands],
    VersionMap = orddict:store(Node, NewVersion, rt_config:get(rt_versions)),
    rt_config:set(rt_versions, VersionMap),
    case Config of
        same -> ok;
        _ -> update_app_config(Node, Config)
    end,
    start(Node),
    rt:wait_until_pingable(Node),
    ok.

run_riak(Node, Cmd) ->
    Exec = riakcmd(Node, Cmd),
    lager:info("Running: ~s :: ~s", [get_host(Node), Exec]),
    ssh_cmd(Node, Exec).

run_riak(Path, Node, Cmd) ->
    Exec = Path ++ "/bin/riak " ++ Cmd,
    lager:info("Running: ~s :: ~s", [get_host(Node), Exec]),
    ssh_cmd(Node, Exec).

run_git(Host, Path, Cmd) ->
    Exec = gitcmd(Path, Cmd),
    lager:info("Running: ~s :: ~s", [Host, Exec]),
    ssh_cmd(Host, Exec).

remote_cmd(Node, Cmd) ->
    lager:info("Running: ~s :: ~s", [get_host(Node), Cmd]),
    {0, Result} = ssh_cmd(Node, Cmd),
    {ok, Result}.

admin(Node, Args) ->
    Cmd = riak_admin_cmd(Node, Args),
    lager:info("Running: ~s :: ~s", [get_host(Node), Cmd]),
    {0, Result} = ssh_cmd(Node, Cmd),
    lager:info("~s", [Result]),
    {ok, Result}.

admin(Node, Args, Options) ->
    Cmd = riak_admin_cmd(Node, Args),
    lager:info("Running: ~s :: ~s", [get_host(Node), Cmd]),
    Result = execute_admin_cmd(Node, Cmd, Options),
    lager:info("~s", [Result]),
    {ok, Result}.

execute_admin_cmd(Node, Cmd, Options) ->
    {_ExitCode, Result} = FullResult = ssh_cmd(Node, Cmd),
    case lists:member(return_exit_code, Options) of
        true ->
            FullResult;
        false ->
            Result
    end.

riak(Node, Args) ->
    Result = run_riak(Node, Args),
    lager:info("~s", [Result]),
    {ok, Result}.

riakcmd(Node, Cmd) ->
    node_path(Node) ++ "/bin/riak " ++ Cmd.

gitcmd(Path, Cmd) ->
    io_lib:format("git --git-dir=\"~s/.git\" --work-tree=\"~s/\" ~s",
                  [Path, Path, Cmd]).

riak_admin_cmd(Node, Args) ->
    Quoted =
        lists:map(fun(Arg) when is_list(Arg) ->
                          lists:flatten([$", Arg, $"]);
                     (_) ->
                          erlang:error(badarg)
                  end, Args),
    ArgStr = string:join(Quoted, " "),
    node_path(Node) ++ "/bin/riak-admin " ++ ArgStr.

load_hosts() ->
    {HostsIn, Aliases} = read_hosts_file("hosts"),
    Hosts = lists:sort(HostsIn),
    rt_config:set(rtssh_hosts, Hosts),
    rt_config:set(rtssh_aliases, Aliases),
    Hosts.

read_hosts_file(File) ->
    case file:consult(File) of
        {ok, Terms} ->
            Terms2 = maybe_clusters(Terms),
            lists:mapfoldl(fun({Alias, Host}, Aliases) ->
                                   Aliases2 = orddict:store(Host, Host, Aliases),
                                   Aliases3 = orddict:store(Alias, Host, Aliases2),
                                   {Host, Aliases3};
                              (Host, Aliases) ->
                                   Aliases2 = orddict:store(Host, Host, Aliases),
                                   {Host, Aliases2}
                           end, orddict:new(), Terms2);
        _ ->
            erlang:error({"Missing or invalid rtssh hosts file", file:get_cwd()})
    end.

maybe_clusters(Terms=[L|_]) when is_list(L) ->
    Labels = lists:seq(1, length(Terms)),
    Hosts = [[case Host of
                  {H, _} ->
                      H;
                  H ->
                      H
              end || Host <- Hosts] || Hosts <- Terms],
    Clusters = lists:zip(Labels, Hosts),
    rt_config:set(rtssh_clusters, Clusters),
    lists:append(Terms);
maybe_clusters(Terms) ->
    Terms.

get_host(Node) when is_atom(Node) ->
    try orddict:fetch(Node, rt_config:get(rt_hosts)) of
        Host -> Host
    catch _:_ ->
        %% Let's try figuring this out from the node name
        node_to_host(Node)
    end;
get_host(Host) -> Host.

get_ip(Node) when is_atom(Node) ->
    get_ip(get_host(Node));
get_ip(Host) ->
    {ok, IP} = inet:getaddr(Host, inet),
    string:join([integer_to_list(X) || X <- tuple_to_list(IP)], ".").

%%%===================================================================
%%% Remote file operations
%%%===================================================================

wildcard(Node, Path) ->
    Cmd = "find " ++ Path ++ " -maxdepth 0 -print",
    case ssh_cmd(Node, Cmd) of
        {0, Result} ->
            string:tokens(Result, "\n");
        _ ->
            error
    end.

spawn_ssh_cmd(Node, Cmd) ->
    spawn_ssh_cmd(Node, Cmd, []).
spawn_ssh_cmd(Node, Cmd, Opts) when is_atom(Node) ->
    Host = get_host(Node),
    spawn_ssh_cmd(Host, Cmd, Opts, true);
spawn_ssh_cmd(Host, Cmd, Opts) ->
    spawn_ssh_cmd(Host, Cmd, Opts, true).

spawn_ssh_cmd(Node, Cmd, Opts, Return) when is_atom(Node) ->
    Host = get_host(Node),
    spawn_ssh_cmd(Host, Cmd, Opts, Return);
spawn_ssh_cmd(Host, Cmd, Opts, Return) ->
    Quiet =
    case Return of
        true -> "";
        false -> " > /dev/null 2>&1"
    end,
    SSHCmd = format("ssh -q -o 'StrictHostKeyChecking no' ~s '~s'"++Quiet,
            [Host, Cmd]),
    spawn_cmd(SSHCmd, Opts).

ssh_cmd(Node, Cmd) ->
    ssh_cmd(Node, Cmd, true).

ssh_cmd(Node, Cmd, Return) ->
    case rt_config:get(rtssh_verbose, false) of
        true ->
            lager:info("Running: ~s :: ~s", [Node, Cmd]);
        false -> ok
    end,
    wait_for_cmd(spawn_ssh_cmd(Node, Cmd, [stderr_to_stdout], Return)).

remote_read_file(Node, File) ->
    timer:sleep(500),
    case ssh_cmd(Node, "cat " ++ File) of
        {0, Text} ->
            %% io:format("~p/~p: read: ~p~n", [Node, File, Text]),

            %% Note: remote_read_file sometimes returns "" for some
            %% reason, however printing out to debug things (as in the
            %% above io:format) makes error go away. Going to assume
            %% race condition and throw in timer:sleep here.
            %% TODO: debug for real.
            timer:sleep(500),
            list_to_binary(Text);
        Error ->
            erlang:error("Failed to read remote file", [Node, File, Error])
    end.

remote_write_file(NodeOrHost, File, Data) ->
    Port = spawn_ssh_cmd(NodeOrHost, "cat > " ++ File, [out]),
    true = port_command(Port, Data),
    true = port_close(Port),
    ok.

format(Msg, Args) ->
    lists:flatten(io_lib:format(Msg, Args)).

update_nodename(Node) ->
    Etc = node_path(Node) ++ "/etc/",
    Files = [filename:basename(File) || File <- wildcard(Node, Etc ++ "*")],
    RiakConfExists = lists:member("riak.conf", Files),
    VMArgsExists = lists:member("vm.args", Files),
    case {RiakConfExists, VMArgsExists} of
        {_, true} ->
            do_update_vm_args(Node, [{"-name", Node}]);
        {true, _} ->
            set_conf(Node, [{"nodename", atom_to_list(Node)}])
    end,
    ok.

update_vm_args(_Node, []) ->
    ok;
update_vm_args(Node, Props) ->
    Etc = node_path(Node) ++ "/etc/",
    Files = [filename:basename(File) || File <- wildcard(Node, Etc ++ "*")],
    VMArgsExists = lists:member("vm.args", Files),
    AdvExists = lists:member("advanced.config", Files),
    if VMArgsExists ->
            do_update_vm_args(Node, Props);
       AdvExists ->
            update_app_config_file(Node, Etc ++ "advanced.config",
                                   [{vm_args, Props}], undefined);
       true ->
            update_app_config_file(Node, Etc ++ "advanced.config",
                                   [{vm_args, Props}], [])
    end.

do_update_vm_args(Node, Props) ->
    %% TODO: Make non-matched options be appended to file
    VMArgs = node_path(Node) ++ "/etc/vm.args",
    Bin = remote_read_file(Node, VMArgs),
    Output =
        lists:foldl(fun({Config, Value}, Acc) ->
                            CBin = to_binary(Config),
                            VBin = to_binary(Value),
                            case re:replace(Acc,
                                            <<"((^|\\n)", CBin/binary, ").+\\n">>,
                                            <<"\\1 ", VBin/binary, $\n>>) of
                                CBin -> <<CBin/binary, VBin/binary, $\n>>;
                                Mod -> Mod
                            end
                    end, Bin, Props),
    %% io:format("~p~n", [iolist_to_binary(Output)]),
    remote_write_file(Node, VMArgs, Output),
    ok.

update_app_config(all, Config) ->
    lager:info("rtdev:update_app_config(all, ~p)", [Config]),
    [ begin
        Paths = wildcard(Host, proplists:get_value(root, rt_config:get(rtdev_path)) ++ "/*/dev/dev*"),
        [ update_app_config(host_to_node(Host), Path, Config) || Path <- Paths ]
    end|| Host <- rt_config:get(rtssh_hosts)];
update_app_config(Node, Config) ->
    update_app_config(Node, node_path(Node), Config).

update_app_config(Node, Path, Config) ->
    Etc = Path ++ "/etc/",
    Files = [filename:basename(File) || File <- wildcard(Node, Etc ++ "*")],
    AppExists = lists:member("app.config", Files),
    AdvExists = lists:member("advanced.config", Files),
    if AppExists ->
            update_app_config_file(Node, Etc ++ "app.config", Config, undefined);
       AdvExists ->
            update_app_config_file(Node, Etc ++ "advanced.config", Config, undefined);
       true ->
            update_app_config_file(Node, Etc ++ "advanced.config", Config, [])
    end.
    %% ConfigFile = node_path(Node) ++ "/etc/app.config",
    %% update_app_config_file(Node, ConfigFile, Config).

update_app_config_file(Node, ConfigFile, Config, Current) ->
    lager:info("rtssh:update_app_config_file(~p, ~s, ~p)",
               [Node, ConfigFile, Config]),
    BaseConfig = current_config(Node, ConfigFile, Current),

    MergeA = orddict:from_list(Config),
    MergeB = orddict:from_list(BaseConfig),
    NewConfig =
        orddict:merge(fun(_, VarsA, VarsB) ->
                              MergeC = orddict:from_list(VarsA),
                              MergeD = orddict:from_list(VarsB),
                              Props =
                                  orddict:merge(fun(_, Fun, ValB) when is_function(Fun) ->
                                                        Fun(ValB);
                                                   (_, ValA, _ValB) ->
                                                        ValA
                                                end, MergeC, MergeD),
                              [{K,V} || {K,V} <- Props,
                                        not is_function(V)]
                      end, MergeA, MergeB),
    NewConfigOut = io_lib:format("~p.", [NewConfig]),
    ?assertEqual(ok, remote_write_file(Node, ConfigFile, NewConfigOut)),
    ok.

current_config(Node, ConfigFile, undefined) ->
    Bin = remote_read_file(Node, ConfigFile),
    try
        {ok, BC} = consult_string(Bin),
        BC
    catch
        _:_ ->
            erlang:error({"Failed to parse app.config for", Node, Bin})
    end;
current_config(_Node, _ConfigFile, Current) ->
    Current.

consult_string(Bin) when is_binary(Bin) ->
    consult_string(binary_to_list(Bin));
consult_string(Str) ->
    {ok, Tokens, _} = erl_scan:string(Str),
    erl_parse:parse_term(Tokens).

-spec set_conf(atom(), [{string(), string()}]) -> ok.
set_conf(all, NameValuePairs) ->
    lager:info("rtssh:set_conf(all, ~p)", [NameValuePairs]),
    Hosts = rt_config:get(rtssh_hosts),
    All = [{Host, DevPath} || Host <- Hosts,
                              DevPath <- devpaths()],
    rt:pmap(fun({Host, DevPath}) ->
                    AllFiles = all_the_files(Host, DevPath, "etc/riak.conf"),
                    [append_to_conf_file(Host, File, NameValuePairs) || File <- AllFiles],
                    ok
            end, All),
    ok;
set_conf(Node, NameValuePairs) when is_atom(Node) ->
    append_to_conf_file(Node, get_riak_conf(Node), NameValuePairs),
    ok.

set_advanced_conf(all, NameValuePairs) ->
    lager:debug("rtssh:set_advanced_conf(all, ~p)", [NameValuePairs]),
    Hosts = rt_config:get(rtssh_hosts),
    All = [{Host, DevPath} || Host <- Hosts,
                              DevPath <- devpaths()],
    rt:pmap(fun({Host, DevPath}) ->
                    AllFiles = all_the_files(Host, DevPath, "etc/advanced.config"),
                    [update_app_config_file(Host, File, NameValuePairs, undefined) || File <- AllFiles],
                    ok
            end, All),
    ok;
set_advanced_conf(Node, NameValuePairs) when is_atom(Node) ->
    append_to_conf_file(Node, get_advanced_riak_conf(Node), NameValuePairs),
    ok.

get_riak_conf(Node) ->
    node_path(Node) ++ "/etc/riak.conf".

get_advanced_riak_conf(Node) ->
    node_path(Node) ++ "/etc/advanced.config".

append_to_conf_file(Node, File, NameValuePairs) ->
    Current = remote_read_file(Node, File),
    Settings = [[$\n, to_list(Name), $=, to_list(Val), $\n] || {Name, Val} <- NameValuePairs],
    Output = iolist_to_binary([Current, Settings]),
    remote_write_file(Node, File, Output).

all_the_files(Host, DevPath, File) ->
    case wildcard(Host, DevPath ++ "/dev/dev*/" ++ File) of
        error ->
            lager:info("~s is not a directory.", [DevPath]),
            [];
        Files ->
            io:format("~s :: files: ~p~n", [Host, Files]),
            Files
    end.

scp_to(Host, Path, RemotePath) ->
    ssh_cmd(Host, "mkdir -p "++RemotePath),
    SCP = format("scp -qr -o 'StrictHostKeyChecking no' ~s ~s:~s",
                 [Path, Host, RemotePath]),
    wait_for_cmd(spawn_cmd(SCP)).

scp_from(Host, RemotePath, Path) ->
    ssh_cmd(Host, "mkdir -p "++RemotePath),
    SCP = format("scp -qr -o 'StrictHostKeyChecking no' ~s:~s ~s",
                 [Host, RemotePath, Path]),
    wait_for_cmd(spawn_cmd(SCP)).

%%%===================================================================
%%% Riak devrel path utilities
%%%===================================================================

-define(PATH, (rt_config:get(rtdev_path))).

dev_path(Path, N) ->
    format("~s/dev/dev~b", [Path, N]).

dev_bin_path(Path, N) ->
    dev_path(Path, N) ++ "/bin".

dev_etc_path(Path, N) ->
    dev_path(Path, N) ++ "/etc".

dev_data_path(Path, N) ->
    dev_path(Path, N) ++ "/data".

relpath(Vsn) ->
    Path = ?PATH,
    relpath(Vsn, Path).

relpath(Vsn, Paths=[{_,_}|_]) ->
    orddict:fetch(Vsn, orddict:from_list(Paths));
relpath(current, Path) ->
    Path;
relpath(root, Path) ->
    Path;
relpath(_, _) ->
    throw("Version requested but only one path provided").

node_path(Node) when is_atom(Node) ->
    node_path(Node, node_version(Node)).

node_path(Node, Version) ->
    N = node_id(Node),
    Path = relpath(Version),
    lists:flatten(io_lib:format("~s/dev/dev~b", [Path, N])).

node_id(_Node) ->
    %% NodeMap = rt_config:get(rt_nodes),
    %% orddict:fetch(Node, NodeMap).
    1.

node_version(Node) ->
    orddict:fetch(Node, rt_config:get(rt_versions)).

%%%===================================================================
%%% Local command spawning
%%%===================================================================

spawn_cmd(Cmd) ->
    spawn_cmd(Cmd, []).
spawn_cmd(Cmd, Opts) ->
    Port = open_port({spawn, Cmd}, [stream, in, exit_status, stderr_to_stdout] ++ Opts),
    put(Port, Cmd),
    Port.

wait_for_cmd(Port) ->
    rt:wait_until(node(),
                  fun(_) ->
                          receive
                              {Port, Msg={data, _}} ->
                                  self() ! {Port, Msg},
                                  false;
                              {Port, Msg={exit_status, _}} ->
                                  catch port_close(Port),
                                  self() ! {Port, Msg},
                                  true
              after 0 ->
                  false
              end
                  end),
    get_cmd_result(Port, []).

get_cmd_result(Port, Acc) ->
    receive
        {Port, {data, Bytes}} ->
            get_cmd_result(Port, [Bytes|Acc]);
        {Port, {exit_status, Status}} ->
            case Status of
                0 ->
                    ok;
                _ ->
                    Cmd = get(Port),
                    lager:info("~p returned exit status: ~p",
                               [Cmd, Status]),
                    ok
            end,
            erase(Port),
            Output = lists:flatten(lists:reverse(Acc)),
            {Status, Output}
    end.

%%%===================================================================
%%% rtdev stuff
%%%===================================================================

devpaths() ->
    Paths = proplists:delete(root, rt_config:get(rtdev_path)),
    lists:usort([DevPath || {_Name, DevPath} <- Paths]).

stop_all(Hosts) ->
    %% [stop_all(Host, DevPath ++ "/dev") || Host <- Hosts,
    %%                                       DevPath <- devpaths()].
    All = [{Host, DevPath} || Host <- Hosts,
                              DevPath <- devpaths()],
    rt:pmap(fun({Host, DevPath}) ->
                    stop_all(Host, DevPath ++ "/dev")
            end, All).

stop_all(Host, DevPath) ->
    case wildcard(Host, DevPath ++ "/dev*") of
        error ->
            lager:info("~s is not a directory.", [DevPath]);
        Devs ->
            [begin
                 Cmd = D ++ "/bin/riak stop",
                 {_, Result} = ssh_cmd(Host, Cmd),
                 Status = case string:tokens(Result, "\n") of
                              ["ok"|_] -> "ok";
                              [_|_] -> "wasn't running";
                              [] -> "error"
                          end,
                 lager:info("Stopping Node... ~s :: ~s ~~ ~s.",
                            [Host, Cmd, Status])
             end || D <- Devs]
    end,
    ok.

teardown() ->
    stop_all(rt_config:get(rt_hostnames)).

%%%===================================================================
%%% Utilities
%%%===================================================================

to_list(X) when is_integer(X) -> integer_to_list(X);
to_list(X) when is_float(X)   -> float_to_list(X);
to_list(X) when is_atom(X)    -> atom_to_list(X);
to_list(X) when is_list(X)    -> X.     %Assumed to be a string

to_binary(X) when is_binary(X) ->
    X;
to_binary(X) ->
    list_to_binary(to_list(X)).
