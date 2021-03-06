%%%
%%%    Copyright (C) 2010 Huseyin Kerem Cevahir <kerem@mydlp.com>
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
%%% @author H. Kerem Cevahir <kerem@mydlp.com>
%%% @copyright 2009, H. Kerem Cevahir
%%% @doc Worker for mydlp.
%%% @end
%%%-------------------------------------------------------------------

-ifdef(__MYDLP_NETWORK).

-module(mydlp_smtpc).
-author("kerem@mydlp.com").
-behaviour(gen_server).

-include("mydlp.hrl").
-include("mydlp_smtp.hrl").

%% API
-export([start_link/0,
	mail/1,
	mail/2,
	mail/3,
	stop/0]).

%% gen_server callbacks
-export([init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3]).

-include_lib("eunit/include/eunit.hrl").

-record(state, {smtp_helo_name, smtp_dest_host, smtp_dest_port}).

%%%%%%%%%%%%% MyDLP Thrift RPC API

mail(Message) -> gen_server:cast(?MODULE, {mail, Message}).

mail(Ref, Message) -> gen_server:cast(?MODULE, {mail, Ref, Message}).

mail(From, Rcpt, MessageS) -> gen_server:cast(?MODULE, {mail, From, Rcpt, MessageS}).

%%%%%%%%%%%%%% gen_server handles

handle_call(stop, _From,  State) ->
	{stop, normalStop, State};

handle_call(_Msg, _From, State) ->
	{noreply, State}.

% INSERT INTO log_incedent (id, rule_id, protocol, src_ip, destination, action, matcher, filename, misc)
handle_cast({mail, #message{mail_from=From, rcpt_to=Rcpt, message=MessageS}}, 
		#state{smtp_helo_name=Helo, smtp_dest_host=DHost, smtp_dest_port=DPort} = State) ->
	?ASYNC(fun() -> smtpc:sendmail(DHost, DPort, Helo, From, Rcpt, MessageS) end, 600000),
	{noreply, State};

handle_cast({mail, Ref, #message{mail_from=From, rcpt_to=Rcpt, message=MessageS}}, 
		#state{smtp_helo_name=Helo, smtp_dest_host=DHost, smtp_dest_port=DPort} = State) ->
	?ASYNC(fun() -> 
		smtpc:sendmail(DHost, DPort, Helo, From, Rcpt, MessageS),
		mydlp_spool:delete(Ref),
		mydlp_spool:consume_next("smtp"),
		ok
	end, 600000),
	{noreply, State};

handle_cast({mail, From, Rcpt, MessageS}, 
		#state{smtp_helo_name=Helo, smtp_dest_host=DHost, smtp_dest_port=DPort} = State) ->
	?ASYNC(fun() -> smtpc:sendmail(DHost, DPort, Helo, From, Rcpt, MessageS) end, 600000),
	{noreply, State};

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({async_reply, Reply, From}, State) ->
	gen_server:reply(From, Reply),
	{noreply, State};

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
	HeloName = ?CFG(smtp_helo_name),
	Host = ?CFG(smtp_next_hop_host),
	Port = ?CFG(smtp_next_hop_port),

	ConsumeFun = fun(Ref, Item) ->
		mydlp_smtpc:mail(Ref, Item)
	end,
	mydlp_spool:create_spool("smtp"),
	mydlp_spool:register_consumer("smtp", ConsumeFun),

	{ok, #state{smtp_helo_name=HeloName, smtp_dest_host=Host, smtp_dest_port=Port}}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

-endif.

