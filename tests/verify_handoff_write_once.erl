%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Basho Technologies, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(verify_handoff_write_once).
-behavior(riak_test).
-export([confirm/0]).
-include_lib("eunit/include/eunit.hrl").
-define(BUCKET_TYPE, <<"write_once">>).

%% We've got a separate test for capability negotiation and other mechanisms, so the test here is fairly
%% straightforward: get a list of different versions of nodes and join them into a cluster, making sure that
%% each time our data has been replicated:
confirm() ->
    NTestItems    = 1000,                                   %% How many test items to write/verify?
    NTestNodes    = 2,                                      %% How many nodes to spin up for tests?

    run_test(NTestItems, NTestNodes),

    lager:info("Test verify_handoff passed."),
    pass.

run_test(NTestItems, NTestNodes) ->
    lager:info("Testing handoff (items ~p, encoding: default)", [NTestItems]),

    lager:info("Spinning up test nodes"),
    [RootNode | TestNodes] = Nodes = deploy_test_nodes(NTestNodes),

    rt:wait_for_service(RootNode, riak_kv),

    make_intercepts_tab(RootNode),

    %% Insert delay into handoff folding to test the efficacy of the
    %% handoff heartbeat addition
    [rt_intercept:add(N, {riak_core_handoff_sender,
                          [{{visit_item, 3}, delayed_visit_item_3}]})
     || N <- Nodes],

    %% Count everytime riak_kv_vnode:handle_overload_command/3 is called with a
    %% ts_puts tuple
    [rt_intercept:add(N, {riak_kv_vnode,
                          [{{handle_handoff_command, 3}, count_handoff_w1c_puts}]})
     || N <- Nodes],

    lager:info("Populating root node."),
    %% write one object with a bucket type
    rt:create_and_activate_bucket_type(RootNode, ?BUCKET_TYPE, [{write_once, true}]),
    %% allow cluster metadata some time to propogate
    rt:systest_write(RootNode, 1, NTestItems, {?BUCKET_TYPE, <<"bucket">>}, 1),

    %% Test handoff on each node:
    lager:info("Testing handoff for cluster."),
    lists:foreach(fun(TestNode) -> test_handoff(RootNode, TestNode, NTestItems) end, TestNodes).

%% See if we get the same data back from our new nodes as we put into the root node:
test_handoff(RootNode, NewNode, NTestItems) ->

    lager:info("Waiting for service on new node."),
    rt:wait_for_service(NewNode, riak_kv),

    %% Set the w1c_put counter to 0
    true = rpc:call(RootNode, ets, insert, [intercepts_tab, {w1c_put_counter, 0}]),

    lager:info("Joining new node with cluster."),
    rt:join(NewNode, RootNode),
    ?assertEqual(ok, rt:wait_until_nodes_ready([RootNode, NewNode])),
    spawn(fun() ->
              rt:systest_write(RootNode, 1001, 2000, {?BUCKET_TYPE, <<"bucket">>}, 1)
          end),
    rt:wait_until_no_pending_changes([RootNode, NewNode]),

    %% See if we get the same data back from the joined node that we added to the root node.
    %%  Note: systest_read() returns /non-matching/ items, so getting nothing back is good:
    lager:info("Validating data after handoff:"),
    Results2 = rt:systest_read(NewNode, 1, NTestItems, {?BUCKET_TYPE, <<"bucket">>}, 1),
    ?assertEqual(0, length(Results2)),
    lager:info("Data looks ok."),
    [{_, Count}] = rpc:call(RootNode, ets, lookup, [intercepts_tab, w1c_put_counter]),
    ?assert(Count > 0),
    lager:info("Looking Good. We handled ~p write_once puts during handoff.", [Count]).

deploy_test_nodes(N) ->
    Config = [{riak_core, [{default_bucket_props, [{n_val, 1}]},
                           {ring_creation_size, 8},
                           {handoff_acksync_threshold, 20},
                           {handoff_concurrency, 2},
                           {handoff_receive_timeout, 2000}]}],
    rt:deploy_nodes(N, Config).

make_intercepts_tab(Node) ->
    SupPid = rpc:call(Node, erlang, whereis, [sasl_safe_sup]),
    intercepts_tab = rpc:call(Node, ets, new, [intercepts_tab, [named_table,
                public, set, {heir, SupPid, {}}]]).