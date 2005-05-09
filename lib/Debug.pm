package Debug;

use POE qw(Filter::Line Wheel::ReadWrite);
use POE::Component::IRC::Plugin qw( :ALL );
use IO::File;

sub new {
  my ($package) = shift;

  my ($self) = bless ( { @_ }, $package );

  POE::Session->create(
	object_states => [
		$self => [ qw(_default _error _flush _register _start _unregister) ],
	],
	options => { trace => 0 },
  );
  return $self,
}

sub PCI_register {
  my ($self,$irc) = splice @_, 0, 2;

  $self->{irc} = $irc;
  $irc->plugin_register( $self, 'SERVER', qw(001) );
  $poe_kernel->post( $self->{SESSION_ID} => '_register' );

  return 1;
}

sub PCI_unregister {
  my ($self,$irc) = splice @_, 0, 2;

  $poe_kernel->post( $self->{SESSION_ID} => '_unregister' );
  #$poe_kernel->refcount_decrement( $self->{SESSION_ID}, 'Plugin::Debug' );
  return 1;
}

sub S_001 {
   return PCI_EAT_NONE;
}

sub _start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $self->{SESSION_ID} = $_[SESSION]->ID();
  #$kernel->refcount_increment( $self->{SESSION_ID}, 'Plugin::Debug' );

  my ($filename) = $self->{file} || 'poco-irc.debug';

  my $handle = new IO::File ">> $filename" or die;

  $self->{wheel} = POE::Wheel::ReadWrite->new(
	Handle => $handle,
	Filter => POE::Filter::Line->new(),
	FlushedEvent => '_flush',
	ErrorEvent => '_error',
  );
}

sub _register {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $self->{irc}->yield( register => 'all' );
}

sub _unregister {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $self->{irc}->yield( unregister => 'all' );
  delete $self->{irc};
  $self->{shutdown} = 1;
}

sub _error {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  delete $self->{wheel};
  $kernel->yield( '_unregister' );
}

sub _flush {
  if ( $_[OBJECT]->{shutdown} ) {
	delete $_[OBJECT]->{wheel};
  }
  return 1;
}

sub _default {
  my ($self, $event, $args) = @_[OBJECT,ARG0 .. $#_];
  return 0 if ( $event eq 'irc_raw' );
  my (@output) = ( "$event: " );

  foreach my $arg ( @$args ) {
	if ( ref($arg) eq 'ARRAY' ) {
		push( @output, "[" . join(" ,", @$arg ) . "]" );
	} else {
		push ( @output, "'$arg'" );
	}
  }
  $self->{wheel}->put( join( ' ', @output ) ) unless ( $self->{shutdown} );
  return 0;
}

1;
