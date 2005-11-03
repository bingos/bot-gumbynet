package PoEBot;

use strict;
use warnings;

use POE qw(Component::Client::NNTP);
use POE::Component::IRC::Plugin qw(:ALL);
use Date::Format;
use Mail::Internet;
use Data::Dumper;

sub new {
  my ($package) = shift;

  POE::Component::Client::NNTP->spawn ( 'NNTP-Client2', { NNTPServer => 'nntp.perl.org' } );

  my $self = bless { @_ }, $package;

  $self->{session_id} = POE::Session->create(
	object_states => [
		$self => { nntp_disconnected => '_disconnected',
			   nntp_socketerr    => '_disconnected',
		},
		$self => [ qw(_connect _handle_article _handle_dbi _handle_dbi_update _start nntp_200 nntp_211 nntp_221 poll shutdown) ],
	],
	options => { trace => 0 },
  )->ID();

  return $self;
}

sub PCI_register {
  my ($self,$irc) = splice @_, 0, 2;

  $self->{irc} = $irc;

  $irc->plugin_register( $self, 'SERVER', qw(msg bot_addressed) );
  return 1;
}

sub PCI_unregister {
  my ($self,$irc) = splice @_, 0, 2;

  delete ( $self->{irc} );
  $poe_kernel->call( $self->{session_id} => 'shutdown' );
  return 1;
}

sub S_bot_addressed {
  my ($self,$irc) = splice @_, 0, 2;
  my ($nick) = ( split /!/, ${ $_[0] } )[0];
  my ($channel) = ${ $_[1] }->[0];
  my ($what) = ${ $_[2] };

  my @cmdline = split /\s+/, $what;
  SWITCH: {
    unless ( $cmdline[0] ) {
        last SWITCH;
    }
    if ( lc ( $cmdline[0] ) =~ /^(uploads|passes|fails)$/ and lc ( $cmdline[1] ) eq 'off' ) {
	my ($action) = $1; $action =~ s/(s|es)$//;
        $poe_kernel->post( $self->{dbi} => do =>
          {
                sql => 'DELETE FROM CPANBot where BotNick = ? and Channel = ? and What = ?',
                session => $self->{session_id},
                event => '_dummy',
                placeholders => [ $self->{botnick}, $channel, $action ],
          }
        );
	$irc->yield( privmsg => $channel => 'Done.' );
        last SWITCH;
    }
    if ( lc ( $cmdline[0] ) =~ /^(uploads|passes|fails)$/ and $cmdline[1] ) {
	my ($action) = $1; $action =~ s/(s|es)$//;
        $poe_kernel->post( $self->{dbi} => do =>
          {
                sql => 'UPDATE CPANBot SET RExp = ? where BotNick = ? and Channel = ? and What = ?',
                session => $self->{session_id},
                event => '_handle_dbi_update',
                placeholders => [ $cmdline[1], $self->{botnick}, $channel, $action ],
          }
        );
	$irc->yield( privmsg => $channel => 'Done.' );
        last SWITCH;
    }
  }
  return PCI_EAT_NONE;
}

sub shutdown {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $kernel->refcount_decrement( $self->{session_id} => __PACKAGE__ );
  $kernel->call( 'NNTP-Client2' => 'shutdown' );
  $kernel->delay( poll => undef );
  $kernel->delay( _connect => undef );
  $self->{shutdown} = 1;
  undef;
}

sub _start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $self->{session_id} = $_[SESSION]->ID();
  $kernel->refcount_increment( $self->{session_id} => __PACKAGE__ );

  $kernel->post ( 'NNTP-Client2' => register => 'all' );
  $kernel->yield( '_connect' );
  undef;
}

sub _connect {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $kernel->post ( 'NNTP-Client2' => 'connect' );
  undef;
}

sub poll {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  foreach my $group ( @{ $self->{groups} } ) {
    $kernel->post ( 'NNTP-Client2' => group => $group );
  }
  undef;
}

sub nntp_200 {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $kernel->yield( 'poll' );
  undef;
}

sub nntp_211 {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my ($estimate,$first,$last,$group) = split( /\s+/, $_[ARG0] );

  if ( defined $self->{articles}->{ $group } ) {
	# Check for new articles
	if ( $estimate >= $self->{articles}->{ $group } ) {
	   for my $article ( $self->{articles}->{ $group } .. $estimate ) {
		$kernel->post ( 'NNTP-Client2' => head => $article );
	   }
	   $self->{articles}->{ $group } = $estimate + 1;
	}
  } else {
	$self->{articles}->{ $group } = $estimate + 1;
  }
  $kernel->delay( 'poll' => ( $self->{poll} || 60 ) );
  undef;
}

sub nntp_221 {
  my ($kernel,$self,$text) = @_[KERNEL,OBJECT,ARG0];

  my ($article) = Mail::Internet->new( $_[ARG1] );
  my ($from) = $article->head->get( 'From' );
  my ($subject) = $article->head->get( 'Subject' );
  my ($newsgroups) = $article->head->get( 'Newsgroups' );
  chomp($subject); chomp($from);
  chomp( $newsgroups );
  $newsgroups =~ s/^\"//;
  $newsgroups =~ s/\"$//;
  foreach my $ng ( split( /,/, $newsgroups ) ) {
	$kernel->yield( '_handle_article' => $ng => $subject => $from );
  }
  undef;
}

sub _disconnected {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $kernel->delay( poll => undef );
  $kernel->delay( _connect => 60 ) unless ( $self->{shutdown} );
  undef;
}

sub _handle_article {
  my ($kernel,$self,$group,$subject,$from) = @_[KERNEL,OBJECT,ARG0 .. ARG2];

  if ( $group eq 'perl.cpan.testers' ) {
	if ( $subject =~ /^CPAN Upload: (.+)$/i ) {
		my (@upload) = split(/\//,$1);
        	my ($author) = $upload[$#upload-1];
        	my ($module) = $upload[$#upload];
        	$module =~ s/\.tar\.gz//;
		$kernel->post( $self->{dbi} => arrayhash =>
		  {
			sql => 'SELECT * FROM CPANBot where BotNick = ? and What = ?',
			event => '_handle_dbi',
			placeholders => [ $self->{botnick}, 'upload' ],
			_module => $module,
			_response => "ACTION CPAN Upload: $module by $author",
		  },
		);
		
		return;
	}
        if ( $subject =~ /^(PASS|FAIL)\s+(.+)\s+/i ) {
		my ($result) = $1; my ($module) = $2;
		$kernel->post( $self->{dbi} => arrayhash =>
		  {
			sql => 'SELECT * FROM CPANBot where BotNick = ? and What = ?',
			event => '_handle_dbi',
			placeholders => [ $self->{botnick}, lc ( $result ) ],
			_module => $module,
			_response => "ACTION cpan.testers: $subject $from",
		  },
		);
		return;
  	}
  }
  if ( $group eq 'perl.poe' ) {
	$self->{irc}->yield( ctcp => '#PoE' => "ACTION perl.poe: $subject $from" );
	return;
  }
  undef;
}

sub _handle_dbi {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my ($result) = $_[ARG0]->{result};
  my ($error) = $_[ARG0]->{error};
  my ($action) = $_[ARG0]->{placeholders}->[1];
  my ($response) = $_[ARG0]->{_response};
  my ($module) = $_[ARG0]->{_module};

  if ( not defined ( $error ) ) {
	foreach my $row ( @{ $result } ) {
	  eval {
	    if ( $module =~ /$row->{RExp}/ ) {
		$self->{irc}->yield( ctcp => $row->{Channel} => $response );
	    }
	  };
	}
  } else {
	# blah
  }
  undef;
}

sub _handle_dbi_update {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my ($result) = $_[ARG0]->{result};
  my ($error) = $_[ARG0]->{error};
  my ($placeholders) = $_[ARG0]->{placeholders};

  if ( not defined ( $error ) ) {
	if ( $result == 0 ) {
	   $kernel->post( $self->{dbi} => insert => 
	     {
		sql => 'INSERT INTO CPANBot (RExp,BotNick,Channel,What) values (?,?,?,?)',
		event => '_dummy',
		session => $self->{session_id},
		placeholders => $placeholders,
	     },
	   );
	}
  } else {
	# blah
  }
  undef;
}

1;
