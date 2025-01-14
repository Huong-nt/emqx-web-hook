%% Copyright (c) 2019 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% Define the default actions.
-module(emqx_web_hook_actions).

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/logger.hrl").

-define(RESOURCE_TYPE_WEBHOOK, 'web_hook').
-define(RESOURCE_CONFIG_SPEC, #{
            url => #{type => string,
                     format => url,
                     required => true,
                     title => #{en => <<"Request URL">>,
                                zh => <<"请求 URL"/utf8>>},
                     description => #{en => <<"Request URL">>,
                                      zh => <<"请求 URL"/utf8>>}},
            headers => #{type => object,
                         schema => #{},
                         default => #{},
                         title => #{en => <<"Request Header">>,
                                    zh => <<"请求头"/utf8>>},
                         description => #{en => <<"Request Header">>,
                                          zh => <<"请求头"/utf8>>}},
            method => #{type => string,
                        enum => [<<"PUT">>,<<"POST">>],
                        default => <<"POST">>,
                        title => #{en => <<"Request Method">>,
                                   zh => <<"请求方法"/utf8>>},
                        description => #{en => <<"Request Method">>,
                                         zh => <<"请求方法"/utf8>>}}
        }).

-define(ACTION_PARAM_RESOURCE, #{
            type => string,
            required => true,
            title => #{en => <<"Resource ID">>,
                       zh => <<"资源 ID"/utf8>>},
            description => #{en => <<"Bind a resource to this action">>,
                             zh => <<"给动作绑定一个资源"/utf8>>}
        }).

-define(ACTION_DATA_SPEC, #{
            '$resource' => ?ACTION_PARAM_RESOURCE
        }).

-define(JSON_REQ(URL, HEADERS, BODY), {(URL), (HEADERS), "application/json", (BODY)}).

-resource_type(#{name => ?RESOURCE_TYPE_WEBHOOK,
                 create => on_resource_create,
                 status => on_get_resource_status,
                 destroy => on_resource_destroy,
                 params => ?RESOURCE_CONFIG_SPEC,
                 title => #{en => <<"WebHook">>,
                            zh => <<"WebHook"/utf8>>},
                 description => #{en => <<"WebHook">>,
                                  zh => <<"WebHook"/utf8>>}
                }).

-rule_action(#{name => data_to_webserver,
               for => '$any',
               create => on_action_create_data_to_webserver,
               params => ?ACTION_DATA_SPEC,
               types => [?RESOURCE_TYPE_WEBHOOK],
               title => #{en => <<"Data to Web Server">>,
                          zh => <<"发送数据到 Web 服务"/utf8>>},
               description => #{en => <<"Forward Messages to Web Server">>,
                                zh => <<"将数据转发给 Web 服务"/utf8>>}
              }).

-type(action_fun() :: fun((Data :: map(), Envs :: map()) -> Result :: any())).

-type(url() :: binary()).

-export_type([action_fun/0]).

-export([ on_resource_create/2
        , on_get_resource_status/2
        , on_resource_destroy/2
        ]).

-export([ on_action_create_data_to_webserver/2
        ]).

%%------------------------------------------------------------------------------
%% Actions for web hook
%%------------------------------------------------------------------------------

-spec(on_resource_create(binary(), map()) -> map()).
on_resource_create(ResId, Conf = #{<<"url">> := Url}) ->
    case emqx_rule_utils:http_connectivity(Url) of
        ok -> Conf;
        {error, Reason} ->
            ?LOG(error, "Initiate Resource ~p failed, ResId: ~p, ~0p",
                [?RESOURCE_TYPE_WEBHOOK, ResId, Reason]),
            error({connect_failure, Reason})
    end.

-spec(on_get_resource_status(binary(), map()) -> map()).
on_get_resource_status(ResId, _Params = #{<<"url">> := Url}) ->
    #{is_alive =>
        case emqx_rule_utils:http_connectivity(Url) of
            ok -> true;
            {error, Reason} ->
                ?LOG(error, "Connectivity Check for ~p failed, ResId: ~p, ~0p",
                     [?RESOURCE_TYPE_WEBHOOK, ResId, Reason]),
                false
        end}.

-spec(on_resource_destroy(binary(), map()) -> ok | {error, Reason::term()}).
on_resource_destroy(_ResId, _Params) ->
    ok.

%% An action that forwards publish messages to a remote web server.
-spec(on_action_create_data_to_webserver(Id::binary(), #{url() := string()}) -> action_fun()).
on_action_create_data_to_webserver(_Id, Params) ->
    #{url := Url, headers := Headers, method := Method}
        = parse_action_params(Params),
    fun(Selected, _Envs) ->
        http_request(Url, Headers, Method, Selected)
    end.


%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

http_request(Url, Headers, Method, Params) ->
    logger:debug("[WebHook Action] ~s to ~s, headers: ~s, body: ~p", [Method, Url, Headers, Params]),
    case http_request(Method, ?JSON_REQ(Url, Headers, jsx:encode(Params)),
                      [{timeout, 5000}], [], 0) of
        {ok, _} -> ok;
        {error, Reason} ->
            logger:error("[WebHook Action] HTTP request error: ~p", [Reason])
    end.

http_request(Method, Req, HTTPOpts, Opts, Times) ->
    %% Resend request, when TCP closed by remotely
    case httpc:request(Method, Req, HTTPOpts, Opts) of
        {error, socket_closed_remotely} when Times < 3 ->
            timer:sleep(trunc(math:pow(10, Times))),
            http_request(Method, Req, HTTPOpts, Opts, Times+1);
        Other -> Other
    end.

parse_action_params(Params = #{<<"url">> := Url}) ->
    try
        #{url => str(Url),
          headers => headers(maps:get(<<"headers">>, Params, undefined)),
          method => method(maps:get(<<"method">>, Params, <<"POST">>)),
          template => maps:get(<<"template">>, Params, undefined)}
    catch _:_ ->
        throw({invalid_params, Params})
    end.

method(GET) when GET == <<"GET">>; GET == <<"get">> -> get;
method(POST) when POST == <<"POST">>; POST == <<"post">> -> post;
method(PUT) when PUT == <<"PUT">>; PUT == <<"put">> -> put;
method(DEL) when DEL == <<"DELETE">>; DEL == <<"delete">> -> delete.

headers(undefined) -> [];
headers(Headers) when is_map(Headers) ->
    maps:fold(fun(K, V, Acc) ->
            [{str(K), str(V)} | Acc]
        end, [], Headers).

str(Str) when is_list(Str) -> Str;
str(Atom) when is_atom(Atom) -> atom_to_list(Atom);
str(Bin) when is_binary(Bin) -> binary_to_list(Bin).
