package Shorten;

use strict;
use URI;
use POE::Component::IRC::Plugin qw(:ALL);
use POE qw(Component::WWW::Shorten);

sub new {
  my ($package) = shift;

  my $self = bless { @_ }, $package;

  $self->{shorten} = POE::Component::WWW::Shorten->spawn( options => { trace => 0 } );

  $self->{session_id} = POE::Session->create(
	object_states => [
		$self => [ qw(_start _shorten _shortened) ],
	],
	options => { trace => 0 },
  )->ID();

  return $self;
}

sub PCI_register {
  my ($self,$irc) = splice @_, 0, 2;
  $self->{irc} = $irc;
  $irc->plugin_register( $self => 'SERVER' => qw(public) );
  return 1;
}

sub PCI_unregister {
  my ($self,$irc) = splice @_, 0, 2;
  delete ( $self->{irc} );
  $self->{shorten}->shutdown();
  $poe_kernel->refcount_decrement( $self->{session_id} => __PACKAGE__ );
  return 1;
}

sub S_public {
  my ($self,$irc) = splice @_, 0, 2;
  my ($nick) = ( split /!/, ${ $_[0] } )[0];
  return PCI_EAT_NONE if ( $self->_ignored_nick( $nick ) );
  my ($channel) = ${ $_[1] }->[0];
  return PCI_EAT_NONE if ( $irc->is_channel_member( $channel, 'shorten' ) );
  my ($what) = ${ $_[2] };

  if ( my $url = ( $what =~ m!(http://.+?)(?=\s|$)! )[0] ) {
	my $uri = URI->new( $url );
	return PCI_EAT_NONE unless ( $uri );
	return PCI_EAT_NONE if ( $uri->host =~ /^xrl.us$/i );
	return PCI_EAT_NONE if ( ( $uri->path_query eq "" or $uri->path_query eq '/' ) and $uri->host < 21 );
	my ($pos) = index($what,'http://');
	if ( length ( $uri->opaque ) > 25 ) {
	   $poe_kernel->post( $self->{session_id} => _shorten => { url => $url, event => '_shortened', _nick => $nick, _channel => $channel } );
	}
  }
  return PCI_EAT_NONE;
}

sub _start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $self->{session_id} = $_[SESSION]->ID();
  $kernel->refcount_increment( $self->{session_id} => __PACKAGE__ );
  undef;
}

sub _shorten {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $self->{shorten}->shorten( $_[ARG0] );
  undef;
}

sub _shortened {
  my ($kernel,$self,$r) = @_[KERNEL,OBJECT,ARG0];

  if ( $r->{short} ) {
	$self->{irc}->yield( ctcp => $r->{_channel} => 'ACTION ' . $r->{_nick} . ( $r->{_nick} =~ /s$/i ? "'" : "'s" ) . " url is at " . $r->{short} );
  }
  undef;
}

sub _ignored_nick {
  my ($self) = shift;
  my ($nick) = shift || return;
  $nick = u_irc( $nick );

  unless ( $self->{ignored_nicks} ) {
	return;
  }

  foreach my $nickname ( @{ $self->{ignored_nicks} } ) {
	if ( u_irc( $nickname ) eq $nick ) {
		return 1;
	}
  }
  return 0;
}

sub u_irc {
  my ($value) = shift || return undef;

  $value =~ tr/a-z{}|/A-Z[]\\/;
  return $value;
}

1;
