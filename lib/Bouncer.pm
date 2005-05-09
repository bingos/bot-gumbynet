package Bouncer;

use Date::Format;
use Socket;
use POE qw(Wheel::SocketFactory Wheel::ReadWrite Filter::IRCD Filter::Line Filter::Stackable);
use POE::Component::IRC::Plugin qw( :ALL );
use Data::Dumper;

sub new {
  my ($package) = shift;

  my $self = bless { @_ }, $package;

  $self->{SESSION_ID} = POE::Session->create(
	object_states => [
	  $self => [ qw(_client_error _client_input _listener_accept _listener_failed _start _shutdown _spawn_listener) ],
	],
	options => { trace => 0 },
  )->ID();
  return $self;
}

sub PCI_register {
  my ($self,$irc) = splice @_, 0, 2;

  $self->{irc} = $irc;

  $irc->plugin_register( $self, 'SERVER', qw(raw 001 disconnected socketerr error public) );

  if ( $irc->{connected} ) {
	$poe_kernel->post( $self->{SESSION_ID} => '_spawn_listener' );
  }

  return 1;
}

sub S_public {
  my ($self,$irc) = splice @_, 0 , 2;
  my ($nick,$userhost) = ( split /!/, ${ $_[0] } )[0..1];
  #return PCI_EAT_NONE unless $self->_bot_owner( $nick );
  my ($channel) = ${ $_[1] }->[0];
  my ($what) = ${ $_[2] };

  my ($mynick) = $irc->nick_name();
  my ($command) = $what =~ m/^\s*\Q$mynick\E[\:\,\;\.]?\s*(.*)$/i;
  return PCI_EAT_NONE unless $command;


  my (@cmd) = split(/ +/,$command);

  SWITCH: {
    if ( uc ( $cmd[0] ) eq 'BNC' ) {
	foreach my $wheel_id ( keys %{ $self->{wheels} } ) {
		next if ( not defined ( $self->{wheels}->{ $wheel_id }->{wheel} ) );
		my ($client) = $self->{wheels}->{ $wheel_id };
		my $string = $client->{user} . '-' . $wheel_id;
		$string .= ' (' . $client->{peer} . ':' . $client->{port} . ')';
		$string .= time2str( " connected %a %h %e %T %Y %Z. ", $client->{start} );
		$string .= 'Uptime: ' . timestring( $client->{start} );
		$irc->yield( privmsg => $channel => $string );
	}
	last SWITCH;
    }
    if ( uc ( $cmd[0] ) eq 'DMP' ) {
	open (FILE,">dumpit.out") or die;
	print FILE Dumper( $self );
	close(FILE);
	last SWITCH;
    }
  }
  return PCI_EAT_NONE;
}

sub PCI_unregister {
  my ($self,$irc) = splice @_, 0, 2;

  delete ( $self->{irc} );

  $poe_kernel->post( $self->{SESSION_ID} => '_shutdown' );
  $poe_kernel->refcount_decrement( $self->{SESSION_ID}, __PACKAGE__ );

  return 1;
}

sub S_001 {
  my ($self,$irc) = splice @_, 0, 2;

  $poe_kernel->post( $self->{SESSION_ID} => '_shutdown' );
  $poe_kernel->post( $self->{SESSION_ID} => '_spawn_listener' );
  return PCI_EAT_NONE;
}

sub S_disconnected {
  my ($self,$irc) = splice @_, 0, 2;

  $poe_kernel->post( $self->{SESSION_ID} => '_shutdown' );
  return PCI_EAT_NONE;
}

sub S_socketerr {
  my ($self,$irc) = splice @_, 0, 2;

  $poe_kernel->post( $self->{SESSION_ID} => '_shutdown' );
  return PCI_EAT_NONE;
}

sub S_error {
  my ($self,$irc) = splice @_, 0, 2;

  $poe_kernel->post( $self->{SESSION_ID} => '_shutdown' );
  return PCI_EAT_NONE;
}

sub S_raw {
  my ($self,$irc) = splice @_, 0, 2;
  my ($line) = ${ $_[0] };

  return PCI_EAT_ALL if ( $line =~ /^PING\s*/ );
  foreach my $wheel_id ( keys %{ $self->{wheels} } ) {
	$self->_send_to_client( $wheel_id, $line );
  }
  return PCI_EAT_ALL;
}

sub _send_to_client {
  my ($self,$wheel_id,$line) = splice @_, 0, 3;

  $self->{wheels}->{ $wheel_id }->{wheel}->put( $line ) if ( defined ( $self->{wheels}->{ $wheel_id }->{wheel} ) and $self->{wheels}->{ $wheel_id}->{reg} );
  return 1;
}

sub _start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $self->{SESSION_ID} = $_[SESSION]->ID();
  $kernel->refcount_increment( $self->{SESSION_ID}, __PACKAGE__ );
  $self->{ircd_filter} = POE::Filter::Stackable->new();
  $self->{irc_filter} = POE::Filter::IRCD->new();
  $self->{ircd_filter}->push( POE::Filter::Line->new(), $self->{irc_filter} );
  return 1;
}

sub _spawn_listener {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $self->{listener} = POE::Wheel::SocketFactory->new(
	BindAddress  => 'localhost',
	BindPort     => $self->{bindport} || 0,
	SuccessEvent => '_listener_accept',
	FailureEvent => '_listener_failed',
	Reuse	     => 'yes',
  );

}

sub _listener_accept {
  my ($kernel,$self,$socket,$peeradr,$peerport,$wheel_id) = @_[KERNEL,OBJECT,ARG0 .. ARG3];

  my ($wheel) = POE::Wheel::ReadWrite->new(
	Handle => $socket,
	InputFilter => $self->{ircd_filter},
	OutputFilter => POE::Filter::Line->new(),
	InputEvent => '_client_input',
	ErrorEvent => '_client_error',
  );

  if ( $wheel ) {
	$self->{wheels}->{ $wheel->ID() }->{wheel} = $wheel;
	$self->{wheels}->{ $wheel->ID() }->{port} = $peerport;
	$self->{wheels}->{ $wheel->ID() }->{peer} = inet_ntoa( $peeradr );
	$self->{wheels}->{ $wheel->ID() }->{start} = time();
  }
  return 1;
}

sub _listener_failed {
  delete ( $_[OBJECT]->{listener} );
  return 1;
}

sub _client_input {
  my ($kernel,$self,$input,$wheel_id) = @_[KERNEL,OBJECT,ARG0,ARG1];

  SWITCH: {
    if ( $input->{command} eq 'QUIT' ) {
	delete ( $self->{wheels}->{ $wheel_id } );
	last SWITCH;
    }
    if ( $input->{command} eq 'NICK' and not $self->{wheels}->{ $wheel_id }->{reg} ) {
	$self->{wheels}->{ $wheel_id }->{register}++;
    }
    if ( $input->{command} eq 'USER' and not $self->{wheels}->{ $wheel_id }->{reg} ) {
	$self->{wheels}->{ $wheel_id }->{user} = $input->{params}->[0];
	$self->{wheels}->{ $wheel_id }->{register}++;
    }
    if ( ( not $self->{wheels}->{ $wheel_id }->{reg} ) and $self->{wheels}->{ $wheel_id }->{register} >= 2 ) {
	$self->{wheels}->{ $wheel_id }->{reg} = 1;
	my ($nickname) = $self->{irc}->nick_name();
	my ($fullnick) = $self->{irc}->nick_long_form( $nickname );
	$self->_send_to_client( $wheel_id, ':' . $self->{irc}->server_name() . " 001 $nickname :Welcome to the Internet Relay Network $fullnick" );
	foreach my $channel ( keys %{ $self->{irc}->channels() } ) {
	  $self->_send_to_client( $wheel_id, ":$fullnick JOIN $channel" );
	  $self->{irc}->yield( 'names' => $channel );
	  $self->{irc}->yield( 'topic' => $channel );
	}
	last SWITCH;
    }
    if ( not $self->{wheels}->{ $wheel_id }->{reg} ) {
	last SWITCH;
    }
    if ( $input->{command} eq 'NICK' or $input->{command} eq 'USER' ) {
	last SWITCH;
    }
    #if ( $input->{command} eq 'PING' and scalar @{ $input->{params} } < 2 ) {
    if ( $input->{command} eq 'PING' ) {
	$self->_send_to_client( $wheel_id, 'PONG ' . $input->{params}->[0] );
	last SWITCH;
    }
    #if ( $input->{command} eq 'PONG' and scalar @{ $input->{params} } < 2 and $input->{params}->[0] =~ /^[0-9]+$/ ) {
    if ( $input->{command} eq 'PONG' and $input->{params}->[0] =~ /^[0-9]+$/ ) {
	$self->{wheels}->{ $wheel_id }->{lag} = time() - $input->{params}->[0];
	last SWITCH;
    }
    #if ( $input->{command} eq 'JOIN' and $self->{irc}->is_channel_member( $input->{params}->[0], $self->{irc}->nick_name() ) ) {
#	last SWITCH;
    #}
    $self->{irc}->yield( lc ( $input->{command} ) => @{ $input->{params} } );
  }
}

sub _client_error {
  my ($self,$wheel_id) = @_[OBJECT,ARG3];

  delete ( $self->{wheels}->{ $wheel_id } );
  return 1;
}

sub _shutdown {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  delete ( $self->{listener} );
  delete ( $self->{wheels} );
  return 1;
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

sub l_irc {
  my ($value) = shift || return undef;

  $value =~ tr/A-Z[]\\/a-z{}|/;
  return $value;
}

sub timestring {
      my ($timeval) = shift || return undef;
      my $uptime = time() - $timeval;

      my $days = int $uptime / 86400;
      my $remain = $uptime % 86400;
      my $hours = int $remain / 3600;
      $remain %= 3600;
      my $mins = int $remain / 60;
      $remain %= 60;

      my $string = "";
      if ($days > 0) {
        $string .= "$days day(s) ";
      }
      if ($hours > 0) {
        $string .= "$hours hour(s) ";
      }
      if ($mins > 0) {
        $string .= "$mins minute(s) ";
      }
      if ($remain > 0) {
        $string .= "$remain second(s)";
      }
      if ($string ne "") {
        return $string;
      }
      return undef;
}

1;
