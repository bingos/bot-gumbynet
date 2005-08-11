package Trust;

use POE;
use POE::Component::IRC::Plugin qw( :ALL );

# REGEXES
our $punc_rx = qr([?.!]?);
our $nick_rx = qr([a-z0-9^`{}_|\][a-z0-9^`{}_|\-]*)i;
our $chan_rx = qr(#$nick_rx)i;
our $names_rx = qr/^\=\s+($chan_rx)\s+:(.+)?\s+$/;
our $messages_trust = qr/^(trust|distrust|believe|disbelieve)\s+(.+)$/;
our $messages_in_channel = qr/\s+(?:in\s+($chan_rx))\s*/;
our $messages_trust_channel = qr/(.+?)\s+(?:in\s+($chan_rx))\s*$/;

sub new {
  my ($package) = shift;

  my ($self) = bless( { @_ }, $package );

  POE::Session->create(
	object_states => [
	  $self => [ qw(_start _stop _on_join _bot_channels _retrieve_trusts _retrieve_salute _spread_ops) ],
	],
	options => { trace => 0 },
  );

  return $self;
}

##########################
# Plugin related methods #
##########################

sub PCI_register {
  my ($self,$irc) = @_;

  $self->{irc} = $irc;

  $irc->plugin_register( $self, 'SERVER', qw(join mode nick public) );

  return 1;
}

sub PCI_unregister {
  my ($self,$irc) = @_;

  delete ( $self->{irc} );

  $poe_kernel->refcount_decrement( $self->{SESSION_ID}, __PACKAGE__ );

  return 1;
}

sub S_join {
  my ($self,$irc) = splice @_, 0 , 2;
  my ($who) = ${ $_[0] };
  my ($nick) = ( split /!/, $who )[0];
  my ($channel) = ${ $_[1] };
  my ($mode);

  SWITCH: {
    if ( not $self->trusted_channel( $channel ) ) {
	last SWITCH;
    }
    if ( $self->_is_trusted( $channel, $who ) ) {
	$mode = 'o';
	last SWITCH;
    }
    if ( $self->_is_henchman( $channel, $who ) ) {
	$mode = 'h';
	last SWITCH;
    }
    if ( $self->_is_believed( $channel, $who ) ) {
	$mode = 'v';
	last SWITCH;
    }
  }

  if ( $mode and $irc->is_channel_operator( $channel, $irc->nick_name() ) ) {
	$irc->yield( mode => $channel => ( '+' . $mode ) => $nick );
  }

  return PCI_EAT_NONE;
}

sub S_nick {
  my ($self,$irc) = splice @_, 0 , 2;
  my ($old,$userhost) = ( split /!/, ${ $_[0] } )[0..1];
  my ($nick) = ${ $_[1] };
  my ($who) = $nick . '!' . $userhost;

  foreach my $channel ( @{ ${ $_[2] } } ) {
    my ($mode);
    SWITCH: {
      if ( not $self->trusted_channel( $channel ) ) {
	last SWITCH;
      }
      if ( $self->_is_trusted( $channel, $who ) ) {
	$mode = 'o';
	last SWITCH;
      }
      if ( $self->_is_henchman( $channel, $who ) ) {
	$mode = 'h';
	last SWITCH;
      }
      if ( $self->_is_believed( $channel, $who ) ) {
	$mode = 'v';
	last SWITCH;
      }
    }

    if ( $mode and $irc->is_channel_operator( $channel, $irc->nick_name() ) ) {
	$irc->yield( mode => $channel => ( '+' . $mode ) => $nick );
    }
  }

  return PCI_EAT_NONE;
}

sub S_mode {
  my ($self,$irc) = splice @_, 0 , 2;
  my ($nick,$userhost) = ( split /!/, ${ $_[0] } )[0..1];
  my ($channel) = ${ $_[1] };
  return PCI_EAT_NONE unless ( $self->trusted_channel( $channel ) );
  my ($mynick) = $irc->nick_name();
  return PCI_EAT_NONE if ( u_irc ( $nick ) eq u_irc ( $mynick ) );
  return PCI_EAT_NONE if ( u_irc ( $channel ) eq u_irc ( $mynick ) );
  my ($parsed_mode) = parse_mode_line( map { $$_ } @_[ 2 .. $#_ ] );

  my ($trusted_nick) = $self->_is_trusted( $channel, ${ $_[0] } );

  while ( my $mode = shift ( @{ $parsed_mode->{modes} } ) ) {
    my $arg = shift ( @{ $parsed_mode->{args} } ) if ( $mode =~ /^(\+[hovklbIe]|-[hovbIe])/ );
	SWITCH: {
	   if ( $trusted_nick and $mode eq '+o' and u_irc ( $arg ) eq u_irc ( $mynick ) ) {
		$poe_kernel->post( $self->{SESSION_ID}, '_spread_ops', $channel );
		last SWITCH;
	   }
	   if ( $trusted_nick and $mode =~ /^\+([ohv])/ ) {
		my ($flag) = $1;
		my ($full) = $irc->nick_long_form( $arg );
		if ( u_irc ( $arg ) ne u_irc ( $mynick ) and ( not $self->_check( $channel, $full, $flag ) ) ) {
		  if ( $self->_record( $channel, $full, '+', $flag ) ) {
			#$self->_salute( $channel, ( split /!/, $full )[0], $mode );
		  }
		}
		last SWITCH;
	   }
	   if ( $mode eq '+o' and u_irc ( $arg ) eq u_irc ( $mynick ) ) {
		if ( $self->_record( $channel, $nick . '!' . $userhost, '+', $flag ) ) {
			#$self->_salute( $channel, $nick, $mode );
		}
		last SWITCH;
	   }
	}
  }

  return PCI_EAT_NONE;
}

sub S_public {
  my ($self,$irc) = splice @_, 0 , 2;
  my ($nick,$userhost) = ( split /!/, ${ $_[0] } )[0..1];
  my ($channel) = ${ $_[1] }->[0];
  return PCI_EAT_NONE unless ( $self->trusted_channel( $channel ) );
  my ($what) = ${ $_[2] };
  
  my ($mynick) = $irc->nick_name();
  my ($command) = $what =~ m/^\s*\Q$mynick\E[\:\,\;\.]?\s*(.*)$/i;
  return PCI_EAT_NONE unless $command;

  my ($msg,@modes) = $self->_told( $channel, $nick, $command );
 
  return PCI_EAT_NONE unless ( $msg );

  $irc->yield( privmsg => $channel => $msg );

  foreach my $mode ( @modes ) {
	$irc->yield( mode => $mode );
  }

  return PCI_EAT_NONE;
}

#############################
# POE based handler methods #
#############################

sub _start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $self->{SESSION_ID} = $_[SESSION]->ID();

  $kernel->refcount_increment( $self->{SESSION_ID}, __PACKAGE__ );

  $kernel->post( $self->{dbi} => array => 
  { 
	sql => 'select Channel from BotChannels where NickName = ?',
	placeholders => [ $self->{botnick} ],
	event => '_bot_channels',
  } );
}

sub _stop {
}

sub _bot_channels {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my ($result) = $_[ARG0]->{result};
  my ($error) = $_[ARG0]->{error};

  if ( not defined ( $error ) ) {
	foreach my $channel ( @{ $result } ) {
		$self->{TRUSTS}->{ u_irc ( $channel ) } = { };
		$kernel->post( $self->{dbi} => arrayhash => 
		{
		  sql => 'select * from Trust where BotNick = ? and Channel = ?',
		  placeholders => [ $self->{botnick}, $channel ],
		  event => '_retrieve_trusts',
		} );
	}
  }
}

sub _retrieve_trusts {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my ($result) = $_[ARG0]->{result};
  my ($error) = $_[ARG0]->{error};

  if ( not defined ( $error ) ) {
	foreach my $row ( @{ $result } ) {
		$self->{TRUSTS}->{ u_irc ( $row->{Channel} ) }->{ $row->{Identity} } = $row->{Mode};
	}
  }
}

sub _retrieve_salute {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my ($result) = $_[ARG0]->{result};
  my ($error) = $_[ARG0]->{error};
  my ($nick) = $_[ARG0]->{_nick};
  my ($channel) = $_[ARG0]->{_channel};

  if ( not defined ( $error ) ) {
	foreach my $salute ( @{ $result } ) {
	   $salute =~ s/<nick>/$nick/i;
	   $self->{irc}->yield( ctcp => $channel => 'ACTION ' . $salute );
	}
  }
}

sub _on_join {
  my ($self) = $_[OBJECT];
  my ($result) = $_[ARG0]->{result};
  my ($error) = $_[ARG0]->{error};

  if ( not defined ( $error ) ) {
	foreach my $row ( @{ $result } ) {
	   my ($nick) = ( split /!/, $row->{Identity} )[0];
	   $self->{irc}->yield( mode => $row->{Channel} => ( '+' . $row->{Mode} ) => $nick );
	}
  }

}

sub _spread_ops {
  my ($kernel,$self,$channel) = @_[KERNEL,OBJECT,ARG0];
  my ($irc) = $self->{irc};
  my (@nicks);

  foreach my $nick ( $self->{irc}->channel_list( $channel ) ) {
	if ( not ( $irc->is_channel_operator( $channel, $nick ) or $irc->is_channel_halfop( $channel, $nick ) or $irc->has_channel_voice( $channel, $nick ) ) ) {
		push ( @nicks, $nick );
	}
  }

  my @trust = ();
  my @believe = ();
  my @hench = ();
  my @modes = ();

  foreach my $nick ( @nicks ) {
        if ($self->_check($channel,$nick,'o')) {
            push @trust, $nick;
        }
        elsif ($self->_check($channel,$nick,'v')) {
            push @believe, $nick;
        }	
	elsif ($self->_check($channel,$nick,'h')) {
	    push @hench, $nick;
	}
  }

  return unless @trust || @believe || @hench;

  #$irc->call( ctcp => $channel => 'ACTION spreads the love...' );

  push @modes, $self->_build_modes($channel,'+','o',@trust);
  push @modes, $self->_build_modes($channel,'+','v',@believe);
  push @modes, $self->_build_modes($channel,'+','h',@hench);

  foreach my $mode ( @modes ) {
        $irc->yield( mode => $mode );
  }
}

#########################
# Trust related methods #
#########################

sub _check_old {
  my ($self) = shift;
  my ($channel) = u_irc ( $_[0] ) || return 0;
  my ($who) = $_[1] || return 0;
  my ($mode) = $_[2] || return 0;

  unless ( defined ( $self->{TRUSTS}->{ $channel } ) ) {
	return 0;
  }

  my ( $nick, $userhost ) = $self->_parse_nick( $who );
  return 0 unless ( $nick and $userhost );

  $who = u_irc ( $nick ) . '!' . lc ( $userhost );

  if ( defined ( $self->{TRUSTS}->{ $channel }->{ $who } ) and $self->{TRUSTS}->{ $channel }->{ $who } =~ /$mode/ ) {
	return 1;
  }

  return 0;
}

sub _check {
  my ($self) = shift;
  my ($channel) = u_irc ( $_[0] ) || return 0;
  my ($who) = $_[1] || return 0;
  my ($mode) = $_[2] || return 0;

  return 1 if ( $self->_bot_owner( $who ) );

  unless ( defined ( $self->{TRUSTS}->{ $channel } ) ) {
	return 0;
  }

  my ( $nick, $userhost ) = $self->_parse_nick( $who );
  return 0 unless ( $nick and $userhost );
 
  $userhost = $self->_sanitise_userhost( $userhost );

  $userhost = quotemeta( $userhost );

  $userhost =~ s/\\\*/[\x01-\xFF]{0,}/g;

  $who = u_irc ( $nick ) . '!' . lc ( $userhost );

  foreach my $trust ( keys %{ $self->{TRUSTS}->{ $channel } } ) {
	if ( $trust =~ /^$who$/ and $self->{TRUSTS}->{ $channel }->{ $trust } =~ /$mode/ ) {
		return 1;
	}
  }

  return 0;
}

sub _is_trusted {
  my ($self) = shift;

  return $self->_check( $_[0], $_[1], 'o' );
}

sub _is_believed {
  my ($self) = shift;

  return $self->_check( $_[0], $_[1], 'v' );
}

sub _is_henchman {
  my ($self) = shift;

  return $self->_check( $_[0], $_[1], 'h' );
}

sub _salute {
  my ($self) = shift;
  my ($channel) = $_[0] || return 0;
  my ($nick) = $_[1] || return 0;
  my ($action) = $_[2] || return 0;

  $poe_kernel->post( $self->{dbi} => array =>
  {
	sql => 'select Salute from Salutes where Action = ? order by rand() limit 1',
	placeholders => [ $action ],
	event => '_retrieve_salute',
	session => $self->{SESSION_ID},
	_nick => $nick,
	_channel => $channel,
  } );

  return 1;
}

sub _record {
  my ($self) = shift;
  my ($channel) = u_irc ( $_[0] ) || return 0;
  my ($who) = $_[1] || return 0;
  my ($give_take) = $_[2] || return 0;
  my ($mode) = $_[3] || return 0;

  my ( $nick, $userhost ) = $self->_parse_nick( $who );
  return 0 unless ( $nick and $userhost );

  $who = u_irc ( $nick ) . '!' . lc ( $userhost );

  if ( $give_take eq '+' ) {
  	$self->{TRUSTS}->{ $channel }->{ $who } = $mode;
  	$poe_kernel->post( $self->{dbi} => insert => 
  	{
		sql => 'insert into Trust (BotNick,Channel,Identity,Mode) values (?,?,?,?)',
		placeholders => [ $self->{botnick}, $channel, $who, $mode ],
		session => $self->{SESSION_ID},
		event => '_added_user',
  	} );
	return 1;
  }
  if ( $give_take eq '-' ) {
  	delete $self->{TRUSTS}->{ $channel }->{ $who };
  	$poe_kernel->post( $self->{dbi} => do => 
  	{
		sql => 'delete from Trust where BotNick = ? and Channel = ? and Identity = ? and Mode = ?',
		placeholders => [ $self->{botnick}, $channel, $who, $mode ],
		session => $self->{SESSION_ID},
		event => '_deleted_user',
  	} );
	return 1;
  }

  return 0;
}

sub _told {
  my ($self) = shift;
  my ($channel) = $_[0] || return undef;
  my ($from_nick) = $_[1] || return undef;
  my ($message) = $_[2] || return undef;

  my $nick = '';
  # trust | distrust | believe | disbelieve
  if (my ($command,$nicks_channel) = $message =~ /$messages_trust/) {;
        my ($nicks,$optional_channel) = $nicks_channel =~ /$messages_trust_channel/;
        $nicks ||= $nicks_channel;
        $channel = $optional_channel || $channel;
        my @nicks = split /\s+/, $nicks;
        return "But I don't trust _you_ $from_nick" unless $self->_check($channel,$from_nick,'o');
        return $self->$command($channel,$from_nick,@nicks);
  }

  # check trust
  elsif (($nick) = $message =~ /^do\s+you\s+trust\s+($nick_rx).*?$punc_rx/i) {
        my ($optional_channel) = $message =~ /$messages_in_channel/;
        $channel = $optional_channel if $optional_channel;
        my $response = $nick eq $from_nick ?  "trust you in $channel" : "trust $nick in $channel";
        return $self->_check($channel,$nick,'o') ? "Yes, I $response" : "No, I don't $response";
  }

  # check believe
  elsif (($nick) = $message =~ /^do\s+you\s+believe\s+($nick_rx).*?$punc_rx/i) {
        my ($optional_channel) = $message =~ /$messages_in_channel/;
        $channel = $optional_channel if $optional_channel;
        return $self->_check($channel,$nick,'v') ? "Yes I do" : "Hell no, are you kidding me?";
        my $response = $nick eq $from_nick ?  "believe you in $channel" :
            "believe $nick in $channel";
        return $self->_check($channel,$nick,'o') ? "Yes, I $response" : "No, I don't $response";
  }

  return undef;
}

sub trusted_channel {
  my ($self) = shift;
  my ($channel) = u_irc ( $_[0] ) || return 0;

  if ( $channel eq '#PERL' ) {
	return 0;
  }
  return 1;
}

sub _parse_nick {
  my ($self) = shift;
  my ($who) = shift || return undef;
  my ($nick,$userhost);

  if ( $who =~ /!/ ) {
	($nick,$userhost) = ( split /!/, $who )[0..1];
  } else {
	($nick,$userhost) = ( split /!/, $self->{irc}->nick_long_form($who) )[0..1];
  }
  return ( $nick, $userhost );
}

sub _sanitise_userhost {
  my ($self) = shift;
  my ($userhost) = shift || return undef;

  my ($user,$host) = split /\@/, $userhost;

  SWITCH: {
    if ( $user =~ /^~/ ) {
	$user =~ s/~/\*/;
    }
    if ( $user =~ /\d/ ) {
	$user = '*';
    }
    # IP address
    if ( $host =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/ ) {
	last SWITCH;
    }
    my (@host) = split /\./, $host;
    if ( $host[0] =~ /\d/ ) {
	$host[0] = '*';
	$host = join('.', @host );
	last SWITCH;
    }
  }
  return join('@', $user, $host);
}

###################
# Command methods #
###################

sub trust {
    my ($self,$channel,$from_nick,@nicks) = @_;
    my @trusted_nicks = ();
    my @mode_nicks = ();

    return "But I don't trust _you_ $from_nick" unless $self->_check($channel,$from_nick,'o');

    for my $nick (@nicks) {
        if ($self->_check($channel,$nick,'o')) {
            push @trusted_nicks, $nick;
        }
        else {
            $self->_record($channel,$nick,'+','o');
            push @mode_nicks, $nick;
        }
    }

    my $privmsg = @trusted_nicks
        ? "$from_nick, I already trust " . _and_join(@trusted_nicks) : @mode_nicks
        ? "OK, $from_nick"                                          :
          "$from_nick, please specify nick(s) you would like me to trust";

    my @modes = $self->_build_modes($channel,'+','o',@mode_nicks);

    return $privmsg, @modes;
}

sub distrust {
    my ($self,$channel,$from_nick,@nicks) = @_;
    my @untrusted_nicks = ();
    my @mode_nicks = ();

    return "But I don't trust _you_ $from_nick" unless $self->_check($channel,$from_nick,'o');

    for my $nick (@nicks) {
        if ($self->_check($channel,$nick,'o')) {
            $self->_record($channel,$nick,'-','o');
            push @mode_nicks, $nick;
        }
        else {
            push @untrusted_nicks, $nick;
        }
    }

    my $privmsg = @untrusted_nicks
        ? "$from_nick, But I don't trust " . _and_join(@untrusted_nicks) : @mode_nicks
        ? "OK, $from_nick"                                               :
            "$from_nick, please specify nick(s) you'd like me to distrust";;

    my @modes = $self->_build_modes($channel,'-','o',@mode_nicks);

    return $privmsg, @modes;
}

sub believe {
    my ($self,$channel,$from_nick,@nicks) = @_;
    my @trust_nicks = ();
    my @believe_nicks = ();
    my @mode_nicks = ();

    return "But I don't trust _you_ $from_nick" unless $self->_check($channel,$from_nick,'o');

    for my $nick (@nicks) {
        if ($self->_check($channel,$nick,'o')) {
            push @trust_nicks, $nick;
        }
        elsif ($self->_check($channel,$nick,'v')) {
            push @believe_nicks, $nick;
        }
        else {
            push @mode_nicks, $nick;
            $self->_record($channel,$nick,'+','v');
        }
    }

    my ($trust_nicks,$believe_nicks);
    if (@trust_nicks && @believe_nicks) {
        $trust_nicks =   join ", ", @trust_nicks;
        $believe_nicks = join ", ", @believe_nicks;
    }
    else {
        $trust_nicks = _and_join(@trust_nicks);
        $believe_nicks = _and_join(@believe_nicks);
    }

    my $privmsg = $trust_nicks && $believe_nicks
        ? "I already trust $trust_nicks and believe $believe_nicks" : $trust_nicks
        ? "I already trust $trust_nicks"                            : $believe_nicks
        ? "I already believe $believe_nicks"                        : @mode_nicks
        ? "OK, $from_nick"                                          :
          "$from_nick, please specify nick(s) you'd like me to believe";

    my @modes = $self->_build_modes($channel,'+','v',@mode_nicks);

    return $privmsg, @modes;
}

sub disbelieve {
    my ($self,$channel,$from_nick,@nicks) = @_;
    my @non_believe_nicks = ();
    my @mode_nicks = ();

    return "But I don't trust _you_ $from_nick" unless $self->_check($channel,$from_nick,'o');

    for my $nick (@nicks) {
        if ($self->_check($channel,$nick,'v')) {
            $self->_record($channel,$nick,'-','v');
            push @mode_nicks, $nick;
        }
        else {
            push @non_believe_nicks, $nick;
        }
    }

    my $privmsg = @non_believe_nicks
        ? "I don't believe " . _and_join(@non_believe_nicks)       : @mode_nicks
        ? "OK, $from_nick"                                        :
          "$from_nick, please specify nick(s) you'd like me to disbelieve";

    my @modes = $self->_build_modes($channel,'-','v',@mode_nicks);

    return $privmsg, @modes;

}

sub _build_modes {
    my ($self,$channel,$give_take,$mode,@nicks) = @_;
    return unless $self->{irc}->is_channel_operator( $channel, $self->{irc}->nick_name() );
    my @modes = ();

    while (my @subset = splice(@nicks,0,4)) {
        push @modes, $channel . ' ' .  $give_take . $mode x @subset . " " . join ' ', @subset;
    }
    return @modes;
}

sub _bot_owner {
  my ($self) = shift;
  my ($who) = $_[0] || return 0;
  my ($nick,$userhost);

  unless ( $self->{botowner} ) {
        return 0;
  }

  if ( $who =~ /!/ ) {
        ($nick,$userhost) = ( split /!/, $who )[0..1];
  } else {
        ($nick,$userhost) = ( split /!/, $self->{irc}->nick_long_form($who) )[0..1];
  }

  unless ( $nick and $userhost ) {
        return 0;
  }

  $who = l_irc ( $nick ) . '!' . l_irc ( $userhost );

  if ( $self->{botowner} =~ /[\x2A\x3F]/ ) {
        my ($owner) = l_irc ( $self->{botowner} );
        $owner =~ s/\x2A/[\x01-\xFF]{0,}/g;
        $owner =~ s/\x3F/[\x01-\xFF]{1,1}/g;
        if ( $who =~ /$owner/ ) {
                return 1;
        }
  } elsif ( $who eq l_irc ( $self->{botowner} ) ) {
        return 1;
  }

  return 0;
}

###########################
# Miscellaneous functions #
###########################

sub u_irc {
  my ($value) = shift || return undef;

  $value =~ tr/a-z{}|/A-Z[]\\/;
  return $value;
}

sub l_irc {
  my ($value) = shift || return undef;

  $value =~ tr/A-Z[]\\/a-z{}|/;
  return $value;
}

sub parse_mode_line {
  my ($hashref) = { };

  my ($count) = 0;
  foreach my $arg ( @_ ) {
        if ( $arg =~ /^(\+|-)/ or $count == 0 ) {
           my ($action) = '+';
           foreach my $char ( split (//,$arg) ) {
                if ( $char eq '+' or $char eq '-' ) {
                   $action = $char;
                } else {
                   push ( @{ $hashref->{modes} }, $action . $char );
                }
           }
         } else {
                push ( @{ $hashref->{args} }, $arg );
         }
         $count++;
  }
  return $hashref;
}

sub _and_join {
    my (@array) = @_;
    return unless @array;
    return $array[0] if @array == 1;
    my $last_element = pop @array;
    return join(', ', @array) . ', and ' . $last_element;
}


1;
