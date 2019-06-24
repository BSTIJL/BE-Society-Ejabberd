%%%----------------------------------------------------------------------
%%% File    : mod_offline.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Store and manage offline messages.
%%% Created :  5 Jan 2003 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2019   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(mod_offline).

-author('alexey@process-one.net').

-protocol({xep, 13, '1.2'}).
-protocol({xep, 22, '1.4'}).
-protocol({xep, 23, '1.3'}).
-protocol({xep, 160, '1.0'}).
-protocol({xep, 334, '0.2'}).

-behaviour(gen_mod).

-export([start/2,
	 stop/1,
	 reload/3,
	 store_packet/1,
	 store_offline_msg/1,
	 c2s_self_presence/1,
	 get_sm_features/5,
	 get_sm_identity/5,
	 get_sm_items/5,
	 get_info/5,
	 handle_offline_query/1,
	 remove_expired_messages/1,
	 remove_old_messages/2,
	 remove_user/2,
	 import_info/0,
	 import_start/2,
	 import/5,
	 export/1,
	 get_queue_length/2,
	 count_offline_messages/2,
	 get_offline_els/2,
	 find_x_expire/2,
	 c2s_handle_info/2,
	 c2s_copy_session/2,
	 webadmin_page/3,
	 webadmin_user/4,
	 webadmin_user_parse_query/5]).

-export([mod_opt_type/1, mod_options/1, depends/2]).

-deprecated({get_queue_length,2}).

-include("logger.hrl").

-include("xmpp.hrl").

-include("ejabberd_http.hrl").

-include("ejabberd_web_admin.hrl").

-include("mod_offline.hrl").

-include("translate.hrl").

-define(OFFLINE_TABLE_LOCK_THRESHOLD, 1000).

%% default value for the maximum number of user messages
-define(MAX_USER_MESSAGES, infinity).

-define(EMPTY_SPOOL_CACHE, offline_empty_cache).

-type c2s_state() :: ejabberd_c2s:state().

-callback init(binary(), gen_mod:opts()) -> any().
-callback import(#offline_msg{}) -> ok.
-callback store_message(#offline_msg{}) -> ok | {error, any()}.
-callback pop_messages(binary(), binary()) ->
    {ok, [#offline_msg{}]} | {error, any()}.
-callback remove_expired_messages(binary()) -> {atomic, any()}.
-callback remove_old_messages(non_neg_integer(), binary()) -> {atomic, any()}.
-callback remove_user(binary(), binary()) -> any().
-callback read_message_headers(binary(), binary()) ->
    [{non_neg_integer(), jid(), jid(), undefined | erlang:timestamp(), xmlel()}].
-callback read_message(binary(), binary(), non_neg_integer()) ->
    {ok, #offline_msg{}} | error.
-callback remove_message(binary(), binary(), non_neg_integer()) -> ok | {error, any()}.
-callback read_all_messages(binary(), binary()) -> [#offline_msg{}].
-callback remove_all_messages(binary(), binary()) -> {atomic, any()}.
-callback count_messages(binary(), binary()) -> non_neg_integer().

-optional_callbacks([remove_expired_messages/1, remove_old_messages/2]).

depends(_Host, _Opts) ->
    [].

start(Host, Opts) ->
    Mod = gen_mod:db_mod(Opts, ?MODULE),
    Mod:init(Host, Opts),
    init_cache(Opts),
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE,
		       store_packet, 50),
    ejabberd_hooks:add(c2s_self_presence, Host, ?MODULE, c2s_self_presence, 50),
    ejabberd_hooks:add(remove_user, Host,
		       ?MODULE, remove_user, 50),
    ejabberd_hooks:add(disco_sm_features, Host,
		       ?MODULE, get_sm_features, 50),
    ejabberd_hooks:add(disco_local_features, Host,
		       ?MODULE, get_sm_features, 50),
    ejabberd_hooks:add(disco_sm_identity, Host,
		       ?MODULE, get_sm_identity, 50),
    ejabberd_hooks:add(disco_sm_items, Host,
		       ?MODULE, get_sm_items, 50),
    ejabberd_hooks:add(disco_info, Host, ?MODULE, get_info, 50),
    ejabberd_hooks:add(c2s_handle_info, Host, ?MODULE, c2s_handle_info, 50),
    ejabberd_hooks:add(c2s_copy_session, Host, ?MODULE, c2s_copy_session, 50),
    ejabberd_hooks:add(webadmin_page_host, Host,
		       ?MODULE, webadmin_page, 50),
    ejabberd_hooks:add(webadmin_user, Host,
		       ?MODULE, webadmin_user, 50),
    ejabberd_hooks:add(webadmin_user_parse_query, Host,
		       ?MODULE, webadmin_user_parse_query, 50),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_FLEX_OFFLINE,
				  ?MODULE, handle_offline_query).

stop(Host) ->
    ejabberd_hooks:delete(offline_message_hook, Host,
			  ?MODULE, store_packet, 50),
    ejabberd_hooks:delete(c2s_self_presence, Host, ?MODULE, c2s_self_presence, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE,
			  remove_user, 50),
    ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE, get_sm_features, 50),
    ejabberd_hooks:delete(disco_local_features, Host, ?MODULE, get_sm_features, 50),
    ejabberd_hooks:delete(disco_sm_identity, Host, ?MODULE, get_sm_identity, 50),
    ejabberd_hooks:delete(disco_sm_items, Host, ?MODULE, get_sm_items, 50),
    ejabberd_hooks:delete(disco_info, Host, ?MODULE, get_info, 50),
    ejabberd_hooks:delete(c2s_handle_info, Host, ?MODULE, c2s_handle_info, 50),
    ejabberd_hooks:delete(c2s_copy_session, Host, ?MODULE, c2s_copy_session, 50),
    ejabberd_hooks:delete(webadmin_page_host, Host,
			  ?MODULE, webadmin_page, 50),
    ejabberd_hooks:delete(webadmin_user, Host,
			  ?MODULE, webadmin_user, 50),
    ejabberd_hooks:delete(webadmin_user_parse_query, Host,
			  ?MODULE, webadmin_user_parse_query, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_FLEX_OFFLINE).

reload(Host, NewOpts, OldOpts) ->
    NewMod = gen_mod:db_mod(NewOpts, ?MODULE),
    OldMod = gen_mod:db_mod(OldOpts, ?MODULE),
    init_cache(NewOpts),
    if NewMod /= OldMod ->
	    NewMod:init(Host, NewOpts);
       true ->
	    ok
    end.

init_cache(Opts) ->
    case mod_offline_opt:use_mam_for_storage(Opts) of
        true ->
	    MaxSize = mod_offline_opt:cache_size(Opts),
	    LifeTime = mod_offline_opt:cache_life_time(Opts),
	    COpts = [{max_size, MaxSize}, {cache_missed, false}, {life_time, LifeTime}],
            ets_cache:new(?EMPTY_SPOOL_CACHE, COpts);
        false ->
            ets_cache:delete(?EMPTY_SPOOL_CACHE)
    end.

-spec store_offline_msg(#offline_msg{}) -> ok | {error, full | any()}.
store_offline_msg(#offline_msg{us = {User, Server}, packet = Pkt} = Msg) ->
    UseMam = use_mam_for_user(User, Server),
    case UseMam andalso xmpp:get_meta(Pkt, mam_archived, false) of
	true ->
	    Mod = gen_mod:db_mod(Server, ?MODULE),
	    ets_cache:lookup(?EMPTY_SPOOL_CACHE, {User, Server},
		fun() ->
		    case count_messages_in_db(User, Server) of
			0 ->
			    case Mod:store_message(Msg) of
				ok ->
				    {cache, ok};
				Err ->
				    {nocache, Err}
			    end;
			_ ->
			    {cache, ok}
		    end
		end);
	false ->
	    Mod = gen_mod:db_mod(Server, ?MODULE),
	    case get_max_user_messages(User, Server) of
		infinity ->
		    Mod:store_message(Msg);
		Limit ->
		    Num = count_messages_in_db(User, Server),
		    if Num < Limit ->
			Mod:store_message(Msg);
			true ->
			    {error, full}
		    end
	    end
    end.

get_max_user_messages(User, Server) ->
    Access = mod_offline_opt:access_max_user_messages(Server),
    case ejabberd_shaper:match(Server, Access, jid:make(User, Server)) of
	Max when is_integer(Max) -> Max;
	infinity -> infinity;
	_ -> ?MAX_USER_MESSAGES
    end.

get_sm_features(Acc, _From, _To, <<"">>, _Lang) ->
    Feats = case Acc of
		{result, I} -> I;
		_ -> []
	    end,
    {result, Feats ++ [?NS_FEATURE_MSGOFFLINE, ?NS_FLEX_OFFLINE]};

get_sm_features(_Acc, _From, _To, ?NS_FEATURE_MSGOFFLINE, _Lang) ->
    %% override all lesser features...
    {result, []};

get_sm_features(_Acc, #jid{luser = U, lserver = S}, #jid{luser = U, lserver = S},
		?NS_FLEX_OFFLINE, _Lang) ->
    {result, [?NS_FLEX_OFFLINE]};

get_sm_features(Acc, _From, _To, _Node, _Lang) ->
    Acc.

get_sm_identity(Acc, #jid{luser = U, lserver = S}, #jid{luser = U, lserver = S},
		?NS_FLEX_OFFLINE, _Lang) ->
    [#identity{category = <<"automation">>,
	       type = <<"message-list">>}|Acc];
get_sm_identity(Acc, _From, _To, _Node, _Lang) ->
    Acc.

get_sm_items(_Acc, #jid{luser = U, lserver = S} = JID,
	     #jid{luser = U, lserver = S},
	     ?NS_FLEX_OFFLINE, _Lang) ->
    ejabberd_sm:route(JID, {resend_offline, false}),
	    Mod = gen_mod:db_mod(S, ?MODULE),
	    Hdrs = Mod:read_message_headers(U, S),
	    BareJID = jid:remove_resource(JID),
	    {result, lists:map(
		       fun({Seq, From, _To, _TS, _El}) ->
			       Node = integer_to_binary(Seq),
			       #disco_item{jid = BareJID,
					   node = Node,
					   name = jid:encode(From)}
		       end, Hdrs)};
get_sm_items(Acc, _From, _To, _Node, _Lang) ->
    Acc.

-spec get_info([xdata()], binary(), module(), binary(), binary()) -> [xdata()];
	      ([xdata()], jid(), jid(), binary(), binary()) -> [xdata()].
get_info(_Acc, #jid{luser = U, lserver = S} = JID,
	 #jid{luser = U, lserver = S}, ?NS_FLEX_OFFLINE, Lang) ->
    ejabberd_sm:route(JID, {resend_offline, false}),
    [#xdata{type = result,
	    fields = flex_offline:encode(
		       [{number_of_messages, count_offline_messages(U, S)}],
		       Lang)}];
get_info(Acc, _From, _To, _Node, _Lang) ->
    Acc.

-spec c2s_handle_info(c2s_state(), term()) -> c2s_state().
c2s_handle_info(State, {resend_offline, Flag}) ->
    {stop, State#{resend_offline => Flag}};
c2s_handle_info(State, _) ->
    State.

-spec c2s_copy_session(c2s_state(), c2s_state()) -> c2s_state().
c2s_copy_session(State, #{resend_offline := Flag}) ->
    State#{resend_offline => Flag};
c2s_copy_session(State, _) ->
    State.

-spec handle_offline_query(iq()) -> iq().
handle_offline_query(#iq{from = #jid{luser = U1, lserver = S1},
			 to = #jid{luser = U2, lserver = S2},
			 lang = Lang,
			 sub_els = [#offline{}]} = IQ)
  when {U1, S1} /= {U2, S2} ->
    Txt = ?T("Query to another users is forbidden"),
    xmpp:make_error(IQ, xmpp:err_forbidden(Txt, Lang));
handle_offline_query(#iq{from = #jid{luser = U, lserver = S} = From,
			 to = #jid{luser = U, lserver = S} = _To,
			 type = Type, lang = Lang,
			 sub_els = [#offline{} = Offline]} = IQ) ->
    case {Type, Offline} of
	{get, #offline{fetch = true, items = [], purge = false}} ->
	    %% TODO: report database errors
	    handle_offline_fetch(From),
	    xmpp:make_iq_result(IQ);
	{get, #offline{fetch = false, items = [_|_] = Items, purge = false}} ->
	    case handle_offline_items_view(From, Items) of
		true -> xmpp:make_iq_result(IQ);
		false -> xmpp:make_error(IQ, xmpp:err_item_not_found())
	    end;
	{set, #offline{fetch = false, items = [], purge = true}} ->
	    case delete_all_msgs(U, S) of
		{atomic, ok} ->
		    xmpp:make_iq_result(IQ);
		_Err ->
		    Txt = ?T("Database failure"),
		    xmpp:make_error(IQ, xmpp:err_internal_server_error(Txt, Lang))
	    end;
	{set, #offline{fetch = false, items = [_|_] = Items, purge = false}} ->
	    case handle_offline_items_remove(From, Items) of
		true -> xmpp:make_iq_result(IQ);
		false -> xmpp:make_error(IQ, xmpp:err_item_not_found())
	    end;
	_ ->
	    xmpp:make_error(IQ, xmpp:err_bad_request())
    end;
handle_offline_query(#iq{lang = Lang} = IQ) ->
    Txt = ?T("No module is handling this query"),
    xmpp:make_error(IQ, xmpp:err_service_unavailable(Txt, Lang)).

-spec handle_offline_items_view(jid(), [offline_item()]) -> boolean().
handle_offline_items_view(JID, Items) ->
    {U, S, R} = jid:tolower(JID),
    case use_mam_for_user(U, S) of
	true ->
	    false;
	_ ->
	    lists:foldl(
		fun(#offline_item{node = Node, action = view}, Acc) ->
		    case fetch_msg_by_node(JID, Node) of
			{ok, OfflineMsg} ->
			    case offline_msg_to_route(S, OfflineMsg) of
				{route, El} ->
				    NewEl = set_offline_tag(El, Node),
				    case ejabberd_sm:get_session_pid(U, S, R) of
					Pid when is_pid(Pid) ->
					    Pid ! {route, NewEl};
					none ->
					    ok
				    end,
				    Acc or true;
				error ->
				    Acc or false
			    end;
			error ->
			    Acc or false
		    end
		end, false, Items)    end.

-spec handle_offline_items_remove(jid(), [offline_item()]) -> boolean().
handle_offline_items_remove(JID, Items) ->
    {U, S, _R} = jid:tolower(JID),
    case use_mam_for_user(U, S) of
	true ->
	    false;
	_ ->
	    lists:foldl(
		fun(#offline_item{node = Node, action = remove}, Acc) ->
		    Acc or remove_msg_by_node(JID, Node)
		end, false, Items)
    end.

-spec set_offline_tag(message(), binary()) -> message().
set_offline_tag(Msg, Node) ->
    xmpp:set_subtag(Msg, #offline{items = [#offline_item{node = Node}]}).

-spec handle_offline_fetch(jid()) -> ok.
handle_offline_fetch(#jid{luser = U, lserver = S} = JID) ->
    ejabberd_sm:route(JID, {resend_offline, false}),
    lists:foreach(
	fun({Node, El}) ->
	    El1 = set_offline_tag(El, Node),
	    ejabberd_router:route(El1)
	end, read_messages(U, S)).

-spec fetch_msg_by_node(jid(), binary()) -> error | {ok, #offline_msg{}}.
fetch_msg_by_node(To, Seq) ->
    case catch binary_to_integer(Seq) of
	I when is_integer(I), I >= 0 ->
	    LUser = To#jid.luser,
	    LServer = To#jid.lserver,
	    Mod = gen_mod:db_mod(LServer, ?MODULE),
	    Mod:read_message(LUser, LServer, I);
	_ ->
	    error
    end.

-spec remove_msg_by_node(jid(), binary()) -> boolean().
remove_msg_by_node(To, Seq) ->
    case catch binary_to_integer(Seq) of
	I when is_integer(I), I>= 0 ->
	    LUser = To#jid.luser,
	    LServer = To#jid.lserver,
	    Mod = gen_mod:db_mod(LServer, ?MODULE),
	    Mod:remove_message(LUser, LServer, I),
	    true;
	_ ->
	    false
    end.

-spec need_to_store(binary(), message()) -> boolean().
need_to_store(_LServer, #message{type = error}) -> false;
need_to_store(LServer, #message{type = Type} = Packet) ->
    case xmpp:has_subtag(Packet, #offline{}) of
	false ->
	    case misc:unwrap_mucsub_message(Packet) of
		#message{type = groupchat} = Msg ->
		    need_to_store(LServer, Msg#message{type = chat});
		#message{} = Msg ->
		    need_to_store(LServer, Msg);
		_ ->
		    case check_store_hint(Packet) of
			store ->
			    true;
			no_store ->
			    false;
			none ->
			    Store = case Type of
					groupchat ->
					    mod_offline_opt:store_groupchat(LServer);
					headline ->
					    false;
					_ ->
					    true
				    end,
			    case {Store, mod_offline_opt:store_empty_body(LServer)} of
				{false, _} ->
				    false;
				{_, true} ->
				    true;
				{_, false} ->
				    Packet#message.body /= [];
				{_, unless_chat_state} ->
				    not misc:is_standalone_chat_state(Packet)
			    end
		    end
	    end;
	true ->
	    false
    end.

-spec store_packet({any(), message()}) -> {any(), message()}.
store_packet({_Action, #message{from = From, to = To} = Packet} = Acc) ->
    case need_to_store(To#jid.lserver, Packet) of
	true ->
	    case check_event(Packet) of
		true ->
		    #jid{luser = LUser, lserver = LServer} = To,
		    case ejabberd_hooks:run_fold(store_offline_message, LServer,
						 Packet, []) of
			drop ->
			    Acc;
			NewPacket ->
			    TimeStamp = erlang:timestamp(),
			    Expire = find_x_expire(TimeStamp, NewPacket),
			    OffMsg = #offline_msg{us = {LUser, LServer},
						  timestamp = TimeStamp,
						  expire = Expire,
						  from = From,
						  to = To,
						  packet = NewPacket},
			    case store_offline_msg(OffMsg) of
				ok ->
				    {offlined, NewPacket};
				{error, Reason} ->
				    discard_warn_sender(Packet, Reason),
				    stop
			    end
		    end;
		_ -> Acc
	    end;
	false -> Acc
    end.

-spec check_store_hint(message()) -> store | no_store | none.
check_store_hint(Packet) ->
    case has_store_hint(Packet) of
	true ->
	    store;
	false ->
	    case has_no_store_hint(Packet) of
		true ->
		    no_store;
		false ->
		    none
	    end
    end.

-spec has_store_hint(message()) -> boolean().
has_store_hint(Packet) ->
    xmpp:has_subtag(Packet, #hint{type = 'store'}).

-spec has_no_store_hint(message()) -> boolean().
has_no_store_hint(Packet) ->
    xmpp:has_subtag(Packet, #hint{type = 'no-store'})
	orelse
	xmpp:has_subtag(Packet, #hint{type = 'no-storage'}).

%% Check if the packet has any content about XEP-0022
-spec check_event(message()) -> boolean().
check_event(#message{from = From, to = To, id = ID, type = Type} = Msg) ->
    case xmpp:get_subtag(Msg, #xevent{}) of
	false ->
	    true;
	#xevent{id = undefined, offline = false} ->
	    true;
	#xevent{id = undefined, offline = true} ->
	    NewMsg = #message{from = To, to = From, id = ID, type = Type,
			      sub_els = [#xevent{id = ID, offline = true}]},
	    ejabberd_router:route(NewMsg),
	    true;
	_ ->
	    false
    end.

-spec find_x_expire(erlang:timestamp(), message()) -> erlang:timestamp() | never.
find_x_expire(TimeStamp, Msg) ->
    case xmpp:get_subtag(Msg, #expire{seconds = 0}) of
	#expire{seconds = Int} ->
	    {MegaSecs, Secs, MicroSecs} = TimeStamp,
	    S = MegaSecs * 1000000 + Secs + Int,
	    MegaSecs1 = S div 1000000,
	    Secs1 = S rem 1000000,
	    {MegaSecs1, Secs1, MicroSecs};
	false ->
	    never
    end.

c2s_self_presence({_Pres, #{resend_offline := false}} = Acc) ->
    Acc;
c2s_self_presence({#presence{type = available} = NewPres, State} = Acc) ->
    NewPrio = get_priority_from_presence(NewPres),
    LastPrio = case maps:get(pres_last, State, undefined) of
		   undefined -> -1;
		   LastPres -> get_priority_from_presence(LastPres)
	       end,
    if LastPrio < 0 andalso NewPrio >= 0 ->
	    route_offline_messages(State);
       true ->
	    ok
    end,
    Acc;
c2s_self_presence(Acc) ->
    Acc.

-spec route_offline_messages(c2s_state()) -> ok.
route_offline_messages(#{jid := #jid{luser = LUser, lserver = LServer}} = State) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Msgs = case Mod:pop_messages(LUser, LServer) of
	       {ok, OffMsgs} ->
		   case use_mam_for_user(LUser, LServer) of
		       true ->
			   ets_cache:delete(?EMPTY_SPOOL_CACHE, {LUser, LServer},
					    ejabberd_cluster:get_nodes()),
			   lists:map(
			       fun({_, #message{from = From, to = To} = Msg}) ->
				   #offline_msg{from = From, to = To,
						us = {LUser, LServer},
						packet = Msg}
			       end, read_mam_messages(LUser, LServer, OffMsgs));
		       _ ->
			   OffMsgs
		   end;
	       _ ->
		   []
	   end,
    lists:foreach(
	fun(OffMsg) ->
	    route_offline_message(State, OffMsg)
	end, Msgs).

-spec route_offline_message(c2s_state(), #offline_msg{}) -> ok.
route_offline_message(#{lserver := LServer} = State,
		      #offline_msg{expire = Expire} = OffMsg) ->
    case offline_msg_to_route(LServer, OffMsg) of
	error ->
	    ok;
	{route, Msg} ->
	    case is_message_expired(Expire, Msg) of
		true ->
		    ok;
		false ->
		    case privacy_check_packet(State, Msg, in) of
			allow -> ejabberd_router:route(Msg);
			deny -> ok
		    end
	    end
    end.

-spec is_message_expired(erlang:timestamp() | never, message()) -> boolean().
is_message_expired(Expire, Msg) ->
    TS = erlang:timestamp(),
    Expire1 = case Expire of
		  undefined -> find_x_expire(TS, Msg);
		  _ -> Expire
	      end,
    Expire1 /= never andalso Expire1 =< TS.

-spec privacy_check_packet(c2s_state(), stanza(), in | out) -> allow | deny.
privacy_check_packet(#{lserver := LServer} = State, Pkt, Dir) ->
    ejabberd_hooks:run_fold(privacy_check_packet,
			    LServer, allow, [State, Pkt, Dir]).

remove_expired_messages(Server) ->
    LServer = jid:nameprep(Server),
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    case erlang:function_exported(Mod, remove_expired_messages, 1) of
	true -> Mod:remove_expired_messages(LServer);
	false -> erlang:error(not_implemented)
    end.

remove_old_messages(Days, Server) ->
    LServer = jid:nameprep(Server),
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    case erlang:function_exported(Mod, remove_old_messages, 2) of
	true -> Mod:remove_old_messages(Days, LServer);
	false -> erlang:error(not_implemented)
    end.

-spec remove_user(binary(), binary()) -> ok.
remove_user(User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:remove_user(LUser, LServer),
    ok.

%% Helper functions:

-spec check_if_message_should_be_bounced(message()) -> boolean().
check_if_message_should_be_bounced(Packet) ->
    case Packet of
	#message{type = groupchat, to = #jid{lserver = LServer}} ->
	    mod_offline_opt:bounce_groupchat(LServer);
	#message{to = #jid{lserver = LServer}} ->
	    case misc:is_mucsub_message(Packet) of
		true ->
		    mod_offline_opt:bounce_groupchat(LServer);
		_ ->
		    true
	    end;
	_ ->
	    true
    end.

%% Warn senders that their messages have been discarded:

-spec discard_warn_sender(message(), full | any()) -> ok.
discard_warn_sender(Packet, Reason) ->
    case check_if_message_should_be_bounced(Packet) of
	true ->
	    Lang = xmpp:get_lang(Packet),
	    Err = case Reason of
		      full ->
			  ErrText = ?T("Your contact offline message queue is "
				       "full. The message has been discarded."),
			  xmpp:err_resource_constraint(ErrText, Lang);
		      _ ->
			  ErrText = ?T("Database failure"),
			  xmpp:err_internal_server_error(ErrText, Lang)
		  end,
	    ejabberd_router:route_error(Packet, Err);
	_ ->
	    ok
    end.

webadmin_page(_, Host,
	      #request{us = _US, path = [<<"user">>, U, <<"queue">>],
		       q = Query, lang = Lang} =
		  _Request) ->
    Res = user_queue(U, Host, Query, Lang), {stop, Res};
webadmin_page(Acc, _, _) -> Acc.

get_offline_els(LUser, LServer) ->
    [Packet || {_Seq, Packet} <- read_messages(LUser, LServer)].

-spec offline_msg_to_route(binary(), #offline_msg{}) ->
				  {route, message()} | error.
offline_msg_to_route(LServer, #offline_msg{from = From, to = To} = R) ->
    CodecOpts = ejabberd_config:codec_options(),
    try xmpp:decode(R#offline_msg.packet, ?NS_CLIENT, CodecOpts) of
	Pkt ->
	    Pkt1 = xmpp:set_from_to(Pkt, From, To),
	    Pkt2 = add_delay_info(Pkt1, LServer, R#offline_msg.timestamp),
	    {route, Pkt2}
    catch _:{xmpp_codec, Why} ->
	    ?ERROR_MSG("Failed to decode packet ~p of user ~s: ~s",
		       [R#offline_msg.packet, jid:encode(To),
			xmpp:format_error(Why)]),
	    error
    end.

-spec read_messages(binary(), binary()) -> [{binary(), message()}].
read_messages(LUser, LServer) ->
    Res = read_db_messages(LUser, LServer),
    case use_mam_for_user(LUser, LServer) of
	true ->
	    read_mam_messages(LUser, LServer, Res);
	_ ->
	    Res
    end.

-spec read_db_messages(binary(), binary()) -> [{binary(), message()}].
read_db_messages(LUser, LServer) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    CodecOpts = ejabberd_config:codec_options(),
    lists:flatmap(
	fun({Seq, From, To, TS, El}) ->
	    Node = integer_to_binary(Seq),
	    try xmpp:decode(El, ?NS_CLIENT, CodecOpts) of
		Pkt ->
		    Node = integer_to_binary(Seq),
		    Pkt1 = add_delay_info(Pkt, LServer, TS),
		    Pkt2 = xmpp:set_from_to(Pkt1, From, To),
		    [{Node, Pkt2}]
	    catch _:{xmpp_codec, Why} ->
		?ERROR_MSG("Failed to decode packet ~p "
			   "of user ~s: ~s",
			   [El, jid:encode(To),
			    xmpp:format_error(Why)]),
		[]
	    end
	end, Mod:read_message_headers(LUser, LServer)).

-spec parse_marker_messages(binary(), [#offline_msg{} | {any(), message()}]) ->
    {integer() | none, [message()]}.
parse_marker_messages(LServer, ReadMsgs) ->
    {Timestamp, ExtraMsgs} = lists:foldl(
	fun({_Node, #message{id = <<"ActivityMarker">>,
			     body = [], type = error} = Msg}, {T, E}) ->
	    case xmpp:get_subtag(Msg, #delay{stamp = {0,0,0}}) of
		#delay{stamp = Time} ->
		    if T == none orelse T > Time ->
			{Time, E};
			true ->
			    {T, E}
		    end
	    end;
	   (#offline_msg{from = From, to = To, timestamp = TS, packet = Pkt},
	    {T, E}) ->
	       try xmpp:decode(Pkt) of
		   #message{id = <<"ActivityMarker">>,
			    body = [], type = error} = Msg ->
		       TS2 = case TS of
				 undefined ->
				     case xmpp:get_subtag(Msg, #delay{stamp = {0,0,0}}) of
					 #delay{stamp = TS0} ->
					     TS0;
					 _ ->
					     erlang:timestamp()
				     end;
				 _ ->
				     TS
			     end,
		       if T == none orelse T > TS2 ->
			   {TS2, E};
			   true ->
			       {T, E}
		       end;
		   Decoded ->
		       Pkt1 = add_delay_info(Decoded, LServer, TS),
		       {T, [xmpp:set_from_to(Pkt1, From, To) | E]}
	       catch _:{xmpp_codec, _Why} ->
		   {T, E}
	       end;
	   ({_Node, Msg}, {T, E}) ->
	       {T, [Msg | E]}
	end, {none, []}, ReadMsgs),
    Start = case {Timestamp, ExtraMsgs} of
		{none, [First|_]} ->
		    case xmpp:get_subtag(First, #delay{stamp = {0,0,0}}) of
			#delay{stamp = {Mega, Sec, Micro}} ->
			    {Mega, Sec, Micro+1};
			_ ->
			    none
		    end;
		{none, _} ->
		    none;
		_ ->
		    Timestamp
	    end,
    {Start, ExtraMsgs}.

-spec read_mam_messages(binary(), binary(), [#offline_msg{} | {any(), message()}]) ->
    [{integer(), message()}].
read_mam_messages(LUser, LServer, ReadMsgs) ->
    {Start, ExtraMsgs} = parse_marker_messages(LServer, ReadMsgs),
    AllMsgs = case Start of
		  none ->
		      ExtraMsgs;
		  _ ->
		      MaxOfflineMsgs = case get_max_user_messages(LUser, LServer) of
					   Number when is_integer(Number) ->
					       max(0, Number - length(ExtraMsgs));
					   infinity ->
					       undefined
				       end,
		      JID = jid:make(LUser, LServer, <<>>),
		      {MamMsgs, _, _} = mod_mam:select(LServer, JID, JID,
						       [{start, Start}],
						       #rsm_set{max = MaxOfflineMsgs,
								before = <<"9999999999999999">>},
						       chat, only_messages),
		      MamMsgs2 = lists:map(
			  fun({_, _, #forwarded{sub_els = [MM | _], delay = #delay{stamp = MMT}}}) ->
			      add_delay_info(MM, LServer, MMT)
			  end, MamMsgs),

		      ExtraMsgs ++ MamMsgs2
	      end,
    AllMsgs2 = lists:sort(
	fun(A, B) ->
	    DA = case xmpp:get_subtag(A, #stanza_id{by = #jid{}}) of
		     #stanza_id{id = IDA} ->
			 IDA;
		     _ -> case xmpp:get_subtag(A, #delay{stamp = {0,0,0}}) of
			      #delay{stamp = STA} ->
				  integer_to_binary(misc:now_to_usec(STA));
			      _ ->
				  <<"unknown">>
			  end
		 end,
	    DB = case xmpp:get_subtag(B, #stanza_id{by = #jid{}}) of
		     #stanza_id{id = IDB} ->
			 IDB;
		     _ -> case xmpp:get_subtag(B, #delay{stamp = {0,0,0}}) of
			      #delay{stamp = STB} ->
				  integer_to_binary(misc:now_to_usec(STB));
			      _ ->
				  <<"unknown">>
			  end
		 end,
	    DA < DB
	end, AllMsgs),
    {AllMsgs3, _} = lists:mapfoldl(
	fun(Msg, Counter) ->
	    {{Counter, Msg}, Counter + 1}
	end, 1, AllMsgs2),
    AllMsgs3.

-spec count_mam_messages(binary(), binary(), [#offline_msg{} | {any(), message()}]) ->
    integer().
count_mam_messages(LUser, LServer, ReadMsgs) ->
    {Start, ExtraMsgs} = parse_marker_messages(LServer, ReadMsgs),
    case Start of
	none ->
	    length(ExtraMsgs);
	_ ->
	    MaxOfflineMsgs = case get_max_user_messages(LUser, LServer) of
				 Number when is_integer(Number) -> Number - length(ExtraMsgs);
				 infinity -> undefined
			     end,
	    JID = jid:make(LUser, LServer, <<>>),
	    {_, _, Count} = mod_mam:select(LServer, JID, JID,
					   [{start, Start}],
					   #rsm_set{max = MaxOfflineMsgs,
						    before = <<"9999999999999999">>},
					   chat, only_count),
	    Count + length(ExtraMsgs)
    end.

format_user_queue(Hdrs) ->
    lists:map(
      fun({Seq, From, To, TS, El}) ->
	      ID = integer_to_binary(Seq),
	      FPacket = ejabberd_web_admin:pretty_print_xml(El),
	      SFrom = jid:encode(From),
	      STo = jid:encode(To),
	      Time = case TS of
			 undefined ->
			     Stamp = fxml:get_path_s(El, [{elem, <<"delay">>},
							  {attr, <<"stamp">>}]),
			     try xmpp_util:decode_timestamp(Stamp) of
				 {_, _, _} = Now -> format_time(Now)
			     catch _:_ ->
				     <<"">>
			     end;
			 {_, _, _} = Now ->
			     format_time(Now)
		     end,
	      ?XE(<<"tr">>,
		  [?XAE(<<"td">>, [{<<"class">>, <<"valign">>}],
			[?INPUT(<<"checkbox">>, <<"selected">>, ID)]),
		   ?XAC(<<"td">>, [{<<"class">>, <<"valign">>}], Time),
		   ?XAC(<<"td">>, [{<<"class">>, <<"valign">>}], SFrom),
		   ?XAC(<<"td">>, [{<<"class">>, <<"valign">>}], STo),
		   ?XAE(<<"td">>, [{<<"class">>, <<"valign">>}],
			[?XC(<<"pre">>, FPacket)])])
      end, Hdrs).

format_time(Now) ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:now_to_local_time(Now),
    str:format("~w-~.2.0w-~.2.0w ~.2.0w:~.2.0w:~.2.0w",
	       [Year, Month, Day, Hour, Minute,	Second]).

user_queue(User, Server, Query, Lang) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    US = {LUser, LServer},
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    user_queue_parse_query(LUser, LServer, Query),
    HdrsAll = Mod:read_message_headers(LUser, LServer),
    Hdrs = get_messages_subset(User, Server, HdrsAll),
    FMsgs = format_user_queue(Hdrs),
    [?XC(<<"h1">>,
	 (str:format(translate:translate(Lang, ?T("~s's Offline Messages Queue")),
		     [us_to_list(US)])))]
      ++ [?XREST(?T("Submitted"))] ++
	[?XAE(<<"form">>,
	      [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}],
	      [?XE(<<"table">>,
		   [?XE(<<"thead">>,
			[?XE(<<"tr">>,
			     [?X(<<"td">>), ?XCT(<<"td">>, ?T("Time")),
			      ?XCT(<<"td">>, ?T("From")),
			      ?XCT(<<"td">>, ?T("To")),
			      ?XCT(<<"td">>, ?T("Packet"))])]),
		    ?XE(<<"tbody">>,
			if FMsgs == [] ->
			       [?XE(<<"tr">>,
				    [?XAC(<<"td">>, [{<<"colspan">>, <<"4">>}],
					  <<" ">>)])];
			   true -> FMsgs
			end)]),
	       ?BR,
	       ?INPUTT(<<"submit">>, <<"delete">>,
		       ?T("Delete Selected"))])].

user_queue_parse_query(LUser, LServer, Query) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    case lists:keysearch(<<"delete">>, 1, Query) of
	{value, _} ->
	    user_queue_parse_query(LUser, LServer, Query, Mod);
	_ ->
	    ok
    end.

user_queue_parse_query(LUser, LServer, Query, Mod) ->
    case lists:keytake(<<"selected">>, 1, Query) of
	{value, {_, Seq}, Query2} ->
	    case catch binary_to_integer(Seq) of
		I when is_integer(I), I>=0 ->
		    Mod:remove_message(LUser, LServer, I);
		_ ->
		    ok
	    end,
	    user_queue_parse_query(LUser, LServer, Query2, Mod);
	false ->
	    ok
    end.

us_to_list({User, Server}) ->
    jid:encode({User, Server, <<"">>}).

get_queue_length(LUser, LServer) ->
    count_offline_messages(LUser, LServer).

get_messages_subset(User, Host, MsgsAll) ->
    MaxOfflineMsgs = case get_max_user_messages(User, Host) of
		       Number when is_integer(Number) -> Number;
		       _ -> 100
		     end,
    Length = length(MsgsAll),
    get_messages_subset2(MaxOfflineMsgs, Length, MsgsAll).

get_messages_subset2(Max, Length, MsgsAll) when Length =< Max * 2 ->
    MsgsAll;
get_messages_subset2(Max, Length, MsgsAll) ->
    FirstN = Max,
    {MsgsFirstN, Msgs2} = lists:split(FirstN, MsgsAll),
    MsgsLastN = lists:nthtail(Length - FirstN - FirstN,
			      Msgs2),
    NoJID = jid:make(<<"...">>, <<"...">>),
    Seq = <<"0">>,
    IntermediateMsg = #xmlel{name = <<"...">>, attrs = [],
			     children = []},
    MsgsFirstN ++ [{Seq, NoJID, NoJID, IntermediateMsg}] ++ MsgsLastN.

webadmin_user(Acc, User, Server, Lang) ->
    QueueLen = count_offline_messages(jid:nodeprep(User),
				jid:nameprep(Server)),
    FQueueLen = [?AC(<<"queue/">>,
		     (integer_to_binary(QueueLen)))],
    Acc ++
      [?XCT(<<"h3">>, ?T("Offline Messages:"))] ++
	FQueueLen ++
	  [?C(<<" ">>),
	   ?INPUTT(<<"submit">>, <<"removealloffline">>,
		   ?T("Remove All Offline Messages"))].

-spec delete_all_msgs(binary(), binary()) -> {atomic, any()}.
delete_all_msgs(User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:remove_all_messages(LUser, LServer).

webadmin_user_parse_query(_, <<"removealloffline">>,
			  User, Server, _Query) ->
    case delete_all_msgs(User, Server) of
	{atomic, ok} ->
	    ?INFO_MSG("Removed all offline messages for ~s@~s",
		      [User, Server]),
	    {stop, ok};
	Err ->
	    ?ERROR_MSG("Failed to remove offline messages: ~p",
		       [Err]),
	    {stop, error}
    end;
webadmin_user_parse_query(Acc, _Action, _User, _Server,
			  _Query) ->
    Acc.

%% Returns as integer the number of offline messages for a given user
-spec count_offline_messages(binary(), binary()) -> non_neg_integer().
count_offline_messages(User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    case use_mam_for_user(User, Server) of
	true ->
	    Res = read_db_messages(LUser, LServer),
	    count_mam_messages(LUser, LServer, Res);
	_ ->
	    count_messages_in_db(LUser, LServer)
    end.

-spec count_messages_in_db(binary(), binary()) -> non_neg_integer().
count_messages_in_db(LUser, LServer) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:count_messages(LUser, LServer).

-spec add_delay_info(message(), binary(),
		     undefined | erlang:timestamp()) -> message().
add_delay_info(Packet, LServer, TS) ->
    NewTS = case TS of
		undefined -> erlang:timestamp();
		_ -> TS
	    end,
    Packet1 = xmpp:put_meta(Packet, from_offline, true),
    misc:add_delay_info(Packet1, jid:make(LServer), NewTS,
			<<"Offline storage">>).

-spec get_priority_from_presence(presence()) -> integer().
get_priority_from_presence(#presence{priority = Prio}) ->
    case Prio of
	undefined -> 0;
	_ -> Prio
    end.

export(LServer) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:export(LServer).

import_info() ->
    [{<<"spool">>, 4}].

import_start(LServer, DBType) ->
    Mod = gen_mod:db_mod(DBType, ?MODULE),
    Mod:import(LServer, []).

import(LServer, {sql, _}, DBType, <<"spool">>,
       [LUser, XML, _Seq, _TimeStamp]) ->
    El = fxml_stream:parse_element(XML),
    #message{from = From, to = To} = Msg = xmpp:decode(El, ?NS_CLIENT, [ignore_els]),
    TS = case xmpp:get_subtag(Msg, #delay{stamp = {0,0,0}}) of
	     #delay{stamp = {MegaSecs, Secs, _}} ->
		 {MegaSecs, Secs, 0};
	     false ->
		 erlang:timestamp()
	 end,
    US = {LUser, LServer},
    Expire = find_x_expire(TS, Msg),
    OffMsg = #offline_msg{us = US, packet = El,
			  from = From, to = To,
			  timestamp = TS, expire = Expire},
    Mod = gen_mod:db_mod(DBType, ?MODULE),
    Mod:import(OffMsg).

use_mam_for_user(_User, Server) ->
    mod_offline_opt:use_mam_for_storage(Server).

mod_opt_type(access_max_user_messages) ->
    econf:shaper();
mod_opt_type(store_groupchat) ->
    econf:bool();
mod_opt_type(bounce_groupchat) ->
    econf:bool();
mod_opt_type(use_mam_for_storage) ->
    econf:bool();
mod_opt_type(store_empty_body) ->
    econf:either(
      unless_chat_state,
      econf:bool());
mod_opt_type(db_type) ->
    econf:db_type(?MODULE);
mod_opt_type(cache_size) ->
    econf:pos_int(infinity);
mod_opt_type(cache_life_time) ->
    econf:timeout(second, infinity).

mod_options(Host) ->
    [{db_type, ejabberd_config:default_db(Host, ?MODULE)},
     {access_max_user_messages, max_user_offline_messages},
     {store_empty_body, unless_chat_state},
     {use_mam_for_storage, false},
     {bounce_groupchat, false},
     {store_groupchat, false},
     {cache_size, ejabberd_option:cache_size(Host)},
     {cache_life_time, ejabberd_option:cache_life_time(Host)}].
