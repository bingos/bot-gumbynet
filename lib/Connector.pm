package Connector;

use POE;
use POE::Component::IRC::Plugin qw( :ALL );

sub new {
  my ($package) = shift;

  my $self = bless { @_ }, $package;

  $self->{SESSION_ID} = POE::Session->create(
	object_states => [
	  $self => [ qw(_start _auto_ping _reconnect _shutdown _start_ping _stop_ping) ],
	],
	options => { trace => 0 },
  )->ID();
  return $self;
}

sub PCI_register {
  my ($self,$irc) = splice @_, 0, 2;

  $self->{irc} = $irc;

  if ( $irc->connected() ) {
    $poe_kernel->post( $self->{SESSION_ID}, '_start_ping' );
  }

  $irc->plugin_register( $self, 'SERVER', qw(all) );

  return 1;
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

  $poe_kernel->post( $self->{SESSION_ID}, '_start_ping' );
  return PCI_EAT_NONE;
}

sub S_disconnected {
  my ($self,$irc) = splice @_, 0, 2;

  $poe_kernel->post( $self->{SESSION_ID}, '_stop_ping' );
  $poe_kernel->post( $self->{SESSION_ID}, '_reconnect' );
  return PCI_EAT_NONE;
}

sub S_error {
  my ($self,$irc) = splice @_, 0, 2;

  $poe_kernel->post( $self->{SESSION_ID}, '_stop_ping' );
  $poe_kernel->post( $self->{SESSION_ID}, '_reconnect' );
  return PCI_EAT_NONE;
}

sub S_socketerr {
  my ($self,$irc) = splice @_, 0, 2;

  $poe_kernel->post( $self->{SESSION_ID}, '_stop_ping' );
  $poe_kernel->post( $self->{SESSION_ID}, '_reconnect' );
  return PCI_EAT_NONE;
}

sub S_pong {
  my ($self,$irc) = splice @_, 0, 2;
  my ($reply) = ${ $_[0] };

  if ( $reply and $reply =~ /^[0-9]+$/ ) {
	$self->{lag} = time() - $reply;
  }
  return PCI_EAT_NONE;
}

sub _default {
  my ($self,$irc) = splice @_, 0, 2;
  $self->{seen_traffic} = 1;
  return PCI_EAT_NONE;
}

sub lag {
  return $_[0]->{lag};
}

sub _start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $self->{SESSION_ID} = $_[SESSION]->ID();

  $kernel->refcount_increment( $self->{SESSION_ID}, __PACKAGE__ );
}

sub _start_ping {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $kernel->delay( '_auto_ping' => $self->{delay} || 300 );
}

sub _auto_ping {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  if ( not $self->{seen_traffic} ) {
     $self->{irc}->yield( 'ping' => time() );
  }
  $self->{seen_traffic} = 0;
  $kernel->yield( '_start_ping' );
}

sub _stop_ping {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $kernel->delay( '_auto_ping' => undef );
}

sub _shutdown {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $kernel->yield( '_stop_ping' );
}

sub _reconnect {
  my ($kernel,$self,$session,$sender) = @_[KERNEL,OBJECT,SESSION,SENDER];

  if ( $sender eq $session ) {
	$self->{irc}->yield( 'connect' );
  } else {
	$kernel->delay( '_reconnect' => 60 );
  }
}

1;
