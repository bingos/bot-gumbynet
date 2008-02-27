package Trust2;

use strict;
use warnings;
use POE;
use POE::Component::IRC::Plugin qw( :ALL );
use POE::Component::IRC::Common qw( :ALL );

# REGEXES
our $punc_rx = qr([?.!]?);
our $nick_rx = qr([a-z0-9^`{}_|\][a-z0-9^`{}_|\-]*)i;
our $chan_rx = qr(#$nick_rx)i;
our $names_rx = qr/^\=\s+($chan_rx)\s+:(.+)?\s+$/;
our $messages_trust = qr/^(trust|distrust|believe|disbelieve)\s+(.+)$/;
our $messages_in_channel = qr/\s+(?:in\s+($chan_rx))\s*/;
our $messages_trust_channel = qr/(.+?)\s+(?:in\s+($chan_rx))\s*$/;

sub new {
  my $package = shift;
  my %parms = @_;
  $parms{lc $_} = delete $parms{$_} for keys %parms;
  return bless \%parms, $package;
}

##########################
# Plugin related methods #
##########################

sub PCI_register {
  my ($self,$irc) = @_;
  $self->{irc} = $irc;
  $irc->plugin_register( $self, 'SERVER', qw(join chan_mode chan_sync nick public) );
  $self->{session_id} = POE::Session->create(
	object_states => [
	  $self => [ qw(_start _spread_ops _check_access) ],
	],
  )->ID();
  return 1;
}

sub PCI_unregister {
  my ($self,$irc) = @_;
  delete $self->{irc};
  $poe_kernel->refcount_decrement( $self->{session_id}, __PACKAGE__ );
  return 1;
}

sub S_join {
  my ($self,$irc) = splice @_, 0 , 2;
  my $who = ${ $_[0] };
  my ($nick,$userhost) = split /!/, $who;
  my $channel = ${ $_[1] };
  my $mapping = $irc->isupport('CASEMAPPING');
  if ( $nick eq $irc->nick_name() ) {
	$self->{CHAN_SYNCING}->{ u_irc $channel, $mapping } = 1;
  	return PCI_EAT_NONE;
  }
  return PCI_EAT_NONE unless $irc->is_channel_operator( $channel, $irc->nick_name() );

  if ( $self->_bot_owner( $who ) ) {
	$irc->yield( mode => $channel => "+o" => $nick );
	return PCI_EAT_NONE;
  }

  my $query = join '!', u_irc( $nick, $mapping ), $self->_sanitise_userhost($userhost); 

  $poe_kernel->post( $self->{dbi}, 'arrayhash', 
  {
	sql => 'select * from Trust where BotNick = ? and Channel = ? and Identity like ?',
	placeholders => [ $self->{botnick}, u_irc( $channel, $mapping ), $query ],
	session => $self->{session_id},
	event => '_check_access',
	_type => 'join',
	_nick => $nick,
	_chan => $channel,
  } );

  return PCI_EAT_NONE;
}

sub S_nick {
  my ($self,$irc) = splice @_, 0 , 2;
  my ($old,$userhost) = split /!/, ${ $_[0] };
  my $nick = ${ $_[1] };
  my $mapping = $irc->isupport('CASEMAPPING');
  my $query = join '!', u_irc( $nick, $mapping ), $self->_sanitise_userhost($userhost); 

  foreach my $channel ( @{ $_[2]->[0] } ) {
    next unless $irc->is_channel_operator( $channel, $irc->nick_name() );
    $poe_kernel->post( $self->{dbi}, 'arrayhash', 
    {
	sql => 'select * from Trust where BotNick = ? and Channel = ? and Identity like ?',
	placeholders => [ $self->{botnick}, u_irc( $channel, $mapping ), $query ],
	session => $self->{session_id},
	event => '_check_access',
	_type => 'nick',
	_nick => $nick,
	_chan => $channel,
    } );
  }
  return PCI_EAT_NONE;
}

sub S_chan_sync {
  my ($self,$irc) = splice @_, 0 , 2;
  my $channel = ${ $_[0] };
  my $mapping = $irc->isupport('CASEMAPPING');
  my $uchan = u_irc $channel, $mapping;
  my $value = delete $self->{CHAN_SYNCING}->{ $uchan };
  $poe_kernel->post( $self->{session_id} => _spread_ops => $channel ) if $value == 2;
  return PCI_EAT_NONE;
}

sub S_chan_mode {
  my ($self,$irc) = splice @_, 0 , 2;
  my $mapping = $irc->isupport('CASEMAPPING');
  my ($nick,$userhost) = ( split /!/, ${ $_[0] } )[0..1];
  return PCI_EAT_NONE if $nick =~ /\./;
  my $channel = ${ $_[1] };
  my $mode = ${ $_[2] };
  my $args = ${ $_[3] };
  return PCI_EAT_NONE unless $mode =~ /\+[ohv]/;
  my $mynick = $irc->nick_name();
  return PCI_EAT_NONE if u_irc ( $nick, $mapping ) eq u_irc ( $mynick, $mapping );

  my $query = join '!', u_irc( $nick, $mapping ), $self->_sanitise_userhost($userhost); 
  $mode =~ s/\+//g;

  $poe_kernel->post( $self->{dbi}, 'arrayhash', 
  {
	sql => 'select * from Trust where BotNick = ? and Channel = ? and Identity like ?',
	placeholders => [ $self->{botnick}, u_irc( $channel, $mapping ), $query ],
	session => $self->{session_id},
	event => '_check_access',
	_type => 'mode',
	_nick => $nick, 
	_uhost => $userhost,
	_chan => $channel,
	_mode => $mode,
	_args => $args,
  } );

  return PCI_EAT_NONE;
}

sub S_public {
  my ($self,$irc) = splice @_, 0 , 2;
  my ($from_nick,$userhost) = ( split /!/, ${ $_[0] } )[0..1];
  return PCI_EAT_NONE if uc( $from_nick ) eq 'PURL';
  my $channel = ${ $_[1] }->[0];
  my $targchan = $channel;
  my $what = ${ $_[2] };
  
  my $mynick = $irc->nick_name();
  my ($message) = $what =~ m/^\s*\Q$mynick\E[\:\,\;\.]?\s*(.*)$/i;
  return PCI_EAT_NONE unless $message;
  my $mapping = $irc->isupport('CASEMAPPING');

  my $nick;
  if (my ($command,$nicks_channel) = $message =~ /$messages_trust/) {;
  	my $query = join '!', u_irc( $from_nick, $mapping ), $self->_sanitise_userhost($userhost); 
        my ($nicks,$optional_channel) = $nicks_channel =~ /$messages_trust_channel/;
        $nicks ||= $nicks_channel;
        $channel = $optional_channel || $channel;
        my @nicks = split /\s+/, $nicks;
	$poe_kernel->post( $self->{dbi}, 'arrayhash',
	{
	  sql => 'select * from Trust where BotNick = ? and Channel = ? and Identity like ? and Mode = ?',
	  placeholders => [ $self->{botnick}, u_irc( $channel, $mapping ), $query, 'o' ],
	  session => $self->{session_id},
	  event => '_check_access',
	  _type => 'command',
	  _cmd  => $command,
	  _nick => $from_nick,
	  _chan => $channel,
	  _list => \@nicks,
	} );
	return PCI_EAT_NONE;
  }

  # check trust
  elsif (($nick) = $message =~ /^do\s+you\s+trust\s+($nick_rx).*?$punc_rx/i) {
        my ($optional_channel) = $message =~ /$messages_in_channel/;
        $channel = $optional_channel if $optional_channel;
	if ( $self->_bot_owner( $nick ) ) {
	  $irc->yield( 'privmsg', $targchan, "Yes, I trust $nick in $channel" );
	  return PCI_EAT_NONE;
	}
	my ($n,$uh) = $self->_parse_nick( $nick );
	unless ( $n and $uh ) {
	  $irc->yield( 'privmsg', $targchan, "Who the hell is $nick ?!" );
	  return PCI_EAT_NONE;
	}
	my $query = join '!', u_irc( $n, $mapping ), $self->_sanitise_userhost( $uh );
	$poe_kernel->post( $self->{dbi}, 'arrayhash', 
	{
	  sql => 'select * from Trust where BotNick = ? and Channel = ? and Identity like ? and Mode = ?',
	  placeholders => [ $self->{botnick}, u_irc( $channel, $mapping ), $query, 'o' ],
	  session => $self->{session_id},
	  event => '_check_access',
	  _type => 'query_trust',
	  _nick => $from_nick,
	  _who  => $n,
	  _chan => $channel,
	  _targ => $targchan,
	} );
	return PCI_EAT_NONE;
  }

  # check believe
  elsif (($nick) = $message =~ /^do\s+you\s+believe\s+($nick_rx).*?$punc_rx/i) {
        my ($optional_channel) = $message =~ /$messages_in_channel/;
        $channel = $optional_channel if $optional_channel;
        #return $self->_check($channel,$nick,'v') ? "Yes I do" : "Hell no, are you kidding me?";
        #my $response = $nick eq $from_nick ?  "believe you in $channel" :
        #    "believe $nick in $channel";
        #return $self->_check($channel,$nick,'o') ? "Yes, I $response" : "No, I don't $response";
	if ( $self->_bot_owner( $nick ) ) {
	  $irc->yield( 'privmsg', $targchan, "Yes, I believe $nick in $channel" );
	  return PCI_EAT_NONE;
	}
	my ($n,$uh) = $self->_parse_nick( $nick );
	unless ( $n and $uh ) {
	  $irc->yield( 'privmsg', $targchan, "Who the hell is $nick ?!" );
	  return PCI_EAT_NONE;
	}
	my $query = join '!', u_irc( $n, $mapping ), $self->_sanitise_userhost( $uh );
	$poe_kernel->post( $self->{dbi}, 'arrayhash', 
	{
	  sql => 'select * from Trust where BotNick = ? and Channel = ? and Identity like ? and Mode = ?',
	  placeholders => [ $self->{botnick}, u_irc( $channel, $mapping ), $query, 'v' ],
	  session => $self->{session_id},
	  event => '_check_access',
	  _type => 'query_belief',
	  _nick => $from_nick,
	  _who  => $nick,
	  _chan => $channel,
	  _targ => $targchan,
	} );
	return PCI_EAT_NONE;
  }
  return PCI_EAT_NONE;
}

#############################
# POE based handler methods #
#############################

sub _start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $self->{session_id} = $_[SESSION]->ID();
  $kernel->refcount_increment( $self->{session_id}, __PACKAGE__ );
  undef;
}

sub _check_access {
  my ($kernel,$self,$data) = @_[KERNEL,OBJECT,ARG0];
  my $result = $data->{result};
  my $error = $data->{error};
  return if defined $error;
  my $type = $data->{_type};
  my $mapping = $self->{irc}->isupport('CASEMAPPING');
  my $mynick = $self->{irc}->nick_name();
  SWITCH: {
    if ( $type =~ /^(join|nick)$/ ) {
	my $mode = '';
	foreach my $row ( @{ $result } ) {
	  my $rmode = $row->{Mode};
	  next if $rmode eq 'v' and $mode =~ /[oh]/;
	  next if $rmode eq 'h' and $mode =~ /o/;
	  $mode = $rmode;
	}
	last SWITCH unless $mode;
	last SWITCH if $mode eq 'v' and $self->{irc}->has_channel_voice( $data->{_chan}, $data->{_nick} );
	last SWITCH if $mode eq 'h' and $self->{irc}->is_channel_halfop( $data->{_chan}, $data->{_nick} );
	last SWITCH if $mode eq 'o' and $self->{irc}->is_channel_operator( $data->{_chan}, $data->{_nick} );
	$self->{irc}->yield( mode => $data->{_chan} => "+$mode" => $data->{_nick} );
	last SWITCH;
    }
    if ( $type eq 'mode' ) {
	my $mode = '';
	foreach my $row ( @{ $result } ) {
	  my $rmode = $row->{Mode};
	  next if $rmode eq 'v' and $mode =~ /[oh]/;
	  next if $rmode eq 'h' and $mode =~ /o/;
	  $mode = $rmode;
	}
	if ( !$mode and $data->{_mode} =~ /o/ and u_irc( $data->{_args}, $mapping ) eq u_irc( $mynick, $mapping ) ) {
	  my $who = join '!', u_irc( $data->{_nick}, $mapping ), $data->{_uhost};
	  $kernel->post( $self->{dbi}, 'insert', 
	  {
                sql => 'insert into Trust (BotNick,Channel,Identity,Mode) values (?,?,?,?)',
                placeholders => [ $self->{botnick}, u_irc( $data->{_chan}, $mapping ), $who, 'o' ],
                session => $self->{session_id},
                event => '_added_user',
	  } );
	  last SWITCH;
	}
	if ( $data->{_mode} =~ /o/ and u_irc( $data->{_args}, $mapping ) eq u_irc( $mynick, $mapping ) ) {
	  my $csync = u_irc $data->{_chan}, $mapping;
	  if ( $self->{CHAN_SYNCING}->{ $csync } ) { 
		$self->{CHAN_SYNCING}->{ $csync } = 2;
	  } else {
	  	$kernel->yield( '_spread_ops', $data->{_chan} );
	  }
	  last SWITCH;
	}
	last SWITCH unless $mode;
	# Okay dude is trusted.
	my ($nick,$userhost) = split /!/, $self->{irc}->nick_long_form( $data->{_args} );
	my $query = join '!', u_irc( $nick, $mapping ), $self->_sanitise_userhost( $userhost );
  	$kernel->post( $self->{dbi}, 'arrayhash', 
  	{
	  sql => 'select * from Trust where BotNick = ? and Channel = ? and Identity like ? and Mode = ?',
	  placeholders => [ $self->{botnick}, u_irc( $data->{_chan}, $mapping ), $query, $data->{_mode} ],
	  session => $self->{session_id},
	  event => '_check_access',
	  _type => 'record_mode',
	  _nick => $nick, 
	  _uhost => $userhost,
	  _chan => $data->{_chan},
	  _mode => $data->{_mode},
  	} );
	last SWITCH;
    }
    if ( $type eq 'record_mode' ) {
	last SWITCH if $data->{rows};
	my $who = join '!', u_irc( $data->{_nick}, $mapping ), $data->{_uhost};
	$kernel->post( $self->{dbi}, 'insert', 
	{
                sql => 'insert into Trust (BotNick,Channel,Identity,Mode) values (?,?,?,?)',
                placeholders => [ $self->{botnick}, u_irc( $data->{_chan}, $mapping ), $who, $data->{_mode} ],
                session => $self->{session_id},
                event => '_added_user',
	} );
	last SWITCH;
    }
    if ( $type eq 'command' and $data->{_cmd} =~ /^(trust|believe)$/i ) {
	unless ( $data->{rows} or $self->_bot_owner( $data->{_nick} ) ) {
	  $self->{irc}->yield( 'privmsg', $data->{_chan}, "But I don't trust _you_ " . $data->{_nick} );
	  last SWITCH;
	}
	my @nicks;
	foreach my $user ( @{ $data->{_list} } ) {
	  next unless $self->{irc}->is_channel_member( $data->{_chan}, $user );
	  push @nicks, $user;
	}
	unless ( @nicks ) {
	  $self->{irc}->yield( 'privmsg', $data->{_chan}, $data->{_nick} . ", please specify nick(s) you would like me to " . $data->{_cmd} );
	  last SWITCH;
	}
	$self->{irc}->yield( 'privmsg', $data->{_chan}, "Ok, " . $data->{_nick} );
	my $mode = ( $data->{_cmd} =~ /trust/ ? 'o' : 'v' );
	my $uchan = u_irc $data->{_chan}, $mapping;
	my @mode_nicks;
	foreach my $entity ( @nicks ) {
	  my ($nick,$userhost) = split /!/, $self->{irc}->nick_long_form( $entity );
	  my $query = join '!', u_irc( $nick, $mapping ), $self->_sanitise_userhost( $userhost );
  	  $kernel->post( $self->{dbi}, 'arrayhash', 
  	  {
	    sql => 'select * from Trust where BotNick = ? and Channel = ? and Identity like ? and Mode = ?',
	    placeholders => [ $self->{botnick}, $uchan, $query, $mode ],
	    session => $self->{session_id},
	    event => '_check_access',
	    _type => 'record_mode',
	    _nick => $nick, 
	    _uhost => $userhost,
	    _chan => $data->{_chan},
	    _mode => $mode,
  	  } );
	  next if $self->{irc}->_nick_has_channel_mode( $data->{_chan}, $nick, $mode );
	  push @mode_nicks, $nick;
	}
	my @modes = $self->_build_modes($data->{_chan},'+',$mode,@mode_nicks);
	$self->{irc}->yield( mode => $_ ) for @modes;
	last SWITCH;
    }
    if ( $type eq 'command' and $data->{_cmd} =~ /^(distrust|disbelieve)$/i ) {
	unless ( $data->{rows} or $self->_bot_owner( $data->{_nick} ) ) {
	  $self->{irc}->yield( 'privmsg', $data->{_chan}, "But I don't trust _you_ " . $data->{_nick} );
	  last SWITCH;
	}
	my @mode_nicks;
	$self->{irc}->yield( 'privmsg', $data->{_chan}, "Ok, " . $data->{_nick} );
	my $mode = ( $data->{_cmd} =~ /distrust/ ? 'o' : 'v' );
	my $uchan = u_irc $data->{_chan}, $mapping;
	foreach my $user ( @{ $data->{_list} } ) {
	  push @mode_nicks, $user if $self->{irc}->is_channel_member( $data->{_chan}, $user );
	  my $query = join '!', u_irc( $user, $mapping ), '%';
	  $kernel->post( $self->{dbi}, 'do', 
	  {
	    sql => 'delete from Trust where BotNick = ? and Channel = ? and Identity like ? and Mode = ?',
	    placeholders => [ $self->{botnick}, $uchan, $query, $mode ],
	    session => $self->{session_id},
	    event => '_delete_access',
	  } );
	}
	my @modes = $self->_build_modes($data->{_chan},'-',$mode,@mode_nicks);
	$self->{irc}->yield( mode => $_ ) for @modes;
	last SWITCH;
    }
    if ( $type eq 'query_trust' ) {
	my $channel = $data->{_chan};
	my $nick = $data->{_who};
        my $response = $nick eq $data->{_nick} ?  "trust you in $channel" : "trust $nick in $channel";
        $self->{irc}->yield( 'privmsg', $data->{_targ}, $data->{rows} ? "Yes, I $response" : "No, I don't $response" );
	last SWITCH;
    }
    if ( $type eq 'query_belief' ) {
	my $channel = $data->{_chan};
	my $nick = $data->{_who};
        my $response = $nick eq $data->{_nick} ?  "believe you in $channel" : "believe $nick in $channel";
        $self->{irc}->yield( 'privmsg', $data->{_targ}, $data->{rows} ? "Yes, I $response" : "No, I don't $response" );
	last SWITCH;
    }
  }
  undef;
}

sub _spread_ops {
  my ($kernel,$self,$channel) = @_[KERNEL,OBJECT,ARG0];
  my $irc = $self->{irc};
  my $mapping = $irc->isupport('CASEMAPPING');
  my @nicks;
  my $uchan = u_irc $channel, $mapping;

  foreach my $nick ( $irc->channel_list( $channel ) ) {
    next if $irc->is_channel_operator( $channel, $nick );
    next if $irc->is_channel_halfop( $channel, $nick );
    next if $irc->has_channel_voice( $channel, $nick );
    my $userhost = ( split /!/, $irc->nick_long_form( $nick ) )[1];
    my $query = join '!', u_irc( $nick, $mapping ), $self->_sanitise_userhost($userhost); 

    $kernel->post( $self->{dbi}, 'arrayhash', 
    {
	sql => 'select * from Trust where BotNick = ? and Channel = ? and Identity like ?',
	placeholders => [ $self->{botnick}, $uchan, $query ],
	session => $self->{session_id},
	event => '_check_access',
	_type => 'join',
	_nick => $nick,
	_chan => $channel,
    } );
  }
  undef;
}

sub _parse_nick {
  my $self = shift;
  my $who = shift || return;
  my ($nick,$userhost);

  if ( $who =~ /!/ ) {
	($nick,$userhost) = ( split /!/, $who )[0..1];
  } else {
	my $long_form = $self->{irc}->nick_long_form($who);
	return unless $long_form;
	($nick,$userhost) = ( split /!/, $long_form )[0..1];
  }
  return ( $nick, $userhost );
}

sub _sanitise_userhost {
  my $self = shift;
  my $userhost = shift || return;

  my ($user,$host) = split /\@/, $userhost;

  SWITCH: {
    if ( $user =~ /^~/ ) {
	$user =~ s/~/\%/;
    }
    if ( $user =~ /\d/ ) {
	$user = '%';
    }
    # IP address
    if ( $host =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/ ) {
	last SWITCH;
    }
    my @host = split /\./, $host;
    if ( $host[0] =~ /\d/ ) {
	$host[0] = '%';
	$host = join '.', @host;
	last SWITCH;
    }
  }
  return join '@', $user, $host;
}

sub _build_modes {
    my ($self,$channel,$give_take,$mode,@nicks) = @_;
    return unless $self->{irc}->is_channel_operator( $channel, $self->{irc}->nick_name() );
    my @modes = ();

    my $max_modes = $self->{irc}->isupport('MODES') || 4;

    while (my @subset = splice(@nicks,0,$max_modes)) {
        push @modes, $channel . ' ' .  $give_take . $mode x @subset . " " . join ' ', @subset;
    }
    return @modes;
}

sub _bot_owner {
  my $self = shift;
  return unless $self->{botowner};
  my $who = $_[0] || return 0;
  $who = $self->{irc}->nick_long_form($who) unless $who =~ /!/;
  return 1 if matches_mask( $self->{botowner}, $who );
  return 0;
}

1;
