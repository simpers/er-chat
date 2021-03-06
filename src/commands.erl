%% @author Sam, Mattias, Ludwing, Per och Tomas
%% @doc Commands module, handles IRC-commands.
-module(commands).
-compile(export_all).
-include("rpl_macro.hrl").

%% @doc Handles the registration of the user on the server.
%%      Proceeds to user/4 or user/5 depending on whether nick have been accepted.
loop_user(Host,Socket) ->
    receive
        {user,[User,_Steps,_Star,RealName]} ->
            user(User,RealName,Host,Socket),
            exit(normal);
        {nick_ok} ->
            receive
                {user,[User,_Steps,_Star,RealName]} ->
                    user(User,RealName,Host,Socket,nick_ok)
            end,
            exit(normal);
        Error ->
            io:format("Error user:~p~n",[Error])
    end.

%% @doc Handles the messages from parser.
%%      Proceeds the message to the proper function to handle the IRC-command.
%%      Replies with an error if it's an unknown command.
loop_other(Host,Socket,UserPid) ->
    receive
        {nick,[Nick]} ->
            nick(Nick,UserPid,Host,Socket),
            loop_other(Host,Socket,UserPid);
        {ping,[Server]} ->
            pong(Host,Server,Socket),
            loop_other(Host,Socket,UserPid);
        {pong,_} ->
            loop_other(Host,Socket,UserPid);
        {quit,[Message]} ->
            quit(Message,Host,Socket),
            loop_other(Host,Socket,UserPid);
        {join,[Channels]} ->
            ChannelList = binary:split(Channels,<<",">>),
            join(ChannelList,Host,Socket),
            loop_other(Host,Socket,UserPid);
        {privmsg,[Target,Message]} ->
            privmsg(Target,Message,Host,Socket),
            loop_other(Host,Socket,UserPid);
        {part,[Channels,Message]} ->
            ChannelList = binary:split(Channels,<<",">>),
            part(ChannelList,Message,Host,Socket),
            loop_other(Host,Socket,UserPid);
        {part,[Channels]} ->
            ChannelList = binary:split(Channels,<<",">>),
            part(ChannelList,<<"">>,Host,Socket),
            loop_other(Host,Socket,UserPid);
	{whois,Target} ->
	    whois(Target, Host, Socket),
	    loop_other(Host, Socket, UserPid);
        {topic,[Channels]} ->
            ChannelList = binary:split(Channels,<<",">>),
	    get_topic(ChannelList, Host, Socket),
	    loop_other(Host, Socket, UserPid);
        {topic,[Channels|Topic]} ->
           ChannelList = binary:split(Channels,<<",">>),
	   set_topic(ChannelList, Topic, Host, Socket),
	   loop_other(Host, Socket, UserPid);
	{invite, [TargetNick, TargetChannel]} ->
	    io:format("ehh: ~p, ~p~n",[TargetNick,TargetChannel]),
	    invite(Host,Socket,TargetNick, TargetChannel),
	    loop_other(Host, Socket, UserPid);
	{kick,[TargetChannel|Tail]} ->
	    TargetNick = lists:nth(1,Tail),
	    Comment = transmit:get_comment(Tail),
	    kick(Host,Socket,TargetChannel,TargetNick,Comment), 
	    loop_other(Host,Socket,UserPid);
	{mode,List} ->
	    mode(Host,Socket,List),
	    loop_other(Host,Socket,UserPid);
        {names,[Channels]} ->
	    ChannelList = binary:split(Channels,<<",">>),
	    {_,[{user,_,_,{_,Nick},_,_,_,_}]} = database:check_socket(Socket),
	    names(Host,ChannelList,Socket,Nick),
	    loop_other(Host,Socket,UserPid);
        {who,[Channel]} ->
            {_,[{user,_,_,{_,Nick},_,_,_,_}]} = database:check_socket(Socket),
	    who(Host,Socket,Nick,Channel),
	    loop_other(Host,Socket,UserPid);
	{list, List}->
	    {_,ServerHostent} = Host,
	    {_,[{user,_,_,{_,Nick},_,_,_,_}]} = database:check_socket(Socket),
	    gen_tcp:send(Socket,?REPLY_LISTSTART),
	    if
		List == [] orelse List == [<<>>] ->
		    list(Host,Socket,Nick);
		true ->
		    Channels = database:get_head(List),
		    ChannelList = binary:split(Channels,<<",">>,[global,trim]),
		    list(Host,ChannelList,Socket,Nick)
	    end,
	    loop_other(Host, Socket, UserPid);
	{unknown,Command} ->
            {_ServerIP,ServerHostent} = Host,
            gen_tcp:send(Socket,?REPLY_UNKNOWNCOMMAND),
	    io:format("Error Command:~p~n",[Command]),
            loop_other(Host,Socket,UserPid);
        Error ->
            io:format("Error nick:~p~n",[Error])
    end.

%% @doc Register the user to server.
%%      Waits for {nick_ok} from nick/4 before registration.
%%      Replies with an error to the user if it's already registerd.
user(User,RealName,{ServerIP,ServerHostent},Socket) ->
    case database:check_socket(Socket) of
        {_,UserTuple} when is_list(UserTuple) orelse element(2,UserTuple) == empty ->
            receive
                {nick_ok} ->
                    {_,{_,Nick}} = database:get_nick(Socket),
                    if
                        Nick =/= [] ->
                            {_,Port} = inet:port(Socket),
                            database:update_user(Socket,User,RealName),
                            gen_tcp:send(Socket,?REPLY_WELCOME),
                            gen_tcp:send(Socket,?REPLY_YOURHOST);
                        true ->
                            nick_not_registered
                    end
            end;
        _ ->
            {_,{_,Nick}} = database:get_nick(Socket),
            gen_tcp:send(Socket,?REPLY_ALREADYREGISTERD)
    end.

%% @doc Register the user to server.
%%      Replies with an error to the user if it's already registerd.
user(User,RealName,{ServerIP,ServerHostent},Socket,nick_ok) ->
    case database:check_socket(Socket) of
        {_,UserTuple} when is_list(UserTuple) orelse element(2,UserTuple) == empty ->
            {_,{_,Nick}} = database:get_nick(Socket),
            if
                Nick =/= [] ->
                    {_,Port} = inet:port(Socket),
                    database:update_user(Socket,User,RealName),
                    gen_tcp:send(Socket,?REPLY_WELCOME),
                    gen_tcp:send(Socket,?REPLY_YOURHOST);
                true ->
                    nick_not_registered
            end;
        _ ->
            {_,{_,Nick}} = database:get_nick(Socket),
            gen_tcp:send(Socket,?REPLY_ALREADYREGISTERD)
    end.

%% @doc Adds the nick to the database if it doesn't exist.
%%      Replies with an error if nick in use.
%%      Sends {nick_ok} to loop_user/2 if successful.
nick(Nick,UserPid,{_ServerIP,ServerHostent},Socket) ->
    case database:check_nick(Nick) of
        {_,[]} ->
            case database:check_socket(Socket) of
                {_,[]} ->
                    case binary:first(Nick) of
                        35 ->
                            OldNick = <<"*">>,
                            gen_tcp:send(Socket,?REPLY_ERRONEUSNICKNAME);
                        _ ->
                            {_,{IP,_}} = inet:sockname(Socket),
                            {_,{_,Hostent,_,_,_,_}} = inet:gethostbyaddr(IP),
                            database:insert_user(Socket,empty,{string:to_lower(binary:bin_to_list(Nick)),Nick},ServerHostent,list_to_binary(Hostent),empty),
                            UserPid ! {nick_ok}
                    end;
                {_,[{user,_,User,{_,OldNick},_,Hostent,_,ChannelList}]} ->
                    case binary:first(Nick) of
                        35 ->
                            gen_tcp:send(Socket,?REPLY_ERRONEUSNICKNAME);
                        _ ->
                            UserList = transmit:channel_change_nick(ChannelList,Nick,[],Socket),
                            NewUserList = lists:delete(OldNick,UserList),
                            transmit:send_new_nick(NewUserList,OldNick,Nick,User,Hostent),
                            database:update_nick(Socket,{string:to_lower(binary:bin_to_list(Nick)),Nick}),
                            gen_tcp:send(Socket,?REPLY_UPDATENICK)
                    end
	    end;
        _  ->
            gen_tcp:send(Socket,?REPLY_NICKNAMEINUSE)
    end.

%% @doc Sends a PING to the user to see if it still active.
ping({_ServerIP,ServerHostent},Socket) ->
    gen_tcp:send(Socket,?REPLY_PING).

%% @doc Replies to a PING with a PONG to tell that it received the PING.
pong({_ServerIP,ServerHostent},_Server,Socket) ->
    {_,{_,Nick}} = database:get_nick(Socket),
    gen_tcp:send(Socket,?REPLY_PONG).

%% @doc Deregister the user from the server.
%%      Sends a PART to all joined channels.
quit(Message,{_ServerIP,_ServerHostent},Socket) ->
    case database:check_socket(Socket) of
        {_,[{user,_,User,{_,Nick},_,Hostent,_,Channels}]} ->
            part(Channels,Message,{_ServerIP,_ServerHostent},Socket),
            gen_tcp:send(Socket,?REPLY_QUIT),
            database:delete_socket(Socket);
        {_,[]} ->
            already_closed
    end.

%% @doc Adds the user to the channel/channels.
%%      Will create the channel if it doesn't exist and give Admin MODE to the user.
join([],{_ServerIP,_ServerHostent},_Socket) ->
    ok;
join([Channel|Tail],{ServerIP,ServerHostent},Socket) ->
    {_,[{user,_,User,{_,Nick},_,Hostent,_,ChannelList}]} = database:check_socket(Socket),
    case binary:first(Channel) of
        35 ->
            case database:check_channel(Channel) of
                {_,[{channel,_,Users,Topic}]} ->
                    case lists:member(Channel,ChannelList) of
                        false ->
                            database:join_channel(Channel,{<<"">>,Nick},Socket),
                            UserList = transmit:convert_nicklist(Users),
                            transmit:send_join_replies(Users,Channel,Nick,User,Hostent),
                            gen_tcp:send(Socket,?REPLY_JOINCHANNEL),
                            if
                                Topic == <<"">> ->
                                    ok;
                                true ->
                                    gen_tcp:send(Socket,?REPLY_JOINTOPIC)
                            end,
                            gen_tcp:send(Socket,?REPLY_JOINNAMREPLY),
                            gen_tcp:send(Socket,?REPLY_ENDOFNAMES);
                        _ ->
                            []
                    end;
                _ ->
                    database:insert_channel(Channel,{<<"@">>,Nick},<<"">>),
                    UserList = [<<"@">>,Nick],
		    gen_tcp:send(Socket,?REPLY_JOINCHANNEL),
                    gen_tcp:send(Socket,?REPLY_JOINNAMREPLY),
                    gen_tcp:send(Socket,?REPLY_ENDOFNAMES)
            end;
        _ ->
            gen_tcp:send(Socket,?REPLY_NOSUCHCHANNEL) 
    end,
    join(Tail,{ServerIP,ServerHostent},Socket).

%% @doc Sends PRIVMSG to Target.
%%      Will send to channel if Target begins with #, else user.
privmsg(Target,Message,{_ServerIP,ServerHostent},Socket) ->
    {_,[{user,_,User,{_,Nick},_,Hostent,_,_}]} = database:check_socket(Socket),
    case binary:first(Target) of
        35 ->
            case database:check_channel(Target) of
                {_,[{channel,_,Users,_Topic}]} ->
                    transmit:send_privmsg(Users,Target,Message,Nick,User,Hostent);
                _ ->
                    gen_tcp:send(Socket, ?REPLY_NOSUCHNICK)
            end;
        _ ->
            case database:check_nick(Target) of
                {_,[{user,TargetSocket,_UserTarget,{_,Target},_,_HostentTarget,_,_ChannelList}]} ->
		    gen_tcp:send(TargetSocket,?REPLY_PRIVMSG);
                _ ->
                    gen_tcp:send(Socket, ?REPLY_NOSUCHNICK)
            end
    end.

%% @doc Sends a PART to all joined user of the channel and deregister the user from the channel.
part([],_Message,{_ServerIP,_ServerHostent},_Socket) ->
    ok;
part([Channel|Tail],Message,{ServerIP,ServerHostent},Socket) ->
    {_,[{user,_,User,{_,Nick},_,Hostent,_,ChannelList}]} = database:check_socket(Socket),
    case database:check_channel(Channel) of
        {_,[{channel,_,Users,_Topic}]} ->
            case lists:member(Channel,ChannelList) of
                true ->
                    transmit:send_part(Users,Channel,Message,Nick,User,Hostent),
                    database:part_channel(Channel,Nick,Socket);
                false ->
                    []
            end;
        _ ->
            gen_tcp:send(Socket,?REPLY_NOSUCHCHANNEL)
    end,
    part(Tail,Message,{ServerIP,ServerHostent},Socket).

%% @doc Replies with who the Target/Targets is/are.
%%      Replies with a no suck nick if no matching user or channel.
whois(TargetList,{_ServerIp, ServerHostent},Socket) ->
    Target = lists:nth(1,TargetList),
    {_,[{user,_,_,{_,Nick},_,_,_,_ChannelList}]} = database:check_socket(Socket),
    case database:check_nick(Target) of
	{_,[{user,_,_TargetUser,_,UserServer,UserHostent,TargetRealName,_ChannelList}]} ->
	    gen_tcp:send(Socket,?REPLY_WHOISUSER), 
	    gen_tcp:send(Socket,?REPLY_WHOISSERVER),
	    gen_tcp:send(Socket,?REPLY_ENDOFWHOIS);
	_ ->
	    gen_tcp:send(Socket,?REPLY_NOSUCHNICK),
	    gen_tcp:send(Socket,?REPLY_ENDOFWHOIS)
    end.

%% @doc Replies with the TOPIC of the channel/channels.
get_topic([],_Host,_Socket) ->
    ok;
get_topic([Channel|Tail],{_ServerIp, ServerHostent},Socket) ->
    {_,[{user,_,_User,{_,Nick},_,_Hostent,_,ChannelList}]} = database:check_socket(Socket),
    case lists:member(Channel,ChannelList) of
        true ->
            {_,[{channel,Channel,_Users,Topic}]} = database:check_channel(Channel),
            case Topic of
                <<"">> ->
                    gen_tcp:send(Socket,?REPLY_JOINTOPIC);
                _ ->
                    gen_tcp:send(Socket,?REPLY_JOINNOTOPIC)
            end;
        false ->
            gen_tcp:send(Socket,?REPLY_NOTINCHANNEL)
    end,
    get_topic(Tail,{_ServerIp, ServerHostent},Socket).

%% @doc Sets the TOPIC of the channel/channels if the user have Admin MODE.
set_topic([],_Topic,_Host,_Socket) ->
    ok;
set_topic([Channel|Tail],Topic,{_ServerIp, ServerHostent},Socket) ->
    {_,[{user,_,User,{_,Nick},_,Hostent,_,ChannelList}]} = database:check_socket(Socket),
    case lists:member(Channel,ChannelList) of
        true ->
            {_,[{channel,Channel,NickList,_OldTopic}]} = database:check_channel(Channel),
            case lists:keysearch(Nick,2,NickList) of
                {_,{<<"@">>,Nick}} ->
                    database:set_topic(Channel,Topic),
                    transmit:send_new_topic(NickList,Channel,Topic,Nick,User,Hostent);
                _ ->
                    gen_tcp:send(Socket,?REPLY_NOTCHANOP)
            end;
        false ->
            gen_tcp:send(Socket,?REPLY_NOTINCHANNEL)
    end,
    set_topic(Tail,Topic,{_ServerIp, ServerHostent},Socket).

%% @doc Sends an invitation to the user to join the channel.
%%      Replies with user already in channel if the Target is already in the channel.
%%      Replies with no such nick if the Target doesn't exist.
invite({_ServerIp,ServerHostent}, Socket, Target, Channel)->
    {_,[{user,_,User,{_,Nick},_,Hostent,_,_}]} = database:check_socket(Socket),
    case database:check_channel(Channel) of  
	{_,[]} ->
	    gen_tcp:send(Socket, ?REPLY_NOSUCHNICK);
	{_,[{channel, Channel, NickList,_}]} ->
	    case lists:keysearch(Target,2,NickList) of
		false ->
		    case database:check_nick(Target) of
			{_,[{user,TargetSocket,_,_,_,_,_,_}]} ->
			    gen_tcp:send(TargetSocket, ?REPLY_INVITING);
			_ ->
			    gen_tcp:send(Socket, ?REPLY_NOSUCHNICK)
		    end;
		_ ->
		    Reason = <<" already in channel">>,
		    gen_tcp:send(Socket, ?REPLY_USERONCHANNEL)
	    end
    end.

%% @doc TBI, will take care of the MODE IRC-command.
mode({_ServerIp,_ServerHostent},_Socket,_List)->
    ok.

%% @doc Kicks the Target from the channel.
kick({_ServerIp,ServerHostent},Socket,TargetChannel,Target,Comment)->
    {_,[{user,_,User,Nick,_,Hostent,_,ChannelList}]} = database:check_socket(Socket),
    case database:check_channel(TargetChannel) of
	{_,[]} ->
	    gen_tcp:send(Socket,?REPLY_NOSUCHNICK);
	{_,[{channel, Channel,NickList,_}]} ->
	    case lists:keysearch(Target,2,NickList) of
		false ->
		    gen_tcp:send(Socket,?REPLY_USERNOTONTHATCHANNEL);
		_ ->
		    case lists:member(TargetChannel,ChannelList) of
			true->
			    case database:check_nick(Target) of 
				{_, [{user,TargetSocket,_,_,_,_,_,_}]} ->
				    database:part_channel(TargetChannel,Target,TargetSocket),
				    if 
					Comment == [] ->
					    transmit:send_kick(NickList,Nick,User,Hostent,Target,TargetChannel);
					true ->					    
					    transmit:send_kick_comment(NickList,Nick,User,Hostent,Target,TargetChannel,Comment)
				    end;
				_ ->
				    gen_tcp:send(Socket,?REPLY_NOSUCHNICK)
			    end;
			_ ->
			    gen_tcp:send(Socket,?REPLY_NOTONCHANNEL)
		    end
	    end
    end.

%% @doc Replies with those who are registered to the channel.
names(_Host,[],_Socket,_Nick)->
    ok;
names({_ServerIp,ServerHostent},[Channel|Tail],Socket,Nick)->
    case database:check_channel(Channel) of
	 {_,[{channel,_,Users,_Topic}]} ->
	    UserList = transmit:convert_nicklist(Users),
	    gen_tcp:send(Socket,?REPLY_JOINNAMREPLY),
	    gen_tcp:send(Socket,?REPLY_ENDOFNAMES);
	_ ->
	    ok
    end,
    names({_ServerIp,ServerHostent},Tail,Socket, Nick).

%% @hidden
get_all_channels() ->
    {_,Channel} = database:get_first_channel(channel),
    get_all_channels(Channel,[Channel]).
%% @hidden
get_all_channels(ChannelKey,Ack) ->
    {_,Channel} = database:get_next_channel(channel,ChannelKey),
    if 
	Channel == '$end_of_table' ->
	    Ack;
	true ->
	    get_all_channels(Channel,[Channel|Ack])
    end.
    
%% @doc Replies with all known channels
list(Host, Socket,Nick)->
    ChannelList = get_all_channels(),
    list(Host,ChannelList,Socket,Nick).

%% @hidden
list({_ServerIp,ServerHostent},[],Socket,Nick)->
    Info = <<"">>,
    gen_tcp:send(Socket,?REPLY_LISTENED);
list({_ServerIp,ServerHostent},[Channel|Tail],Socket,Nick)->
    {_,[{channel,_,NickList,Topic}]} = database:check_channel(Channel),
    Number = length(NickList),
    gen_tcp:send(Socket,?REPLY_LIST),
    list({_ServerIp,ServerHostent},Tail,Socket,Nick).

%% @doc Replies with who the Target is.
who({_ServerIp,ServerHostent},Socket,Nick,Target) ->
    case transmit:is_channel(Target) of
        true ->
            Channel = Target,
            case database:check_channel(Channel) of
                {_,[{channel,_,NickList,_}]} ->
                    transmit:send_wholist(NickList,Socket,Nick,ServerHostent,Channel),
                    gen_tcp:send(Socket,?REPLY_ENDOFWHO);
                _ ->
                    gen_tcp:send(Socket,?REPLY_ENDOFWHO)
            end;
        false ->
            case database:check_nick(Target) of
                {_,[{user,_,User,{_,NickDb},UserServer,UserHostent,RealName,_ChannelList}]} ->
                    Channel = Target,
                    Status = <<"">>,
                    gen_tcp:send(Socket,?REPLY_WHO),
                    gen_tcp:send(Socket,?REPLY_ENDOFWHO);
                _ ->
                    Channel = <<"*">>,
                    gen_tcp:send(Socket,?REPLY_ENDOFWHO)
            end
    end.
