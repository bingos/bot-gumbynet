package DNS;

use POE;
use POE::Component::Client::DNS;
use POE::Component::IRC::Plugin qw( :ALL );

sub new {
    my ($package) = shift;

    my $self = bless {@_}, $package;

    POE::Session->create(
        object_states => [
            $self => [qw(_start _query _response)],
        ],
	options => { trace => 0 },
    );

    return $self;
}

sub PCI_register {
    my ( $self, $irc ) = splice @_, 0, 2;

    $self->{irc} = $irc;
    $irc->plugin_register( $self, 'SERVER', qw(public) );
    return 1;
}

sub PCI_unregister {
    my ( $self, $irc ) = splice @_, 0, 2;

    delete $self->{irc};

    # Plugin is dying make sure our POE session does as well.
    $poe_kernel->refcount_decrement( $self->{SESSION_ID}, 'Plugins::' . __PACKAGE__ );
    $self->{resolver}->shutdown();
    delete $self->{resolver};
    return 1;
}

sub S_public {
  my ($self,$irc) = splice @_, 0 , 2;
  my ($nick,$userhost) = ( split /!/, ${ $_[0] } )[0..1];
  my ($channel) = ${ $_[1] }->[0];
  my ($what) = ${ $_[2] };

  my ($mynick) = $irc->nick_name();
  my ($command) = $what =~ m/^\s*\Q$mynick\E[\:\,\;\.]?\s*(.*)$/i;
  return PCI_EAT_NONE unless ( $command and $command =~ /^dns\s+/i );

  my ($query,$type) = ( split /\s+/, $command )[1..2];

  $type = 'A' unless ( $type and $type =~ /^(A|MX|PTR|TXT|AAAA|SRV)$/i );

  if ( $query =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/ ) {
	$type = 'PTR';
  }

  $poe_kernel->post( $self->{SESSION_ID} => _query => $nick => $channel => $query => $type );
  return PCI_EAT_NONE;
}

sub _start {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];

    $self->{SESSION_ID} = $_[SESSION]->ID();

    # Make sure our POE session stays around. Could use aliases but that is so messy :)
    $kernel->refcount_increment( $self->{SESSION_ID}, 'Plugins::' . __PACKAGE__ );

    $self->{resolver} = POE::Component::Client::DNS->spawn( Alias => 'resolver' . $self->{SESSION_ID} );
}

sub _query {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    my ($nick,$channel,$query,$type) = @_[ARG0 .. ARG3];

    my ($response) = $self->{resolver}->resolve(
	event => '_response',
	host => $query,
	type => $type,
	context => { nick => $nick, channel => $channel },
    );
    if ( $response ) {
	$kernel->yield( _response => $response );
    }
}

sub _response {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    my $response = $_[ARG0];
    my ($nick) = $response->{context}->{nick};
    my ($channel) = $response->{context}->{channel};

    if ( not $response->{response} ) {
	$self->{irc}->yield( privmsg => $channel => "$nick: Thanks that generated an error" );
    } else {
	my (@answers);
	foreach my $answer ( $response->{response}->answer() ) {
		push( @answers, $answer->rdatastr() );
	}
	if ( @answers ) {
	  $self->{irc}->yield( privmsg => $channel => "$nick: " . $response->{host} . " is " . join(', ', @answers) );
	} else {
	  $self->{irc}->yield( privmsg => $channel => "$nick: I can\'t find machine name \"$response->{host}\"." );
	}
    }
}

1;
