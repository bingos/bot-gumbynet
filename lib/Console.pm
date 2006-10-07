package Console;

use POE qw(Wheel::SocketFactory Wheel::ReadWrite Filter::IRCD Filter::Line Filter::Stackable);
use POE::Component::IRC::Plugin qw( :ALL );
use Data::Dumper;

sub new {
  my ($package) = shift;

  my $self = bless { @_ }, $package;

  POE::Session->create(
	object_states => [
	  $self => [ qw(_client_error _client_input _listener_accept _listener_failed _start _shutdown) ],
	],
  );
  return $self;
}

sub PCI_register {
  my ($self,$irc) = splice @_, 0, 2;

  $self->{irc} = $irc;

  $irc->plugin_register( $self, 'SERVER', qw(all) );
  $irc->plugin_register( $self, 'USER', qw(all) );

  return 1;
}

sub PCI_unregister {
  my ($self,$irc) = splice @_, 0, 2;

  delete $self->{irc};

  $poe_kernel->post( $self->{SESSION_ID} => '_shutdown' );
  $poe_kernel->refcount_decrement( $self->{SESSION_ID}, __PACKAGE__ );

  return 1;
}

sub _default {
  my ($self,$irc) = splice @_, 0, 2;
  my $event = shift;
  return PCI_EAT_NONE if $event eq 'S_raw';
  pop @_ if ref $_[$#_] eq 'ARRAY';
  my @args = map { $$_ } @_;
  my @output = ( "$event: " );

  foreach my $arg ( @args ) {
        if ( ref($arg) eq 'ARRAY' ) {
                push( @output, "[" . join(" ,", @$arg ) . "]" );
        } else {
                push ( @output, "'$arg'" );
        }
  }

  foreach my $wheel_id ( keys %{ $self->{wheels} } ) {
	$self->{wheels}->{ $wheel_id }->put( join(' ', @output ) ) if ( defined ( $self->{wheels}->{ $wheel_id } ) );
  }

  return PCI_EAT_NONE;
}

sub _start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $self->{SESSION_ID} = $_[SESSION]->ID();
  $kernel->refcount_increment( $self->{SESSION_ID}, __PACKAGE__ );
  $self->{ircd_filter} = POE::Filter::Stackable->new();
  $self->{ircd_filter}->push( POE::Filter::Line->new(), POE::Filter::IRCD->new() );

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

  $self->{wheels}->{ $wheel->ID() } = $wheel;
  return 1;
}

sub _listener_failed {
  delete ( $_[OBJECT]->{listener} );
  return 1;
}

sub _client_input {
  my ($kernel,$self,$input,$wheel_id) = @_[KERNEL,OBJECT,ARG0,ARG1];

  $self->{irc}->yield( lc ( $input->{command} ) => @{ $input->{params} } );
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

1;
