%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Basho Technologies, Inc.
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

-module(ts_cluster_select_desc_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

suite() ->
    [{timetrap,{minutes,10}}].

init_per_suite(Config) ->
    [_Node|_] = Cluster = ts_util:build_cluster(multiple),
    [{cluster, Cluster} | Config].

end_per_suite(_Config) ->
    ok.

init_per_group(use_ttb_true, Config) ->
    [{use_ttb, true} | Config];
init_per_group(use_ttb_false, Config) ->
    [{use_ttb, false} | Config].

end_per_group(_GroupName, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    ct:pal("TEST CASE ~p", [_TestCase]),
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

groups() ->
    [
     {use_ttb_true, [sequence], rt:grep_test_functions(?MODULE)}
     ,{use_ttb_false, [sequence], rt:grep_test_functions(?MODULE)}
    ].

all() -> 
    [
     {group, use_ttb_true}
     ,{group, use_ttb_false}
    ].

%%--------------------------------------------------------------------
%% UTILS
%%--------------------------------------------------------------------

run_query(Pid, Query, Config) when is_pid(Pid) ->
    UseTTB = proplists:get_value(use_ttb, Config),
    riakc_ts:query(Pid, Query, [{use_ttb, UseTTB}]).

table_name() ->
    {_, Reds} = erlang:process_info(self(), reductions),
    "table_" ++ integer_to_list(random:uniform(Reds * 1000)).

%%--------------------------------------------------------------------
%% TESTS
%%--------------------------------------------------------------------

%% basic descending keys test with the desc key on the last timestamp column in
%% the key.
select_def_basic_test(Config) ->
    [Node|_] = proplists:get_value(cluster, Config),
    Pid = rt:pbc(Node),
    Table = table_name(),
    Table_def =
        "CREATE TABLE "++Table++"("
        "a SINT64 NOT NULL, "
        "b SINT64 NOT NULL, "
        "c TIMESTAMP NOT NULL, "
        "PRIMARY KEY ((a,b,quantum(c, 1, 's')), a,b, c DESC))",
    {ok, _} = run_query(Pid, Table_def, Config),
    ok = riakc_ts:put(Pid, Table, [{1,1,N} || N <- lists:seq(1,200)]),
    Query =
        "SELECT * FROM "++Table++" WHERE a = 1 AND b = 1 AND c >= 35 AND c <= 45",
    ts_util:assert_row_sets(
        {rt_ignore_columns, [{1,1,N} || N <- lists:seq(45,35,-1)]},
        run_query(Pid, Query, Config)
    ).

create_data_def_multi_quanta_test(Config) ->
    [Node|_] = proplists:get_value(cluster, Config),
    Pid = rt:pbc(Node),
    Table = table_name(),
    Table_def =
        "CREATE TABLE "++Table++"("
        "a SINT64 NOT NULL, "
        "b SINT64 NOT NULL, "
        "c TIMESTAMP NOT NULL, "
        "PRIMARY KEY ((a,b,quantum(c, 1, 's')), a,b,c DESC))",
    {ok, _} = run_query(Pid, Table_def, Config),
    ok = riakc_ts:put(Pid, Table, [{1,1,N} || N <- lists:seq(200,200*100,200)]),
    Query =
        "SELECT * FROM "++Table++" WHERE a = 1 AND b = 1 AND c >= 3000 AND c <= 5000",
    ts_util:assert_row_sets(
        {rt_ignore_columns, [{1,1,N} || N <- lists:seq(5000,3000,-200)]},
        run_query(Pid, Query, Config)
    ).