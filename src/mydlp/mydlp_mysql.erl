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

-module(mydlp_mysql).
-author("kerem@mydlp.com").
-behaviour(gen_server).

-include("mydlp.hrl").
-include("mydlp_schema.hrl").

%% API
-export([start_link/0,
	compile_filters/0,
	compile_customer/1,
	push_log/9,
	push_log/10,
	archive_log/6,
	push_smb_discover/1,
	is_multisite/0,
	get_denied_page/0,
	new_afile/0,
	update_afile/6,
	repopulate_mnesia/0,
	stop/0]).

%% gen_server callbacks
-export([init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3]).

-include_lib("eunit/include/eunit.hrl").

-record(state, {host, port, user, password, database, pool_size, master_pid, pool_pids}).

%%%%%%%%%%%%% MyDLP Thrift RPC API

push_log(Proto, RuleId, Action, Ip, User, To, Matcher, FileS, Misc) ->
	gen_server:cast(?MODULE, {push_log, {Proto, RuleId, Action, Ip, User, To, Matcher, FileS, Misc}}).

push_log(Proto, RuleId, Action, Ip, User, To, Matcher, FileS, #file{} = File, Misc) ->
	gen_server:cast(?MODULE, {push_log, {Proto, RuleId, Action, Ip, User, To, Matcher, FileS, File, Misc}}).

archive_log(Proto, RuleId, Ip, User, To, AFileId) ->
	gen_server:cast(?MODULE, {archive_log, {Proto, RuleId, Ip, User, To, AFileId}}).

push_smb_discover(XMLResult) ->
	gen_server:cast(?MODULE, {push_smb_discover, XMLResult}).

repopulate_mnesia() ->
	gen_server:cast(?MODULE, repopulate_mnesia).

compile_filters() -> 
	gen_server:call(?MODULE, compile_filters, 60000).

compile_customer(CustomerId) when is_integer(CustomerId) ->
	gen_server:call(?MODULE, {compile_customer, CustomerId} , 60000).

is_multisite() -> gen_server:call(?MODULE, is_multisite).

get_denied_page() -> gen_server:call(?MODULE, get_denied_page).

new_afile() -> gen_server:call(?MODULE, new_afile, 60000).

update_afile(AFileId, Filename, MimeType, Size, ArchivePath, ContentText) -> 
	gen_server:cast(?MODULE, {update_afile, AFileId, Filename, MimeType, Size, ArchivePath, ContentText}).

%%%%%%%%%%%%%% gen_server handles

handle_call({compile_customer, CustomerId}, From, State) ->
	Worker = self(),
	?ASYNC(fun() ->
			mydlp_mnesia:remove_site(CustomerId),
			Reply = populate_site(CustomerId),
                        Worker ! {async_reply, Reply, From}
		end, 60000),
        {noreply, State};

handle_call(compile_filters, From, State) ->
	Worker = self(),
	?ASYNC(fun() ->
			mydlp_mnesia:truncate_nondata(),
			Reply = populate(),
                        Worker ! {async_reply, Reply, From}
		end, 60000),
        {noreply, State};

handle_call(is_multisite, _From, State) ->
	{ok, ATQ} = psq(app_type),
	Reply = case ATQ of
		[] -> false;
		[[0]] -> false;
		[[1]] -> true end,
        {reply, Reply, State};

handle_call(get_denied_page, _From, State) ->
	% Probably will create problems in multisite use.
	{ok, DPQ} = psq(denied_page_by_cid, [mydlp_mnesia:get_dcid()]),
	Reply = case DPQ of
		[[DeniedPage]] when is_binary(DeniedPage) -> DeniedPage;
		_Else -> not_found end,
        {reply, Reply, State};

handle_call(new_afile, _From, State) ->
	% Probably will create problems in multisite use.
	{atomic, AFEId} = transaction(fun() ->
		psqt(new_archive_file_entry),
		last_insert_id_t() end, 30000),
	Reply = AFEId,	
        {reply, Reply, State};

handle_call(stop, _From,  State) ->
	{stop, normalStop, State};

handle_call(_Msg, _From, State) ->
	{noreply, State}.

% INSERT INTO log_archive (id, customer_id, rule_id, protocol, src_ip, src_user, destination, log_archive_file_id)
handle_cast({archive_log, {Proto, RuleId, Ip, User, To, AFileId}}, State) ->
	?ASYNC0(fun() ->
		{CustomerId, RuleId1, Ip1, User1} = pre_push_log(RuleId, Ip, User),
		psq(insert_archive, [CustomerId, RuleId1, Proto, Ip1, User1, To, AFileId], 30000)
	end),
	{noreply, State};

% INSERT INTO log_incedent (id, rule_id, protocol, src_ip, destination, action, matcher, filename, misc)
handle_cast({push_log, {Proto, RuleId, Action, Ip, User, To, Matcher, FileS, Misc}}, State) ->
	?ASYNC0(fun() ->
		{CustomerId, RuleId1, Ip1, User1} = pre_push_log(RuleId, Ip, User),
		psq(insert_incident, 
			[CustomerId, RuleId1, Proto, Ip1, User1, To, Action, Matcher, FileS, Misc])
	end),
	{noreply, State};

handle_cast({push_log, {Proto, RuleId, Action, Ip, User, To, Matcher, FileS, File, Misc}}, State) ->
	?ASYNC0(fun() ->
		{ok, Path} = mydlp_api:quarantine(File),
		Size = mydlp_api:binary_size(File#file.data),
		MimeType = (File#file.mime_type),
		{CustomerId, RuleId1, Ip1, User1} = pre_push_log(RuleId, Ip, User),
		transaction( fun() ->
			psqt(insert_incident, [CustomerId, RuleId1, Proto, Ip1, User1, To, Action, Matcher, FileS, Misc]),
			psqt(insert_incident_file, [Path, MimeType, Size]) end)
	end),
	{noreply, State};

handle_cast({push_smb_discover, XMLResult}, State) ->
	?ASYNC0(fun() ->
		transaction( fun() ->
			psqt(delete_all_smb_discover),
			psqt(insert_smb_discover, [mydlp_mnesia:get_dcid(), XMLResult]) end )
	end),
	{noreply, State};

handle_cast({update_afile, AFileId, Filename, MimeType, Size, ArchivePath, ContentText}, State) ->
	% Probably will create problems in multisite use.
	?ASYNC(fun() ->
		{atomic, ADataId} = transaction(fun() ->
			mysql:fetch(<<"LOCK TABLE log_archive_data WRITE">>),
			Query =  psqt(archive_data_by_path, [ArchivePath]),
			AId = case Query of
				{ok, [] } ->	psqt(insert_archive_data, [MimeType, Size, ArchivePath, ContentText]),
						last_insert_id_t();
				{ok, [[Id]|_]} -> Id end,
			mysql:fetch(<<"UNLOCK TABLES">>), AId
			end, 60000),
		psq(update_archive_file, [Filename, ADataId, AFileId], 30000)
	end, 100000),
	{noreply, State};

handle_cast(repopulate_mnesia, State) ->
	% Probably will create problems in multisite use.
	?ASYNC0(fun() ->
		mydlp_mnesia:wait_for_tables(),
		case mydlp_mysql:is_multisite() of
			false -> mydlp_mysql:compile_customer(mydlp_mnesia:get_dcid());
			true -> ok % should be implemented for multi site usage
		end
	end),
	{noreply, State};

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({async_reply, Reply, From}, State) ->
	gen_server:reply(From, Reply),
	{noreply, State};

handle_info({'DOWN', _, _, MPid , _}, #state{master_pid=MPid} = State) ->
	{stop, normalStop, State};

handle_info({'DOWN', _, _, Pid , _}, #state{host=Host,
		user=User, password=Password, database=DB, 
		pool_pids=PoolPids} = State) ->
	PoolPids1 = lists:delete(Pid, PoolPids),
	case mysql:connect(p, Host, undefined, User, Password, DB, true) of
		{ok,NewPid} -> {noreply, State#state{pool_pids=[NewPid|PoolPids1]}};
		_Else -> {stop, normalStop, State#state{pool_pids=PoolPids1}} end;

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
	Host = ?CFG(mysql_host),
	Port = ?CFG(mysql_port),
	User = ?CFG(mysql_user),
	Password = ?CFG(mysql_password),
	DB = ?CFG(mysql_database),
	PoolSize = ?CFG(mysql_pool_size),
	
	{ok, MPid} = mysql:start_link(p, Host, Port, User, Password, DB, fun(_,_,_,_) -> ok end),
	erlang:monitor(process, MPid), 
	
	PoolReturns = [ mysql:connect(p, Host, undefined, User, Password, DB, true) || _I <- lists:seq(1, PoolSize)],
	PPids = [ P || {ok, P} <- PoolReturns ],
	[ erlang:monitor(process, P) || P <- PPids ],

	[ mysql:prepare(Key, Query) || {Key, Query} <- [
		{last_insert_id, <<"SELECT last_insert_id()">>},
		{filters, <<"SELECT id,name,default_action FROM sh_filter WHERE is_active=TRUE">>},
		{filters_by_cid, <<"SELECT id,name,default_action FROM sh_filter WHERE is_active=TRUE and customer_id=?">>},
		{rules_by_fid, <<"SELECT id,action FROM sh_rule WHERE is_nw_active=TRUE and filter_id=?">>},
		{tdomains_by_rid, <<"SELECT domain_name FROM nw_rule_white_domain WHERE rule_id=?">>},
		{cid_of_rule_by_id, <<"SELECT f.customer_id FROM sh_rule AS r, sh_filter AS f WHERE r.filter_id=f.id AND r.id=?">>},
		{ipr_by_rule_id, <<"SELECT a.customer_id,a.base_ip,a.subnet FROM sh_ipr AS i, sh_ipaddress AS a WHERE i.parent_rule_id=? AND i.sh_ipaddress_id=a.id">>},
		{user_by_rule_id, <<"SELECT eu.id, eu.username FROM sh_ad_entry_user AS eu, sh_ad_cross AS c, sh_ad_entry AS e, sh_ad_group AS g, sh_ad_rule_cross AS rc WHERE rc.parent_rule_id=? AND rc.group_id=g.id AND rc.group_id=c.group_id AND c.entry_id=e.id AND c.entry_id=eu.entry_id">>},
		%{user_by_rule_id, <<"SELECT eu.id, eu.username FROM sh_ad_entry_user AS eu, sh_ad_cross AS c, sh_ad_rule_cross AS rc WHERE rc.parent_rule_id=? AND rc.group_id=c.group_id AND c.entry_id=eu.entry_id">>},
		{match_by_rule_id, <<"SELECT DISTINCT m.id,m.func FROM sh_match AS m, sh_func_params AS p WHERE m.parent_rule_id=? AND p.match_id=m.id AND p.param <> \"0\" ">>},
		{params_by_match_id, <<"SELECT DISTINCT p.param FROM sh_match AS m, sh_func_params AS p WHERE m.id=? AND p.match_id=m.id AND p.param <> \"0\" ">>},
		{file_params_by_match_id, <<"SELECT DISTINCT m.enable_shash, m.sentence_hash_count, m.sentence_hash_percentage, m.enable_bayes, m.bayes_average, m.enable_whitefile FROM sh_match AS m, sh_func_params AS p WHERE m.id=? AND p.match_id=m.id AND p.param <> \"0\" ">>},
		{mimes, <<"SELECT m.id, c.group_id, m.mime, m.extension FROM nw_mime_type_cross AS c, nw_mime_type m WHERE c.mime_id=m.id">>},
		{mimes_by_cid, <<"SELECT m.id, c.group_id, m.mime, m.extension FROM nw_mime_type_cross AS c, nw_mime_type m WHERE c.mime_id=m.id and m.customer_id=?">>},
		{regexes, <<"SELECT r.id, c.group_id, r.regex FROM sh_regex_cross AS c, sh_regex r WHERE c.regex_id=r.id">>},
		{regexes_by_cid, <<"SELECT r.id, c.group_id, r.regex FROM sh_regex_cross AS c, sh_regex r WHERE c.regex_id=r.id and r.customer_id=?">>},
		{customer_by_id, <<"SELECT id,static_ip FROM sh_customer WHERE id=?">>},
		{app_type, <<"SELECT type FROM app_type">>},
		{denied_page_by_cid, <<"SELECT html_text FROM sh_warning_page WHERE customer_id=?">>},
		{defaultrule_by_cid, <<"SELECT action, cc_count, ssn_count, iban_count, canada_sin_count, france_insee_count, uk_nino_count, tr_tck_count FROM sh_defaultrule_predefined WHERE enabled <> 0 and customer_id=?">>},
		{dr_fhash_by_cid, <<"SELECT hash FROM sh_defaultrule_filehash WHERE customer_id=?">>},
		{dr_wfhash_by_cid, <<"SELECT hash FROM sh_defaultrule_white_filehash WHERE customer_id=?">>},
		{insert_incident, <<"INSERT INTO log_incedent (id, customer_id, rule_id, protocol, src_ip, src_user, destination, action, matcher, filename, misc) VALUES (NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)">>},
		{insert_incident_file, <<"INSERT INTO log_incedent_file (id, log_incedent_id, path, mime_type, size) VALUES (NULL, last_insert_id(), ?, ?, ?)">>},
		{insert_archive, <<"INSERT INTO log_archive (id, customer_id, rule_id, protocol, src_ip, src_user, destination, log_archive_file_id) VALUES (NULL, ?, ?, ?, ?, ?, ?, ?)">>},
		{new_archive_file_entry, <<"INSERT INTO log_archive_file (id) VALUES (NULL)">>},
		{update_archive_file, <<"UPDATE log_archive_file SET filename=?, log_archive_data_id=? WHERE id = ?">>},
		{archive_data_by_path, <<"SELECT id FROM log_archive_data WHERE path = ?">>},
		{insert_archive_data, <<"INSERT INTO log_archive_data (id, mime_type, size, path, content_text) VALUES (NULL, ?, ?, ?, ?)">>},
		{delete_all_smb_discover, <<"DELETE FROM log_shared_folder">>},
		{insert_smb_discover, <<"INSERT INTO log_shared_folder (id, customer_id, result) VALUES (NULL, ?, ?)">>}
	]],

	{ok, #state{host=Host, port=Port, 
			user=User, password=Password, 
			database=DB, pool_size=PoolSize, 
			master_pid=MPid, pool_pids=PPids}}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%%%%%%%%%% internal api

psq(PreparedKey) -> psq(PreparedKey, []).

psq(PreparedKey, Params) -> psq(PreparedKey, Params, 5000).

psq(PreparedKey, Params, Timeout) ->
	case mysql:execute(p, PreparedKey, Params, Timeout) of
		{data,{mysql_result,_,Result,_,_}} -> {ok, Result};
		{updated,{mysql_result, _,_,RowCount,_}} -> {updated, RowCount};
		Else -> throw({error, Else})
	end.

last_insert_id_t() ->
	{ok, [[LIId]]} = psqt(last_insert_id), LIId.

transaction(Fun) -> transaction(Fun, 5000).

transaction(Fun, Timeout) -> mysql:transaction(p, Fun, Timeout).

psqt(PreparedKey) -> psqt(PreparedKey, []).

psqt(PreparedKey, Params) ->
	case mysql:execute(PreparedKey, Params) of
		{data,{mysql_result,_,Result,_,_}} -> {ok, Result};
		{updated,{mysql_result, _,_,RowCount,_}} -> {updated, RowCount};
		Else -> throw({error, Else})
	end.

%%%%%%%%%%%% internal

populate() -> 
	{ok, FQ} = psq(filters),
	populate_filters(FQ),
	{ok, MQ} = psq(mimes),
	populate_mimes(MQ),
	{ok, RQ} = psq(regexes),
	populate_regexes(RQ),
	ok.

populate_site(CustomerId) ->
	{ok, FQ} = psq(filters_by_cid, [CustomerId]),
	populate_filters(FQ, CustomerId),
	{ok, MQ} = psq(mimes_by_cid, [CustomerId]),
	populate_mimes(MQ, CustomerId),
	{ok, RQ} = psq(regexes_by_cid, [CustomerId]),
	populate_regexes(RQ, CustomerId),
	{ok, SQ} = psq(customer_by_id, [CustomerId]),
	populate_site_desc(SQ),
	{ok, DQ} = psq(defaultrule_by_cid, [CustomerId]),
	populate_default_rule(DQ, CustomerId),
	{ok, FHQ} = psq(dr_fhash_by_cid, [CustomerId]),
	populate_file_hashes(FHQ, bl, CustomerId),
	{ok, WFHQ} = psq(dr_wfhash_by_cid, [CustomerId]),
	populate_file_hashes(WFHQ, wl, CustomerId),
	ok.

populate_filters(Rows) -> populate_filters(Rows, mydlp_mnesia:get_dcid()).

populate_filters([[Id, Name, DActionS]|Rows], CustomerId) ->
	DAction = rule_action_to_tuple(DActionS),
	{ok, RQ} = psq(rules_by_fid, [Id]),
	populate_rules(RQ, Id),
	F = #filter{id=Id, customer_id=CustomerId, name=Name, default_action=DAction},
	mydlp_mnesia:write(F),
	populate_filters(Rows, CustomerId);
populate_filters([], _CustomerId) -> ok.

% Id, Action, [Matchers]	
% {Func, FuncParams}
populate_default_rule([], _CustomerId) -> ok;
populate_default_rule([[ActionS, CCCount, SSNCount, IBANCount, SINCount, INSEECount, NINOCount, TRIDCount]], CustomerId) ->
	DefaultRuleId = {dr, CustomerId},
	Action = rule_action_to_tuple(ActionS),

	WFMatch = [{whitefile_dr, []}],
	CCMatch = case CCCount of
		0 -> [];
		Count -> [{cc_match, [{count, Count}]}] end,
	SSNMatch = case SSNCount of
		0 -> [];
		Count2 -> [{ssn_match, [{count, Count2}]}] end,
	IBANMatch = case IBANCount of
		0 -> [];
		Count3 -> [{iban_match, [{count, Count3}]}] end,
	SINMatch = case SINCount of
		0 -> [];
		Count4 -> [{canada_sin_match, [{count, Count4}]}] end,
	INSEEMatch = case INSEECount of
		0 -> [];
		Count5 -> [{france_insee_match, [{count, Count5}]}] end,
	NINOMatch = case NINOCount of
		0 -> [];
		Count6 -> [{uk_nino_match, [{count, Count6}]}] end,
	TRIDMatch = case TRIDCount of
		0 -> [];
		Count7 -> [{trid_match, [{count, Count7}]}] end,
	MD5Match = [{md5_dr_match, []}],

	Matchers = lists:append([WFMatch,
				CCMatch, 
				SSNMatch, 
				IBANMatch, 
				SINMatch,
				INSEEMatch,
				NINOMatch,
				TRIDMatch,
				MD5Match]),

	ResolvedRule = {DefaultRuleId, Action, Matchers},
	DR = #default_rule{customer_id=CustomerId, resolved_rule=ResolvedRule},
	mydlp_mnesia:write(DR).

populate_rules([[Id, ActionS ] |Rows], FilterId) ->
	Action = rule_action_to_tuple(ActionS),
	populate_rule(Id, Action, FilterId),
	populate_rules(Rows, FilterId);
populate_rules([], _FilterId) -> ok.

populate_rule(Id, Action, FilterId) ->
	Parent = {rule, Id},
	{ok, IQ} = psq(ipr_by_rule_id, [Id]),
	populate_iprs(IQ, Parent),
	{ok, UQ} = psq(user_by_rule_id, [Id]),
	populate_users(UQ, Parent),
	{ok, MQ} = psq(match_by_rule_id, [Id]),
	populate_matches(MQ, Parent),
	%{ok, MGQ} = psq(mgroup_by_rule_id, [Id]),
	%populate_matchGroups(MGQ, Parent),
	{ok, TDQ} = psq(tdomains_by_rid, [Id]),
	TDs = lists:flatten(TDQ),
	R = #rule{id=Id, action=Action, filter_id=FilterId, trusted_domains=TDs},
	mydlp_mnesia:write(R).

populate_iprs([[CustomerId, Base, Subnet]| Rows], Parent) ->
	B1 = int_to_ip(Base),
	S1 = int_to_ip(Subnet),
	Id = mydlp_mnesia:get_unique_id(ipr),
	I = #ipr{id=Id, customer_id=CustomerId, parent=Parent, ipbase=B1, ipmask=S1},
	mydlp_mnesia:write(I),
	populate_iprs(Rows, Parent);
populate_iprs([], _Parent) -> ok.

populate_users([[Id, Username]| Rows], Parent) ->
	U = #m_user{id=Id, parent=Parent, username=Username},
	mydlp_mnesia:write(U),
	populate_users(Rows, Parent);
populate_users([], _Parent) -> ok.

int_to_ip(nil) -> nil;
int_to_ip(N4) ->
	I4 = N4 rem 256,
	N3 = N4 div 256,
	I3 = N3 rem 256,
	N2 = N3 div 256,
	I2 = N2 rem 256,
	N1 = N2 div 256,
	I1 = N1,
	I1 = N1 rem 256,
	{I1, I2, I3, I4}.

ip_to_int(nil) -> nil;
ip_to_int({I1,I2,I3,I4}) ->
	(I1*256*256*256)+(I2*256*256)+(I3*256)+I4.

populate_matches(Rows, Parent) -> populate_matches(Rows, Parent, []).

populate_matches([[Id, Func]| Rows], Parent, Matches) ->
	Match = populate_match(Id, Func, Parent),
	populate_matches(Rows, Parent, [Match|Matches]);
populate_matches([], _Parent, Matches) -> 
	Matches1 = expand_matches(lists:reverse(Matches)),
	Matches2 = whitefile(Matches1),
	write_matches(Matches2),
	ok.

expand_matches(Matches) -> expand_matches(Matches, []).

expand_matches([#match{func={group, Group}, func_params=FuncParams, 
		parent=Parent, orig_id=OrigId}|Matches], Returns) -> 
	GReturn = mydlp_matchers:Group(FuncParams),
	GMatchers = [new_match(OrigId, Parent, F, FP) || {F,FP} <- GReturn],
	expand_matches(Matches, lists:append(lists:reverse(GMatchers), Returns));
expand_matches([Match|Matches], Returns) -> expand_matches(Matches, [Match|Returns]);
expand_matches([], Returns) -> lists:reverse(Returns).
	
whitefile(Matches) -> whitefile(Matches, []).

whitefile([#match{func=whitefile} = Match|Matches], Returns) -> 
	L1 = lists:append([lists:reverse(Matches), Returns, [Match]]),
	lists:reverse(L1);
whitefile([Match|Matches], Returns) -> whitefile(Matches, [Match|Returns]);
whitefile([], Returns) -> lists:reverse(Returns).

new_match(Id, Parent, Func) -> new_match(Id, Parent, Func, []).

new_match(Id, Parent, Func, FuncParams) ->
	#match{orig_id=Id, parent=Parent, func=Func, func_params=FuncParams}.

write_matches(Matches) ->
	Matches1 = [ M#match{id=mydlp_mnesia:get_unique_id(match)} || M <- Matches ],
	mydlp_mnesia:write(Matches1).

populate_match(Id, <<"e_archive">>, Parent) ->
	Func = e_archive_match,
	new_match(Id, Parent, Func);

populate_match(Id, <<"e_file">>, Parent) ->
	Func = e_file_match,
	new_match(Id, Parent, Func);

populate_match(Id, <<"i_archive">>, Parent) ->
	Func = i_archive_match,
	new_match(Id, Parent, Func);

populate_match(Id, <<"i_binary">>, Parent) ->
	Func = i_binary_match,
	new_match(Id, Parent, Func);

populate_match(Id, <<"p_text">>, Parent) ->
	Func = p_text_match,
	[ScoreS] = get_func_params(Id),
	FuncParams = [{score, mydlp_api:binary_to_integer(ScoreS)}],
	new_match(Id, Parent, Func, FuncParams);

populate_match(Id, <<"trid">>, Parent) ->
	Func = trid_match,
	[CountS] = get_func_params(Id),
	FuncParams = [{count, mydlp_api:binary_to_integer(CountS)}],
	new_match(Id, Parent, Func, FuncParams);

populate_match(Id, <<"ssn">>, Parent) ->
	Func = ssn_match,
	[CountS] = get_func_params(Id),
	FuncParams = [{count, mydlp_api:binary_to_integer(CountS)}],
	new_match(Id, Parent, Func, FuncParams);

populate_match(Id, <<"iban">>, Parent) ->
	Func = iban_match,
	[CountS] = get_func_params(Id),
	FuncParams = [{count, mydlp_api:binary_to_integer(CountS)}],
	new_match(Id, Parent, Func, FuncParams);

populate_match(Id, <<"cc">>, Parent) ->
	Func = cc_match,
	[CountS] = get_func_params(Id),
	FuncParams = [{count, mydlp_api:binary_to_integer(CountS)}],
	new_match(Id, Parent, Func, FuncParams);

populate_match(Id, <<"canada_sin">>, Parent) ->
	Func = canada_sin_match,
	[CountS] = get_func_params(Id),
	FuncParams = [{count, mydlp_api:binary_to_integer(CountS)}],
	new_match(Id, Parent, Func, FuncParams);

populate_match(Id, <<"france_insee">>, Parent) ->
	Func = france_insee_match,
	[CountS] = get_func_params(Id),
	FuncParams = [{count, mydlp_api:binary_to_integer(CountS)}],
	new_match(Id, Parent, Func, FuncParams);

populate_match(Id, <<"uk_nino">>, Parent) ->
	Func = uk_nino_match,
	[CountS] = get_func_params(Id),
	FuncParams = [{count, mydlp_api:binary_to_integer(CountS)}],
	new_match(Id, Parent, Func, FuncParams);

populate_match(Id, <<"scode">>, Parent) ->
	Func = scode_match,
	[ScoreS] = get_func_params(Id),
	FuncParams = [{score, mydlp_api:binary_to_integer(ScoreS)}],
	new_match(Id, Parent, Func, FuncParams);

populate_match(Id, <<"scode_ada">>, Parent) ->
	Func = scode_ada_match,
	[ScoreS] = get_func_params(Id),
	FuncParams = [{score, mydlp_api:binary_to_integer(ScoreS)}],
	new_match(Id, Parent, Func, FuncParams);

populate_match(Id, <<"mime">>, Parent) ->
	Func = mime_match,
	GroupsS = get_func_params(Id),
	FuncParams = [ mydlp_api:binary_to_integer(G) || G <- GroupsS ],
	new_match(Id, Parent, Func, FuncParams);

populate_match(Id, <<"regex">>, Parent) ->
	Func = regex_match,
	GroupsS = get_func_params(Id),
	FuncParams = [ mydlp_api:binary_to_integer(G) || G <- GroupsS ],
	new_match(Id, Parent, Func, FuncParams);

populate_match(Id, <<"file">>, Parent) ->
	Func = {group,file},
	GroupsS = get_func_params(Id),
	GroupsI = [ mydlp_api:binary_to_integer(G) || G <- GroupsS ],
	{ok, [[SentenceHashI, SHCount, SHPercI, BayesI, BThresI, WhiteFileI]]} = psq(file_params_by_match_id, [Id]),
	SentenceHash = case SentenceHashI of 0 -> false; _ -> true end,
	SHPerc = SHPercI / 100,
	Bayes = case BayesI of 0 -> false; _ -> true end,
	BThres = BThresI / 100,
	WhiteFile = case WhiteFileI of 0 -> false; _ -> true end,

	FuncParams = [{shash,SentenceHash}, {shash_count,SHCount}, {shash_percentage, SHPerc},
			{bayes, Bayes}, {bayes_threshold, BThres},
			{whitefile, WhiteFile}, {group_ids, GroupsI}],
	new_match(Id, Parent, Func, FuncParams);

populate_match(Id, Matcher, _) -> throw({error, {unsupported_match, Id, Matcher} }).

get_func_params(MatchId) ->
	{ok, PQ} = psq(params_by_match_id, [MatchId]),
	lists:append(PQ).

populate_mimes(Rows) -> populate_mimes(Rows, mydlp_mnesia:get_dcid()).

populate_mimes([[Id, GroupId, Mime, Ext]|Rows], CustomerId) ->
	M = #mime_type{id=Id, customer_id=CustomerId, group_id=GroupId, mime=Mime, extension=Ext},
	mydlp_mnesia:write(M),
	populate_mimes(Rows, CustomerId);
populate_mimes([], _CustomerId) -> ok.


populate_regexes(Rows) -> populate_regexes(Rows, mydlp_mnesia:get_dcid()).

populate_regexes(Rows, CustomerId) -> 
	populate_regexes1(Rows, CustomerId),
	mydlp_mnesia:compile_regex().

populate_regexes1([[Id, GroupId, Regex]|Rows], CustomerId) ->
	R = #regex{id=Id, customer_id=CustomerId, group_id=GroupId, plain=Regex},
	mydlp_mnesia:write(R),
	populate_regexes1(Rows, CustomerId);
populate_regexes1([], _CustomerId) -> ok.

populate_site_desc([[Id, StaticIpI]]) ->
	IpAddr = int_to_ip(StaticIpI),
	S = #site_desc{customer_id=Id, ipaddr=IpAddr},
	mydlp_mnesia:write(S), ok.

populate_file_hashes([[Hash]|Rows], Tag, CustomerId) ->
	F = #file_hash{id=mydlp_mnesia:get_unique_id(file_hash),
			file_id={Tag, CustomerId},
			md5=mydlp_api:hex2bytelist(Hash) },
	mydlp_mnesia:write(F),
	populate_file_hashes(Rows, Tag, CustomerId);
populate_file_hashes([], _Tag, _CustomerId) -> ok.

get_rule_cid(RuleId) ->
	case psq(cid_of_rule_by_id, [RuleId]) of
		{ok, [[CustomerId]]} -> CustomerId;
		_Else -> 0 end.

rule_action_to_tuple(<<"pass">>) -> pass;
rule_action_to_tuple(<<"log">>) -> log;
rule_action_to_tuple(<<"block">>) -> block;
rule_action_to_tuple(<<"quarantine">>) -> quarantine;
rule_action_to_tuple(<<"archive">>) -> archive;
rule_action_to_tuple(<<"">>) -> pass;
rule_action_to_tuple(Else) -> throw({error, unsupported_action_type, Else}).

pre_push_log(RuleId, Ip, User) -> 
	{CustomerId, RuleId1} = case RuleId of
		{dr, CId} -> {CId, 0};
		-1 = RuleId -> {mydlp_mnesia:get_dcid(), RuleId};	% this shows default action had been enforeced 
							% this should be refined for multisite use
		RId when is_integer(RId) -> {get_rule_cid(RId), RId} end,
	User1 = case User of
		nil -> null;
		Else -> Else
	end,
	Ip1 = case ip_to_int(Ip) of
		nil -> null;
		Else2 -> Else2
	end,
	{CustomerId, RuleId1, Ip1, User1}.

-endif.

