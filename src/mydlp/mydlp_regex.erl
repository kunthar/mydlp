%%%
%%%    Copyright (C) 2010 Huseyin Kerem Cevahir <kerem@medra.com.tr>
%%%
%%%--------------------------------------------------------------------------
%%%    This file is part of MyDLP.
%%%
%%%    MyDLP is free software: you can redistribute it and/or modify
%%%    it under the terms of the GNU General Public License as published by
%%%    the Free Software Foundation, either version 3 of the License, or
%%%    (at your option) any later version.
%%%
%%%    MyDLP is distributed in the hope that it will be useful,
%%%    but WITHOUT ANY WARRANTY; without even the implied warranty of
%%%    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%%    GNU General Public License for more details.
%%%
%%%    You should have received a copy of the GNU General Public License
%%%    along with MyDLP.  If not, see <http://www.gnu.org/licenses/>.
%%%--------------------------------------------------------------------------

%%%-------------------------------------------------------------------
%%% @author H. Kerem Cevahir <kerem@medratech.com>
%%% @copyright 2009, H. Kerem Cevahir
%%% @doc Worker for mydlp.
%%% @end
%%%-------------------------------------------------------------------
-module(mydlp_regex).
-author("kerem@medra.com.tr").
-behaviour(gen_server).

-include("mydlp.hrl").

%% API
-export([start_link/0,
	match_bin/2,
	match/2,
%	clean/1,
%	clean/0,
	stop/0]).

%% gen_server callbacks
-export([init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3]).

-include_lib("eunit/include/eunit.hrl").

-record(state, {cache_tree, builtin_tree}).

%%%%%%%%%%%%% MyDLP Thrift RPC API

match_bin(BInKey, Data) -> gen_server:call(?MODULE, {mbin, BInKey, Data}).

match([GI|GIs], Data) -> 
	case match1(GI, Data) of
		true -> true;
		false -> match(GIs, Data)
	end;
match([], _Data) -> false.

match1(GroupId, Data) ->
	gen_server:call(?MODULE, {match, GroupId, Data}).

%clean() -> gen_server:cast(?MODULE, {clean}).
%clean(GroupId) -> gen_server:cast(?MODULE, {clean, GroupId}).

%%%%%%%%%%%%%% gen_server handles

handle_call({match, GroupId, Data}, From, #state{cache_tree=RT} = State) ->
	Worker = self(),
	spawn_link(fun() ->
			{CID, Regexes} = case gb_trees:lookup(GroupId, RT) of
				{value, Rs} -> {nochange, Rs};
				none -> 
					Rs = mydlp_mnesia:get_regexes(GroupId),
					{{add, GroupId, Rs}, Rs}
			end,
			Result = matches_any(Regexes, Data),
			Reply = {Result, CID},
			Worker ! {async_match, Reply, From}
		end),
	{noreply, State, 15000};

handle_call({mbin, BInKey, Data}, From, #state{builtin_tree=BT} = State) ->
	Worker = self(),
	spawn_link(fun() ->
			RE = gb_trees:get(BInKey, BT),
			case re:run(Data, RE, [global, {capture, all, list}]) of
				nomatch -> Worker ! {async_reply, [], From};
				{match, Captured} -> Worker ! {async_reply, lists:append(Captured), From}
			end
		end),
	{noreply, State, 15000};

handle_call(stop, _From, State) ->
	{stop, normalStop, State};

handle_call(_Msg, _From, State) ->
	{noreply, State}.

handle_info({async_reply, Reply, From}, State) ->
	gen_server:reply(From, Reply),
	{noreply, State};

handle_info({async_match, {Result, CID}, From}, #state{cache_tree=RT} = State) ->
	gen_server:reply(From, Result),
	case CID of
		nochange -> {noreply, State};
		{add, GroupId, Rs} -> {noreply, #state{cache_tree=gb_trees:enter(GroupId, Rs, RT)}}
	end;

handle_info(_Info, State) ->
	{noreply, State}.

%%%%%%%%%%%%%%%% Implicit functions

start_link() ->
	case gen_server:start_link({local, ?MODULE}, ?MODULE, [], []) of
		{ok, Pid} -> {ok, Pid};
		{error, {already_started, Pid}} -> {ok, Pid}
	end.

stop() ->
	gen_server:call(?MODULE, stop).

init([]) ->
	BInREs = [
		%{credit_card, rec("\\b(?:\\d[ -]{0,4}?){13,16}\\b")}
		{credit_card, rec("(?:\\d[ -]{0,4}){13,16}")},
		{iban, rec("(?:[a-zA-Z][ -]{0,4}){2}(?:[0-9][ -]{0,4}){2}(?:[a-zA-Z0-9][ -]{0,4}){4}(?:[0-9][ -]{0,4}){7}(?:[a-zA-Z0-9][ -]{0,4}){0,16}")},
		{trid, rec("(?:\\d[ -]{0,2}){11}")}
	],
	BT = insert_all(BInREs, gb_trees:empty()),
	{ok, #state{cache_tree=gb_trees:empty(), builtin_tree=BT}}.

handle_cast(_Msg, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

matches_any([R|RS], Data) ->
	case re:run(Data, R) of
		{match, _Captured} -> true;
		nomatch -> matches_any(RS, Data)
	end;
matches_any([], _Data) -> false.

insert_all([{Key, Val}|Rest], Tree) -> insert_all(Rest, gb_trees:enter(Key, Val, Tree));
insert_all([], Tree) -> Tree.

rec(Regex) -> {ok, Ret} = re:compile(Regex, [unicode]), Ret.