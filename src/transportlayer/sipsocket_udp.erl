%%%-------------------------------------------------------------------
%%% File    : sipsocket_udp.erl
%%% @author   Fredrik Thulin <ft@it.su.se>
%%% @doc      Transportlayer UDP all-in-one handler. Receive UDP
%%%           datagrams and, if they are not keep alives (or too
%%%           short), spawn sipserver:process(...) on the received
%%%           packets. Send packets using either our IPv4 or our IPv6
%%%           socket.
%%%
%%% Note    : This module should be split in two, one server process
%%%           and one interface module which can be a sipsocket
%%%           behaviour module, like the TCP sipsocket code.
%%%
%%% Note    : Our UDP code does not support multiple interfaces
%%%           correctly. We should get one socket per interface (and
%%%           protocol), to be able to implement RFC3581 (rport)
%%%           correctly.
%%%
%%% @since    15 Dec 2003 by Fredrik Thulin <ft@it.su.se>
%%% @end
%%%-------------------------------------------------------------------
-module(sipsocket_udp).
%%-compile(export_all).

-behaviour(gen_server).

%%--------------------------------------------------------------------
%% External exports
%%--------------------------------------------------------------------
-export([
	 start_link/0,
	 send/5,
	 is_reliable_transport/1,
	 get_socket/1,
	 get_specific_socket/1,
	 get_raw_socket/1,
	 get_remote_peer/1,
	 close_socket/1,

	 test/0
	]).

%%--------------------------------------------------------------------
%% Internal exports - gen_server callbacks
%%--------------------------------------------------------------------
-export([
	 init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3
	]).

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------
-include("sipsocket.hrl").
-include("stun.hrl").

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------
%% @type state() = #state{}.
%%                 no description
-record(state, {inet_socketlist  = [],	%% list() of {Socket, SipSocket}
		inet6_socketlist = [],	%% list() of {Socket, SipSocket}
		socketlist,
		test_leader
	       }).

%%--------------------------------------------------------------------
%% Macros
%%--------------------------------------------------------------------
-define(SOCKETOPTS, [{reuseaddr, true}, binary]).
%% v6 sockets have a default receive buffer size of 1k in Erlang R9C-0
-define(SOCKETOPTSv6, [{reuseaddr, true}, binary, inet6, {buffer, 8 * 1024}]).

%% LINUX_IPPROTO_IPv6 = 41 is located in
%% /usr/include/linux/in.h from linux-libc-dev
%% /usr/include/netinet/in.h from libc6-dev
-define(LINUX_IPPROTO_IPV6, 41).
%% and LINUX_IPV6_V6ONLY = 26 in
%% * /usr/include/linux/in6.h from linux-libc-dev
%% * /usr/include/bits/in.h from libc6-dev
-define(LINUX_IPV6_V6ONLY, 26).

%% timeout (in milliseconds) for get_socket/1
-define(GET_SOCKET_TIMEOUT, 1500).

%% registered name of gen_server
-define(SIPSOCKET_UDP_SERVER, sipsocket_udp).
-define(SIPSOCKET_UDP_TABLE_NAME, yxa_sipsocket_udp).

%%====================================================================
%% External functions
%%====================================================================

%%--------------------------------------------------------------------
%% @spec    () -> term()
%%
%% @doc     Starts the server
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SIPSOCKET_UDP_SERVER}, ?MODULE, [], []).

%%====================================================================
%% Server functions
%%====================================================================

%%--------------------------------------------------------------------
%% @spec    ([]) ->
%%            {ok, State}    |
%%            {stop, Reason}
%%
%%            Reason = string()
%%
%% @doc     Initiates the server
%% @hidden
%% @end
%%--------------------------------------------------------------------
init([]) ->
    Port = sipsocket:get_listenport(udp),  %% same for UDP and UDPv6
    init([Port, undefined]);

init([Port, TestLeader]) when is_integer(Port), (is_pid(TestLeader) orelse TestLeader == undefined) ->
    IPv4Spec =
	lists:foldl(fun(IP, Acc) ->
			    case inet_parse:ipv4_address(IP) of
				{ok, IPt} ->
				    [{udp, IPt, Port} | Acc];
				_ ->
				    Acc
			    end
		    end, [], lists:reverse(siphost:myip_list() ++ ["127.0.0.1"])),
%%		    end, [], lists:reverse(siphost:myip_list())),
    Spec =
	case yxa_config:get_env(enable_v6) of
	    {ok, true} ->
		[{udp6, {0,0,0,0,0,0,0,0}, Port} | IPv4Spec];
	    {ok, false} ->
		IPv4Spec
	end,

    ets:new(?SIPSOCKET_UDP_TABLE_NAME, [public, bag, named_table]),

    start_listening(Spec, #state{socketlist  = socketlist:empty(),
				 test_leader = TestLeader
				}).

%%--------------------------------------------------------------------
%% @spec    (Spec, State) ->
%%            {ok, State}    |
%%            {stop, Reason}
%%
%%            Spec  = [{Proto, IP, Port}]
%%            Proto = udp | udp6
%%            IP    = {A,B,C,D} | {A,B,C,D,E,F,G,H,I}
%%            Port  = integer()
%%
%%            Reason = string()
%%
%% @doc     Begin listening on port Port for interface with IP IP.
%% @end
%%--------------------------------------------------------------------
start_listening([{udp, IP, Port} | T], State) when is_integer(Port), is_record(State, state) ->
    SocketOpts = [{ip, IP} | ?SOCKETOPTS],
    case (catch gen_udp:open(Port, SocketOpts)) of
	{ok, Socket} ->
	    HostPort1 = get_localaddr(Socket, "0.0.0.0"),
	    HostPort = HostPort1#hp{l_port = Port},
	    SipSocket =
		#sipsocket{module	= sipsocket_udp,
			   proto	= udp,
			   pid		= self(),
			   hostport	= HostPort,
			   id		= #ob_id{proto = udp,
						 id    = erlang:now()	%% unique ID for Outbound
						}
			  },
	    {ok, NewSocketList} = socketlist:add(listener, self(), SipSocket, 0, State#state.socketlist),
	    sipsocket:add_listener_info(udp, HostPort#hp.l_ip, HostPort#hp.l_port),
	    NewInetSocketL = [{Socket, SipSocket} | State#state.inet_socketlist],
	    start_listening(T, State#state{inet_socketlist = NewInetSocketL,
					   socketlist      = NewSocketList
					  });
	{error, Reason} ->
	    logger:log(error, "Could not open UDP socket (options ~p), port ~p : ~s",
		       [SocketOpts, Port, inet:format_error(Reason)]),
	    {stop, "Could not open UDP socket"};
	Error ->
	    logger:log(error, "Could not open UDP socket (options ~p), port ~p : ~p",
		       [SocketOpts, Port, Error]),
	    {stop, "Could not open UDP socket"}
    end;
start_listening([{udp6, IP, Port} | T], State) when is_integer(Port), is_record(State, state) ->
    SocketOpts0 = [{ip, IP} | ?SOCKETOPTSv6],
    SocketOpts = case os:type() of
		     {unix,linux} ->
			 %% set socket options to request an IPv6 socket only on Linux
			 LinuxIPv6only = {raw,  ?LINUX_IPPROTO_IPV6, ?LINUX_IPV6_V6ONLY, <<1:32/native>>},
			 [LinuxIPv6only | SocketOpts0];
		     _ ->
			 SocketOpts0
		 end,
    case gen_udp:open(Port, SocketOpts) of
	{ok, Socket} ->
	    HostPort1 = get_localaddr(Socket, "[::]"),
	    HostPort = HostPort1#hp{l_port = Port},
	    SipSocket =
		#sipsocket{module	= sipsocket_udp,
			   proto	= udp6,
			   pid		= self(),
			   hostport	= HostPort,
			   id		= #ob_id{proto = udp6,
						 id    = erlang:now()	%% unique ID for Outbound
						}
			  },
	    {ok, NewSocketList} = socketlist:add(listener, self(), SipSocket, 0, State#state.socketlist),
	    sipsocket:add_listener_info(udp6, HostPort#hp.l_ip, Port),
	    NewInet6SocketL = [{Socket, SipSocket} | State#state.inet6_socketlist],
	    start_listening(T, State#state{inet6_socketlist = NewInet6SocketL,
					   socketlist	    = NewSocketList
					  });
	{error, Reason} ->
	    logger:log(error, "Could not open IPv6 UDP socket (options ~p), port ~p : ~s",
		       [SocketOpts, Port, inet:format_error(Reason)]),
	    {stop, "Could not open IPv6 UDP socket"}
    end;
start_listening([], #state{test_leader = TL} = State) when is_pid(TL) ->
    logger:log(debug, "Test sipsocket_udp server started, reporting to ~p", [TL]),
    ets:insert(?SIPSOCKET_UDP_TABLE_NAME, {{self(), udp}, State#state.inet_socketlist}),
    ets:insert(?SIPSOCKET_UDP_TABLE_NAME, {{self(), udp6}, State#state.inet6_socketlist}),
    TL ! {started, State},
    {ok, State};
start_listening([], State) ->
    ets:insert(?SIPSOCKET_UDP_TABLE_NAME, {{self(), udp}, State#state.inet_socketlist}),
    ets:insert(?SIPSOCKET_UDP_TABLE_NAME, {{self(), udp6}, State#state.inet6_socketlist}),
    {ok, State}.


%%--------------------------------------------------------------------
%% @spec    handle_call(Msg, From, State) ->
%%            {reply, Reply, State}          |
%%            {reply, Reply, State, Timeout} |
%%            {noreply, State}               |
%%            {noreply, State, Timeout}      |
%%            {stop, Reason, Reply, State}   |
%%            {stop, Reason, State}
%%
%% @doc     Handling call messages
%% @hidden
%% @end
%%--------------------------------------------------------------------

%% @clear


%%--------------------------------------------------------------------
%% @spec    ({get_socket, Proto}, From, State) ->
%%            {reply, Reply, State}
%%
%%            Proto = udp | udp6
%%
%%            Reply     = {ok, SipSocket} | {error, Reason}
%%            SipSocket = #sipsocket{}
%%            Reason    = string()
%%
%% @doc     Get a socket for a certain protocol (Proto). Always return
%%          the first socket for the requested Proto for now.
%% @hidden
%% @end
%%--------------------------------------------------------------------
handle_call({get_socket, udp}, _From, #state{inet_socketlist = [{_Socket, SipSocket} | _]} = State) ->
    {reply, {ok, SipSocket}, State};

handle_call({get_socket, udp6}, _From, #state{inet6_socketlist = [{_Socket, SipSocket} | _]} = State) ->
    {reply, {ok, SipSocket}, State};

handle_call({get_socket, _Proto}, _From, State) ->
    {reply, {error, "No socket found"}, State};


%%--------------------------------------------------------------------
%% @spec    ({get_specific_socket, Id}, From, State) ->
%%            {reply, Reply, State}
%%
%%            Id = #ob_id{}
%%
%%            Reply     = {ok, SipSocket} | {error, Reason}
%%            SipSocket = #sipsocket{}
%%            Reason    = string()
%%
%% @doc     Get a specific socket.
%% @hidden
%% @end
%%--------------------------------------------------------------------
handle_call({get_specific_socket, #ob_id{proto = udp} = Id}, _From, State) ->
    Res = get_sipsocket_id_match(Id, State#state.inet_socketlist),
    {reply, Res, State};

handle_call({get_specific_socket, #ob_id{proto = udp6} = Id}, _From, State) ->
    Res = get_sipsocket_id_match(Id, State#state.inet6_socketlist),
    {reply, Res, State};


%%--------------------------------------------------------------------
%% @spec    ({get_raw_socket, Proto}, From, State) ->
%%            {reply, Reply, State}
%%
%%            Proto = udp | udp6
%%
%%            Reply     = {ok, RawSocket}
%%            RawSocket = term()
%%
%% @doc     Get the raw socket.
%% @hidden
%% @end
%%--------------------------------------------------------------------
handle_call({get_raw_socket, udp}, _From, #state{inet_socketlist = [{Socket, _SipSocket} | _]} = State) ->
    {reply, {ok, Socket}, State};

handle_call({get_raw_socket, udp6}, _From, #state{inet6_socketlist = [{Socket, _SipSocket} | _]} = State) ->
    {reply, {ok, Socket}, State};

handle_call({get_raw_socket, _Proto}, _From, State) ->
    {reply, {error, "No socket found"}, State};


%%--------------------------------------------------------------------
%% @spec    ({get_socketlist, Proto}, ...) ->
%%            {reply, Reply, State}
%%
%%            Proto = udp | udp6
%%
%%            Reply = {ok, Res}
%%            Res   = [#sipsocket]
%%
%% @doc     Return the list of sockets for a protocol, to facilitate
%%          sending messages from client processes, thereby avoiding
%%          the bottle neck of the single sipsocket_udp process.
%%
%% @hidden
%% @end
%%--------------------------------------------------------------------
handle_call({get_socketlist, udp}, _From, State) ->
    {reply, {ok, State#state.inet_socketlist}, State};
handle_call({get_socketlist, udp6}, _From, State) ->
    {reply, {ok, State#state.inet6_socketlist}, State};

%%
%% For now, this is just used by unit tests.
%%
handle_call(quit, From, State) ->
    logger:log(debug, "Terminating on request from ~p", [From]),
    {stop, normal, ok, State}.


%%--------------------------------------------------------------------
%% @spec    handle_cast(Msg, State) ->
%%            {noreply, State}          |
%%            {noreply, State, Timeout} |
%%            {stop, Reason, State}
%%
%% @doc     Handling cast messages
%% @hidden
%% @end
%%--------------------------------------------------------------------

%% @clear

%%--------------------------------------------------------------------
%% @spec    (Unknown, State) -> {noreply, State}
%%
%% @doc     Unknown cast.
%% @hidden
%% @end
%%--------------------------------------------------------------------
handle_cast(Unknown, State) ->
    logger:log(error, "Sipsocket UDP: Received unknown gen_server cast : ~p", [Unknown]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @spec    handle_info(Msg, State) ->
%%            {noreply, State}          |
%%            {noreply, State, Timeout} |
%%            {stop, Reason, State}
%%
%% @doc     Handling all non call/cast messages
%% @hidden
%% @end
%%--------------------------------------------------------------------

%% @clear

%%--------------------------------------------------------------------
%% @spec    ({udp, Socket, IPlist, InPortNo, Packet}, State) ->
%%            {noreply, State}
%%
%%            Socket   = term()
%%            IPtuple  = term() "source IP address"
%%            InPortNo = integer()
%%            Packet   = list()
%%
%% @doc     Handle data received (as a signal) from one of our
%%          sockets.
%% @hidden
%% @end
%%--------------------------------------------------------------------
handle_info({udp, Socket, IPtuple, InPortNo, Packet}, State) when is_integer(InPortNo) ->
    {Proto, SipSocket} =
	case lists:keysearch(Socket, 1, State#state.inet_socketlist) of
	    {value, {Socket, SipSocket4}} ->
		{udp, SipSocket4};
	    false ->
		case lists:keysearch(Socket, 1, State#state.inet6_socketlist) of
		    {value, {Socket, SipSocket6}} ->
			{udp6, SipSocket6};
		    false ->
			{nomatch, none}
		end
	end,

    case (Proto == udp orelse Proto == udp6) of
	true ->
	    IP = siphost:makeip(IPtuple),
	    case State#state.test_leader of
		undefined ->
		    %% not testing
		    received_packet(Packet, IPtuple, IP, InPortNo, Proto, Socket, SipSocket);
		TL when is_pid(TL) ->
		    %% unit testing
		    TL ! {received_packet, Packet, IPtuple, IP, InPortNo, Proto, Socket, SipSocket}
	    end;
	false ->
	    logger:log(error, "Sipsocket UDP: Received gen_server info 'udp' "
		       "from unknown source '~p', ignoring", [Socket])
    end,

    {noreply, State};

handle_info(Info, State) ->
    logger:log(error, "Sipsocket UDP: Received unknown gen_server info : ~p", [Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @spec    (Reason, State) -> term() "ignored by gen_server"
%%
%% @doc     Shutdown the server
%% @hidden
%% @end
%%--------------------------------------------------------------------
terminate(Reason, _State) ->
    case Reason of
        normal -> true;
        _ -> logger:log(error, "UDP listener terminating : ~p", [Reason])
    end,
    ok.

%%--------------------------------------------------------------------
%% @spec    (OldVsn, State, Extra) -> {ok, NewState}
%%
%% @doc     Convert process state when code is changed
%% @hidden
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%====================================================================
%% Interface functions
%%====================================================================

%%--------------------------------------------------------------------
%% @spec    (SipSocket, Proto, Host, Port, Message) ->
%%            Result |
%%            {error, Reason}
%%
%%            SipSocket = #sipsocket{}
%%            Proto     = udp | udp6
%%            Host      = string()
%%            Port      = integer()
%%            Message   = term()
%%
%%            Result = term() "ultimately the result of send()"
%%            Reason = string()
%%
%% @doc     Send Message to Host:Port. Proto must currently be the
%%          same protocol as is stored in SipSocket.
%% @end
%%--------------------------------------------------------------------
send(SipSocket, Proto, _Host, _Port, _Message)
  when is_record(SipSocket, sipsocket), SipSocket#sipsocket.proto /= Proto ->
    {error, "Protocol mismatch"};
send(SipSocket, Proto, Host, Port, Message) when is_record(SipSocket, sipsocket),
						 is_integer(Port), is_atom(Proto),
						 (Proto == udp orelse Proto == udp6) ->
    Host2 =
	case Proto of
	    udp6 ->
		case hd(Host) of
		    "[" ->
			case string:rchr(Host, 93) of	%% 93 is ]
			    0 ->
				{error, "Unknown format of destination"};
			    Index when is_integer(Index) ->
				Addr = string:substr(Host, 1, Index - 1),
				{ok, AddrT} = inet_parse:ipv6_address(Addr),
				AddrT
			end;
		    _ ->
			Host
		end;
	    udp ->
		Host
	end,

    case get_socketlist(SipSocket#sipsocket.pid, Proto) of
	{ok, SocketList} ->
	    do_send(SocketList, SipSocket, Host2, Port, Message);
	{error, Reason} ->
	    {error, Reason}
    end.

%%--------------------------------------------------------------------
%% @spec    (Dst) ->
%%            SipSocket       |
%%            {error, Reason}
%%
%%            Dst = #sipdst{}
%%
%%            SipSocket = #sipsocket{}
%%            Reason    = string()
%%
%% @doc     Return a socket suitable for communicating with this dst.
%% @end
%%--------------------------------------------------------------------
get_socket(#sipdst{proto = Proto}) when Proto == udp; Proto == udp6 ->
    get_socket(Proto, ?SIPSOCKET_UDP_SERVER).

get_socket(Proto, ServerRef) ->
    case catch gen_server:call(ServerRef, {get_socket, Proto}, ?GET_SOCKET_TIMEOUT) of
	{ok, SipSocket} ->
	    SipSocket;
	{error, E} ->
	    logger:log(error, "Sipsocket UDP: Failed fetching socket for protocol ~p : ~p", [Proto, E]),
	    {error, E};
	{'EXIT', {timeout, _}} ->
	    logger:log(error, "Sipsocket UDP: Failed fetching socket for protocol ~p : timeout (~p ms)",
		       [Proto, ?GET_SOCKET_TIMEOUT]),
	    {error, "timeout"}
    end.

%%--------------------------------------------------------------------
%% @spec    (Id) ->
%%            SipSocket       |
%%            {error, Reason}
%%
%%            Id = #ob_id{}
%%
%%            SipSocket = #sipsocket{}
%%            Reason    = string()
%%
%% @doc     Return a specific socket. Used by draft-Outbound implem-
%%          entation to send requests using an existing flow, or not
%%          at all.
%% @end
%%--------------------------------------------------------------------
get_specific_socket(#ob_id{proto = Proto} = Id) when Proto == udp; Proto == udp6 ->
    get_specific_socket(Id, ?SIPSOCKET_UDP_SERVER).

get_specific_socket(Id, ServerRef) ->
    case catch gen_server:call(ServerRef, {get_specific_socket, Id}) of
	{ok, SipSocket} ->
	    SipSocket;
	{error, E} ->
	    %% semi-normal to not find specific sockets
	    logger:log(debug, "Sipsocket UDP: Failed fetching specific socket with id ~p : ~p", [Id, E]),
	    {error, E}
    end.

%%--------------------------------------------------------------------
%% @spec    (Socket) ->
%%            {ok, RawSocket} |
%%            {error, Reason}
%%
%%            Socket = #sipsocket{}
%%
%%            RawSocket = term()
%%            Reason    = string()
%%
%% @doc     Get the raw TCP/UDP/TLS socket from the socket handler. Be
%%          careful with what you do with the raw socket - don't use
%%          it for sending/receiving for example. Intended for use in
%%          extractin certificate information of an SSL socket or
%%          similar.
%% @end
%%--------------------------------------------------------------------
get_raw_socket(#sipsocket{proto = Proto}) when Proto == udp; Proto == udp6 ->
    case catch gen_server:call(sipsocket_udp, {get_raw_socket, Proto}) of
	{ok, RawSocket} ->
	    {ok, RawSocket};
	{error, E} ->
	    logger:log(error, "Sipsocket UDP: Failed fetching socket for protocol ~p : ~p", [Proto, E]),
	    {error, E}
    end.

%%--------------------------------------------------------------------
%% @spec    (SipSocket) -> not_applicable
%%
%% @doc     UDP sockets don't have a remote peer.
%% @end
%%--------------------------------------------------------------------
get_remote_peer(#sipsocket{proto = Proto}) when Proto == udp; Proto == udp6 ->
    not_applicable.

%%--------------------------------------------------------------------
%% @spec    (SipSocket) -> false
%%
%%            SipSocket = #sipsocket{}
%%
%% @doc     No UDP protocol is reliable transport. Return false.
%% @end
%%--------------------------------------------------------------------
is_reliable_transport(#sipsocket{proto = Proto}) when Proto == udp; Proto == udp6 ->
    false.

%%--------------------------------------------------------------------
%% @spec    (SipSocket) ->
%%            ok              |
%%            {error, Reason}
%%
%%            SipSocket = #sipsocket{}
%%
%%            Reason = string
%%
%% @doc     Close a socket.
%% @end
%%--------------------------------------------------------------------
close_socket(#sipsocket{proto = Proto}) when Proto == udp; Proto == udp6 ->
    {error, not_applicable}.

%%====================================================================
%% Internal functions
%%====================================================================

%%--------------------------------------------------------------------
%% @spec    (Socket, DefaultAddr) ->
%%            HP
%%
%%            Socket      = term() "gen_udp socket"
%%            DefaultAddr = list() "default if we fail"
%%
%%            HP = #hostport{}
%%
%% @doc     Return the listening IP and port for a socket.
%% @end
%%--------------------------------------------------------------------
get_localaddr(Socket, DefaultAddr) ->
    case inet:sockname(Socket) of
	{ok, {IPlist, LocalPort}} ->
	    IP = siphost:makeip(IPlist),
	    logger:log(debug, "Listening on UDP ~s:~p (socket ~p)", [IP, LocalPort, Socket]),
	    #hp{l_ip   = IP,
		l_port = LocalPort
	       };
	{error, E} ->
	    %% XXX maybe we don't have a good socket after all?
	    logger:log(error, "UDP listener: sockname() on socket ~p returned error ~p", [Socket, E]),
	    #hp{l_ip   = DefaultAddr,
		l_port = 0
	       }
    end.

%%--------------------------------------------------------------------
%% @spec    (Packet, IPtuple, IP, Port, Proto, Socket, SipSocket) ->
%%            ok
%%
%%            Packet    = binary() "packet received from network"
%%            IPtuple   = term() "source IP address tuple"
%%            IP        = string() "source IP address"
%%            Port      = integer() "source port"
%%            Proto     = atom() "source protocol"
%%            Soclet    = term() "socket we received packet on"
%%            SipSocket = #sipsocket{}
%%
%% @doc     Check if a received packet is a keepalive or possibly a
%%          SIP message. For the latter case, we spawn
%%          sipserver:process(...) on the packet, after creating the
%%          necessary sipsocket and origin records.
%% @end
%%--------------------------------------------------------------------
received_packet(<<"\r\n">>, _IPtuple, IP, Port, Proto, _Socket, _SipSocket) ->
    logger:log(debug, "Keepalive packet (CRLF) received from ~p:~s:~p", [Proto, IP, Port]),
    ok;
received_packet(Packet, IPtuple, IP, Port, Proto, Socket, _SipSocket) when is_binary(Packet), size(Packet) =< 30 ->
    %% Too short to be anywhere near a real SIP message
    %% STUN packets (or whatever they are) look like "\r111.222.333.444:pppp"
    case is_only_nulls(Packet) of
	true ->
	    logger:log(debug, "Keepalive packet (~p NULLs) received from ~p:~s:~p",
		       [size(Packet), Proto, IP, Port]);
	false ->
	    case Packet of
		<<N:8, _Rest/binary>> when N == 0; N == 1 ->
		    case yxa_config:get_env(stun_demuxing_on_sip_ports) of
			{ok, true} ->
			    stun_process(Packet, Proto, IPtuple, IP, Port, Socket);
			{ok, false} ->
			    logger:log(debug, "Ignoring STUN packet received from ~p:~s:~p",
				       [Proto, IP, Port])
		    end;
		_ ->
		    logger:log(debug, "Packet received from ~p:~s:~p too short to be a SIP message :~n~p~n"
			       "(as list: ~p)", [Proto, IP, Port, Packet, binary_to_list(Packet)])
	    end
    end,
    ok;
received_packet(Packet, IPtuple, IP, Port, Proto, Socket, SipSocket)
  when is_binary(Packet), is_list(IP), is_integer(Port), is_atom(Proto), is_record(SipSocket, sipsocket) ->
    case Packet of
	<<N:8, _Rest/binary>> when N == 0; N == 1 ->
	    case yxa_config:get_env(stun_demuxing_on_sip_ports) of
		{ok, true} ->
		    stun_process(Packet, Proto, IPtuple, IP, Port, Socket);
		{ok, false} ->
		    logger:log(debug, "Ignoring STUN packet received from ~p:~s:~p",
			       [Proto, IP, Port])
	    end;
	_ ->
	    IP = siphost:makeip(IPtuple),
	    Origin = #siporigin{proto		= Proto,
				addr		= IP,
				port		= Port,
				receiver	= self(),
				sipsocket	= SipSocket
			       },
	    yxa_proc:safe_spawn(sipserver, process, [Packet, Origin]),
	    ok
    end.

stun_process(Packet, Proto, IPtuple, IP, Port, Socket) ->
    {ok, {LocalIP, LocalPort}} = inet:sockname(Socket),
    SocketOpts =
	case Proto of
	    udp ->
		[{ip, LocalIP} | ?SOCKETOPTS];
	    udp6 ->
		[{ip, LocalIP} | ?SOCKETOPTSv6] -- [{buffer, 8 * 1024}]
	end,
    %% Get a socket with an alternate port number on the same interface that we received
    %% this STUN packet on. STUN has options for getting the server to answer using a
    %% different port (which is unspecified), and different IP address than the request
    %% was received on (to help classify NAT devices between the client and server).
    %% We currently only support the 'use other port' mode - not the 'use other IP'.
    {AltSocket, _AltIP, AltPort} =
	case gen_udp:open(0, SocketOpts) of
	    {ok, AltSocket1} ->
		{ok, {A, P}} = inet:sockname(AltSocket1),
		{AltSocket1, A, P};
	    {error, Reason} ->
		logger:log(error, "Failed acquiring a second socket for alternate-port STUN using socket options "
			   "~p : ~p", [SocketOpts, Reason]),
		{undefined, undefined, undefined}
	end,

    StunEnv =
	#stun_env{proto			= Proto,
		  local_ip		= LocalIP,
		  local_port		= LocalPort,
		  remote_ip		= IPtuple,
		  remote_ip_str		= IP,
		  remote_port		= Port,
		  alt_ip		= undefined,	%% Alternate IP not supported (patches welcome)
		  alt_port		= AltPort
		 },

    case stun:process(Packet, StunEnv) of
	#stun_result{action = send_response, change = Change, response = STUNResponse} ->
	    case Change of
		none ->	gen_udp:send(Socket, IP, Port, STUNResponse);
		port ->	gen_udp:send(AltSocket, IP, Port, STUNResponse);
		ip ->
		    %% This should never happen since we set StunEnv alt_ip to 'undefined', but who knows...
		    %% We don't want the UDP receiving gen_server to crash, so we check for it.
		    logger:log(debug, "STUN module request us to change IP for the response, but that is not "
			       "currently supported - not sending STUN response");
		both ->
		    %% This should never happen since we set StunEnv alt_ip to 'undefined', but who knows...
		    %% We don't want the UDP receiving gen_server to crash, so we check for it.
		    logger:log(debug, "STUN module request us to change both IP and port for the response, "
			       "but changing IP is currently not supported - not sending STUN response")
	    end;
	ignore ->
	    ok;
	{error, not_stun} ->
	    logger:log(debug, "Non-STUN packet received from ~p:~s:~p : ~n~p~n"
		       "(as list: ~p)", [Proto, IP, Port, Packet, binary_to_list(Packet)])
    end,
    gen_udp:close(AltSocket),
    ok.

%%--------------------------------------------------------------------
%% @spec    (Packet) -> true | false
%%
%%            Packet = binary() "a packet received from the network"
%%
%% @doc     Check if a binary packet is only NULL bytes or not.
%% @end
%%--------------------------------------------------------------------
is_only_nulls(<<0, Rest/binary>>) ->
    is_only_nulls(Rest);
is_only_nulls(<<>>) ->
    true;
is_only_nulls(_) ->
    false.

%%--------------------------------------------------------------------
%% @spec    (Id, L) ->
%%            {ok, SipSocket} |
%%            {error, Reason}
%%
%%            Id = term()
%%            L  = [#sipsocket{}]
%%
%%            SipSocket = #sipsocket{}
%%            Reason    = string()
%%
%% @doc     Look for sipsocket with id matching Id.
%% @end
%%--------------------------------------------------------------------
get_sipsocket_id_match(Id, [{_Socket, #sipsocket{id = Id} = SipSocket} | _T]) ->
    {ok, SipSocket};
get_sipsocket_id_match(Id, [_H | T]) ->
    get_sipsocket_id_match(Id, T);
get_sipsocket_id_match(_Id, []) ->
    {error, "No socket found"}.


%%--------------------------------------------------------------------
%% @spec    (SocketList, SipSocket, Host, Port, Message) ->
%%            {error, no_socket} | term() "send result"
%%
%%            SocketList = [{Socket, SipSocket}]
%%            Socket     = term() "gen_udp socket"
%%            SipSocket  = #sipsocket{} "prefered socket to use"
%%            Host       = string()
%%            Port       = integer()
%%            Message    = term()
%%
%% @doc     Try sockets in SocketList until we find one that can send
%%          to this destination, or they are all exhausted.
%% @end
%%--------------------------------------------------------------------
do_send(Sockets, SipSocket, Host, Port, Message) ->
    %% look for SipSocket in Sockets, if it is found we place that socket first
    %% in the list to always first try the exact socket requested, but otherwise
    %% fall back to the "try all" method
    NewSockets = do_send_sort_sockets(Sockets, SipSocket),
    do_send2(NewSockets, Host, Port, Message).

do_send2([{Socket, _SipSocket} | T], Host, Port, Message) ->
    Res = gen_udp:send(Socket, Host, Port, Message),
    case Res of
	{error, einval} ->
	    %% destination address not valid for this socket, try next
	    do_send2(T, Host, Port, Message);
	Res ->
	    Res
    end;
do_send2([], _Host, _Port, _Message) ->
    {error, no_socket}.

%%--------------------------------------------------------------------
%% @spec    (Sockets, SipSocket) ->
%%            NewSockets
%%
%%            Sockets   = [{Socket, SipSocket}]
%%            Socket    = term() "gen_udp socket"
%%            SipSocket = #sipsocket{} "prefered socket to use"
%%
%%            NewSockets = [{Socket, SipSocket}]
%%
%% @doc     Sort sockets to try and send a message using. First, we
%%          look for a socket that matches the requested SipSocket
%%          exactly, and second we look for one with the same local
%%          host and port. The best socket found is returned first in
%%          a new list, but all sockets in Sockets will always be
%%          returned in NewSockets.
%% @end
%%--------------------------------------------------------------------
do_send_sort_sockets(Sockets, SipSocket) ->
    case sort_sockets_id(Sockets, SipSocket#sipsocket.id, []) of
	Res when is_list(Res) ->
	    Res;
	none ->
	    case sort_sockets_laddr(Sockets, SipSocket#sipsocket.hostport, []) of
		none ->
		    Sockets;
		Res when is_list(Res) ->
		    Res
	    end
    end.

%% part of do_send_sort_sockets/4
%% Returns : list() of sipsocket record() | none
sort_sockets_id([{_Socket, #sipsocket{id = Id}} = H | T], Id, Res) ->
    %% exact match found - this is the normal case so we don't log it
    [H | lists:reverse(Res)] ++ T;
sort_sockets_id([H | T], Id, Res) ->
    %% no match
    sort_sockets_id(T, Id, [H | Res]);
sort_sockets_id([], Id, _Res) ->
    logger:log(debug, "Sipsocket UDP: Found no exact match for socket with id ~p", [Id]),
    none.

%% part of do_send_sort_sockets/4
%% Returns : list() of sipsocket record() | none
sort_sockets_laddr([{_Socket, SipSocket} = H | T], HP, Res) ->
    SS_HP = SipSocket#sipsocket.hostport,
    case (SS_HP#hp.l_ip == HP#hp.l_ip andalso
	  SS_HP#hp.l_port == HP#hp.l_port) of
	true ->
	    logger:log(debug, "Sipsocket UDP: Found socket matching local address+port ~s:~p",
		       [HP#hp.l_ip, HP#hp.l_port]),
	    [H | lists:reverse(Res)] ++ T;
	false ->
	    %% no match
	    sort_sockets_laddr(T, HP, [H | Res])
    end;
sort_sockets_laddr([], HP, _Res) ->
    logger:log(debug, "Sipsocket UDP: Found no match for local address+port ~s:~p", [HP#hp.l_ip, HP#hp.l_port]),
    none.

get_socketlist(ServerRef, Proto) when Proto == udp; Proto == udp6 ->
    %%gen_server:call(ServerRef, {get_socketlist, Proto}).
    ServerPid =
	case is_pid(ServerRef) of
	    true ->
		ServerRef;
	    false ->
		case erlang:whereis(ServerRef) of
		    Pid when is_pid(Pid) ->
			Pid;
		    undefined ->
			throw({error, "Sipsocket UDP server not found"})
		end
	end,

    [{_Key, List}] = ets:lookup(?SIPSOCKET_UDP_TABLE_NAME, {ServerPid, Proto}),

    {ok, List}.



%%====================================================================
%% Test functions
%%====================================================================

%%--------------------------------------------------------------------
%% @spec    () -> ok
%%
%% @doc     autotest callback
%% @hidden
%% @end
%%--------------------------------------------------------------------
-ifdef( YXA_NO_UNITTEST ).
test() ->
    {error, "Unit test code disabled at compile time"}.

-else.

test() ->

    %% test do_send_sort_sockets(Sockets, SipSocket)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "do_send_sort_sockets/2 - 1"),
    %% test with exact match possible
    SortSocketsL1 = [{2, #sipsocket{id = 2}},
		     {1, #sipsocket{id = 1}}
		    ],
    SortSockets1_expect = lists:reverse(SortSocketsL1),
    SortSockets1_expect = do_send_sort_sockets(SortSocketsL1, #sipsocket{id = 1}),

    autotest:mark(?LINE, "do_send_sort_sockets/2 - 2"),
    %% test with no exact match possible, but local address found (order should be preserved except
    %% the matching socket which is inserted at the head of the list)
    SortSocketsL2 = [{3, #sipsocket{id = 3, hostport = #hp{l_ip = "192.0.2.1", l_port = 5003}}},
		     {2, #sipsocket{id = 2, hostport = #hp{l_ip = "192.0.2.1", l_port = 5002}}},
		     {1, #sipsocket{id = 1, hostport = #hp{l_ip = "192.0.2.1", l_port = 5001}}}
		    ],
    SortSockets2_SS = #sipsocket{id = 99, hostport = #hp{l_ip = "192.0.2.1", l_port = 5002}},
    [{2, _}, {3, _}, {1, _}] = do_send_sort_sockets(SortSocketsL2, SortSockets2_SS),

    autotest:mark(?LINE, "do_send_sort_sockets/2 - 3"),
    %% test with no match at all
    SortSockets3_SS = #sipsocket{id = 99, hostport = #hp{l_ip = "192.0.2.1", l_port = 5099}},
    SortSocketsL2 = do_send_sort_sockets(SortSocketsL2, SortSockets3_SS),


    %% test is_only_nulls(Packet)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "is_only_nulls/1 - 1"),
    true = is_only_nulls(<<>>),

    autotest:mark(?LINE, "is_only_nulls/1 - 2"),
    true = is_only_nulls(<<0, 0, 0>>),

    autotest:mark(?LINE, "is_only_nulls/1 - 3"),
    false = is_only_nulls(<<0, 0, 0, 1>>),

    ok = test_ipv4(),

    ok = test_speed(),

    ok.

test_ipv4() ->

    %% test init(Port, TestLeader)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "init/1 - 1.0"),

    MyIP = siphost:myip(),
    {ok, MyIPt} = inet_parse:ipv4_address(MyIP),

    ok = yxa_test_config:init(incomingproxy, []),
    ok = yxa_test_config:set(enable_v6, false),

    TestPort = 59595,
    Self = self(),
    {ok, TestServer} = gen_server:start_link(?MODULE,
					     [TestPort, Self],
					     []
					    ),
    autotest:mark(?LINE, "init/1 - 1.1"),
    receive
	{started, #state{test_leader = Self}} ->
	    ok
    after 1000 ->
	    throw({error, "sipsocket_UDP test server did not start OK"})
    end,

    %% test get_socket(Dst)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "get_socket/1 - 1"),
    %% get v4 socket
    SipSocket1 = get_socket(udp, TestServer),

    autotest:mark(?LINE, "get_socket/1 - 1"),
    %% should have no v6 socket
    {error,"No socket found"} = get_socket(udp6, TestServer),

    %% test get_specific_socket(Id)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "get_specific_socket/1 - 1"),
    %% ask for the socket we have
    SipSocket1 = get_specific_socket(SipSocket1#sipsocket.id, TestServer),

    autotest:mark(?LINE, "get_specific_socket/1 - 2"),
    %% ask for a socket we DON'T have
    {error, "No socket found"} = get_specific_socket(#ob_id{proto = udp6}, TestServer),

    autotest:mark(?LINE, "get_specific_socket/1 - 3"),
    %% ask for a socket we DON'T have #2
    {error, "No socket found"} = get_specific_socket(#ob_id{proto = udp, id = 123}, TestServer),

    %% test packet reception
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "packet reception - 1.0"),
    TestSocketOpts = [{ip, MyIPt} | ?SOCKETOPTS],

    %% get a temporary plain gen_udp socket
    {ok, ClientSocket1} = gen_udp:open(0, TestSocketOpts),

    {ok, {ClientAddress1, ClientPort1}} = inet:sockname(ClientSocket1),

    TestPacket1 = <<"\r\n">>,
    ok = gen_udp:send(ClientSocket1, siphost:myip(), TestPort, TestPacket1),

    autotest:mark(?LINE, "packet reception - 1.1"),
    receive
	{received_packet, TestPacket1,
	 ClientAddress1, MyIP, ClientPort1,
	 udp, _Socket1, #sipsocket{}} ->
	    ok;
	Msg1 ->
	    throw({error, "Received unknown message", Msg1})
    after 1000 ->
	    throw({error, "Did not receive packet"})
    end,


    autotest:mark(?LINE, "packet reception - 1.2"),
    %% clean up
    gen_udp:close(ClientSocket1),


    %% test send(SipSocket, Proto, Host, Port, Message)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "send/5 - 1.0"),
    TestPacket2 = <<0, 0, 0, 0, 0>>,
    ok = send(SipSocket1, udp, MyIP, TestPort, TestPacket2),

    autotest:mark(?LINE, "send/5 - 1.1"),
    receive
	{received_packet,
	 TestPacket2,
	 _IP2_1,
	 _IP2_2,
	 TestPort,
	 udp, _Socket2, #sipsocket{}} ->
	    ok;
	Msg2 ->
	    throw({error, "Received unknown message", Msg2})
    after 1000 ->
	    throw({error, "Did not receive packet"})
    end,

    autotest:mark(?LINE, "send/5 - 2"),
    %% test with protocol not matching our socket
    {error, "Protocol mismatch"} = send(SipSocket1, udp6, MyIP, TestPort, TestPacket2),


    %% test quit
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "gen_server call (quit)/1 - 1"),
    ok = gen_server:call(TestServer, quit),

    ok = yxa_test_config:stop(),

    ok.



test_speed() ->

    %% test init(Port, TestLeader)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "init/1 - 1.0"),

    MyIP = siphost:myip(),
    {ok, MyIPt} = inet_parse:ipv4_address(MyIP),

    ok = yxa_test_config:init(incomingproxy, []),
    ok = yxa_test_config:set(enable_v6, false),

    TestPort = 59596,
    Self = self(),
    {ok, TestServer} = gen_server:start_link(?MODULE,
					     [TestPort, Self],
					     []
					    ),
    autotest:mark(?LINE, "init/1 - 1.1"),
    receive
	{started, #state{test_leader = Self}} ->
	    ok
    after 1000 ->
	    throw({error, "sipsocket_UDP test server did not start OK"})
    end,

    %% test get_socket(Dst)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "get_socket/1 - 1"),
    %% get v4 socket
    SipSocket1 = get_socket(udp, TestServer),

    autotest:mark(?LINE, "UDP send/receive speed - 1.0"),
    Time = 100,
    NumTests = 5,
    PPS_L = [test_speed2(Time, SipSocket1, MyIP, TestPort) || _ <- lists:seq(1, NumTests)],

    BestResult = lists:max(PPS_L),
    autotest:mark(?LINE, "UDP send/receive speed - 1.1 (best result per ~p ms of ~p runs : ~p packets)",
		  [Time, NumTests, BestResult]),
    %% fake test to output result

    autotest:mark(?LINE, "UDP send/receive speed - 1.2"),
    if
	BestResult < 500 ->
	    %% Around 1000 PPS for Time == 100 is what I get on my laptop
	    throw({error, {"Packets per second benchmark result too low (must be >= 500)", BestResult}});
	true ->
	    ok
    end,


    %% test quit
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "gen_server call (quit)/1 - 1"),
    ok = gen_server:call(TestServer, quit),

    ok = yxa_test_config:stop(),

    ok.

test_speed2(Time, SipSocket, MyIP, TestPort) ->
    erlang:send_after(Time, self(), stop_speedtest),
    {ok, Count} = test_speed3(SipSocket, MyIP, TestPort, 0),
    Count.

test_speed3(SipSocket, MyIP, TestPort, Count) ->
    %%TestPacket = <<0, 0, 0, 0, 0, "TEST", Count>>,
    TestPacket =
	<<"INVITE sip:test@example.org SIP/2.0\r\n"
	 "Via: SIP/2.0/TCP one.example.org\r\n"
	 "Via: SIP/2.0/TCP two.example.org\r\n"
	 "Via: SIP/2.0/TCP three.example.org\r\n"
	 "Via: SIP/2.0/TCP four.example.org\r\n"
	 "Via: SIP/2.0/TCP five.example.org\r\n"
	 "Via: SIP/2.0/TCP six.example.org\r\n"
	 "Via: SIP/2.0/TCP seven.example.org\r\n"
	 "Via: SIP/2.0/TCP eight.example.org\r\n"
	 "Via: SIP/2.0/TCP nine.example.org\r\n"
	 "Via: SIP/2.0/TCP ten.example.org\r\n"
	 "Via: SIP/2.0/TCP eleven.example.org\r\n"
	 "Via: SIP/2.0/TCP twelve.example.org\r\n"
	 "From: Test <sip:test@example.org>;tag=f-123\r\n"
	 "To: <sip:test@example.org>;tag=t-123\r\n"
	 "Content-Length: 4\r\n"
	 "\r\n",
	 Count
	 >>,
    receive
	stop_speedtest ->
	    {ok, Count}
    after 0 ->
	    ok = send(SipSocket, udp, MyIP, TestPort, TestPacket),

	    receive
		{received_packet,
		 TestPacket,
		 _IP2_1,
		 _IP2_2,
		 _TestPort,
		 _Proto,
		 _Socket,
		 _SipSocket
		} ->
		    test_speed3(SipSocket, MyIP, TestPort, Count + 1)
	    after 1000 ->
		    throw({error, "Did not receive packet"})
	    end
    end.

-endif.
