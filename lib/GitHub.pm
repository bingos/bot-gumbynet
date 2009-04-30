package HTTPD;

use strict;
use warnings;
use POE qw(Component::Server::SimpleHTTP);
use POE::Component::IRC::Plugin qw( :ALL );
use CGI::Simple;
use JSON::XS ();

sub new {
  my ($package) = shift;

  my $self = bless { @_ }, $package;

  $self->{SESSION_ID} = POE::Session->create(
	object_states => [
	  $self => [ qw(_start _http_handler) ],
	],
	options => { trace => 0 },
  )->ID();
  return $self;
}

sub PCI_register {
  my ($self,$irc) = splice @_, 0, 2;

  $self->{irc} = $irc;

  $irc->plugin_register( $self, 'SERVER', qw(all) );

  return 1;
}

sub PCI_unregister {
  my ($self,$irc) = splice @_, 0, 2;

  delete ( $self->{irc} );

  $poe_kernel->call( 'httpd' => 'SHUTDOWN' );
  $poe_kernel->refcount_decrement( $self->{SESSION_ID}, __PACKAGE__ );

  return 1;
}

sub _default {
  my ($self,$irc) = splice @_, 0, 2;
  $self->{seen_traffic} = 1;
  return PCI_EAT_NONE;
}

sub _start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $self->{SESSION_ID} = $_[SESSION]->ID();

  POE::Component::Server::SimpleHTTP->new(
	ALIAS => 'httpd',
#	ADDRESS => '192.168.1.252',
	PORT => $self->{bindport} || 0,
	HANDLERS => [
		{
			DIR => '.*',
			SESSION => $self->{SESSION_ID},
			EVENT => '_http_handler',
		},
	],
	HEADERS => { Server => 'GumbyNET/0.9' },
  );

  $kernel->refcount_increment( $self->{SESSION_ID}, __PACKAGE__ );
  undef;
}

sub _http_handler {
  my ($kernel, $self, $request, $response, $dirmatch ) = @_[ KERNEL, OBJECT, ARG0 .. ARG2 ];

  # Check for errors
  if ( ! defined $request ) {
    $kernel->call( 'httpd', 'DONE', $response );
    return;
  }

  my $p = CGI::Simple->new( $request->content );
  my $channel = $p->param('name');
  my $info    = JSON::XS->new->latin1->decode ( $p->param('payload') );
  for my $commit (@{ $info->{commits} || [] }) {
      $self->{irc}->yield( 'privmsg', '#IRC.pm', 
	"$channel: " . $commit->{author}{name} . ' ' . $info->{ref} );
      $self->{irc}->yield( 'privmsg', '#IRC.pm', 
	$commit->{message} );
      $self->{irc}->yield( 'privmsg', '#IRC.pm', 
	$commit->{url} );
  }
  return;
}

1;
