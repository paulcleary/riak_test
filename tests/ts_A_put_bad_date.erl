%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Basho Technologies, Inc.
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

-module(ts_A_put_bad_date).

-behavior(riak_test).

-export([confirm/0]).

-include_lib("eunit/include/eunit.hrl").

confirm() ->
    TestType = normal,
    DDL = ts_util:get_ddl(),
    Obj =
        [[ts_util:get_varchar(),
          ts_util:get_varchar(),
          <<"abc">>,
          ts_util:get_varchar(),
          ts_util:get_float()]],
    Expected = {error, {1003, <<"Invalid data found at row index(es) 1">>}},
    Got = ts_util:ts_put(
            ts_util:cluster_and_connect(single), TestType, DDL, Obj),
    ?assertEqual(Expected, Got),
    pass.
