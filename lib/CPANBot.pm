package CPANBot;

use strict;
use warnings;

use POE qw(Component::Client::NNTP);
use POE::Component::IRC::Plugin qw(:ALL);
use Date::Format;
use Mail::Internet;


sub new {
  my ($package) = shift;

  POE::Component::Client::NNTP->spawn ( 'NNTP-Client', { NNTPServer => 'nntp.perl.org' } );

  my $self = bless { }, $package;

  $self->{session_id} = POE::Session->create(
	object_states => [
		$self => { nntp_disconnected => '_disconnected',
			   nntp_socketerr    => '_disconnected',
		},
		$self => [ qw(_start _default nntp_200 nntp_211 nntp_221 poll shutdown) ],
	],
	options => { trace => 1 },
  )->ID();

  return $self;
}

sub PCI_register {
  my ($self,$irc) = splice @_, 0, 2;

  $self->{irc} = $irc;

  $irc->plugin_register( $self, 'SERVER', qw(msg) );
  return 1;
}

sub PCI_unregister {
  my ($self,$irc) = splice @_, 0, 2;

  delete ( $self->{irc} );
  $poe_kernel->post( $self->{session_id} => 'shutdown' );
  return 1;
}

sub shutdown {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $kernel->refcount_decrement( $self->{session_id} => __PACKAGE__ );
  $self->{shutdown} = 1;
  undef;
}

sub _start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $self->{session_id} = $_[SESSION]->ID();
  $kernel->refcount_increment( $self->{session_id} => __PACKAGE__ );

  $kernel->post ( 'NNTP-Client' => register => 'all' );
  $kernel->post ( 'NNTP-Client' => 'connect' );
  undef;
}

sub poll {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $kernel->post ( 'NNTP-Client' => group => 'perl.cpan.testers' );
}

sub nntp_200 {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $kernel->post ( 'NNTP-Client' => group => 'perl.cpan.testers' );
  undef;
}

sub nntp_211 {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my ($estimate,$first,$last,$group) = split( /\s+/, $_[ARG0] );

  if ( defined $self->{articles} ) {
	# Check for new articles
	if ( $estimate >= $self->{articles} ) {
	   for my $article ( $self->{articles} .. $estimate ) {
		$kernel->post ( 'NNTP-Client' => head => $article );
	   }
	   $self->{articles} = $estimate + 1;
	}
  } else {
	$self->{articles} = $estimate + 1;
  }
  $kernel->delay( 'poll' => 60 );
  undef;
}

sub nntp_221 {
  my ($kernel,$self,$text) = @_[KERNEL,OBJECT,ARG0];

  my ($article) = Mail::Internet->new( $_[ARG1] );
  my ($from) = $article->head->get( 'From' );
  my ($subject) = $article->head->get( 'Subject' );
  chomp($subject); chomp($from);
  if ( $subject =~ /^CPAN Upload: (.+)$/i ) {
	my (@upload) = split(/\//,$1);
	my ($author) = $upload[$#upload-1];
	my ($module) = $upload[$#upload];
	$module =~ s/\.tar\.gz//;
	$self->{irc}->yield( ctcp => '#IRC.pm' => "ACTION CPAN Upload: $module by $author" ) if ( $module =~ /^(POE-)/i );
  }
  undef;
}

sub _disconnected {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $kernel->delay( poll => undef );
  $kernel->delay( _connect => 60 ) unless ( $self->{shutdown} );
  undef;
}

1;
