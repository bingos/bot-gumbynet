package CPANBot;

use strict;
use warnings;

use POE qw(Component::Client::NNTP Component::WWW::Shorten);
use POE::Component::IRC::Plugin qw(:ALL);
use Date::Format;
#use Mail::Internet;
use Email::Simple;

sub new {
  my $package = shift;

  POE::Component::Client::NNTP->spawn ( 'NNTP-Client', { NNTPServer => 'nntp.perl.org' } );

  my $self = bless { @_ }, $package;

  $self->{shorten} = POE::Component::WWW::Shorten->spawn();

  return $self;
}

sub PCI_register {
  my ($self,$irc) = splice @_, 0, 2;

  $self->{irc} = $irc;

  $irc->plugin_register( $self, 'SERVER', qw(msg bot_addressed) );

  $self->{session_id} = POE::Session->create(
	object_states => [
		$self => { nntp_disconnected => '_disconnected',
			   nntp_socketerr    => '_disconnected',
		},
		$self => [ qw(_connect _handle_article _handle_dbi _handle_dbi_update _start nntp_200 nntp_211 nntp_220 poll shutdown _shortened) ],
	],
	options => { trace => 0 },
  )->ID();

  return 1;
}

sub PCI_unregister {
  my ($self,$irc) = splice @_, 0, 2;
  delete $self->{irc};
  $poe_kernel->call( $self->{session_id} => 'shutdown' );
  return 1;
}

sub S_bot_addressed {
  my ($self,$irc) = splice @_, 0, 2;
  my $nick = ( split /!/, ${ $_[0] } )[0];
  my $channel = ${ $_[1] }->[0];
  my $what = ${ $_[2] };

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
  $kernel->call( 'NNTP-Client' => 'shutdown' );
  $self->{shorten}->shutdown();
  $kernel->delay( poll => undef );
  $kernel->delay( _connect => undef );
  $self->{shutdown} = 1;
  undef;
}

sub _start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $self->{session_id} = $_[SESSION]->ID();
  $kernel->refcount_increment( $self->{session_id} => __PACKAGE__ );

  $kernel->post ( 'NNTP-Client' => register => 'all' );
  $kernel->yield( '_connect' );
  undef;
}

sub _connect {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $kernel->post ( 'NNTP-Client' => 'connect' );
  undef;
}

sub poll {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $kernel->post ( 'NNTP-Client' => group => $_ ) for @{ $self->{groups} };
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
		$kernel->post ( 'NNTP-Client' => article => $article );
	   }
	   $self->{articles}->{ $group } = $estimate + 1;
	}
  } 
  else {
	$self->{articles}->{ $group } = $estimate + 1;
  }
  $kernel->delay( 'poll' => ( $self->{poll} || 60 ) );
  undef;
}

sub nntp_220 {
  my ($kernel,$self,$text) = @_[KERNEL,OBJECT,ARG0];

#  my $article = Mail::Internet->new( $_[ARG1] );
#  my $from = $article->head->get( 'From' );
#  my $subject = $article->head->get( 'Subject' );
#  my $newsgroups = $article->head->get( 'Newsgroups' );
#  my $xref = $article->head->get( 'Xref' );
#  chomp($subject); chomp($from); chomp($xref);
#  chomp( $newsgroups );
  my $article = Email::Simple->new( join "\n", @{ $_[ARG1] } );
  my $from = $article->header('From');
  my $subject = $article->header('Subject');
  my $xref = $article->header('Xref');
  my $newsgroups = $article->header('Newsgroups');
  my $body = $article->body();
  $newsgroups =~ s/^\"//;
  $newsgroups =~ s/\"$//;
  $kernel->yield( '_handle_article' => $_ => $subject => $from => $xref => $body ) for split /,/, $newsgroups;
  undef;
}

sub _disconnected {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $kernel->delay( poll => undef );
  $kernel->delay( _connect => 60 ) unless ( $self->{shutdown} );
  undef;
}

sub _handle_article {
  my ($kernel,$self,$group,$subject,$from,$xref,$body) = @_[KERNEL,OBJECT,ARG0 .. ARG4];

  if ( $group eq 'perl.cpan.testers' ) {
	if ( my ($author,$module) = $subject =~ m!^CPAN Upload: \w+/\w+/(\w+)/(.+)(\.tar\.gz|\.tgz|\.zip)$!i ) {
		$kernel->post( $self->{dbi} => arrayhash =>
		  {
			sql => 'SELECT * FROM CPANBot where BotNick = ? and What = ?',
			event => '_handle_dbi',
			placeholders => [ $self->{botnick}, 'upload' ],
			_module => $module,
			_response => "ACTION CPAN Upload: $module by $author",
			_xref => $xref,
		  },
		);
		
		return;
	}
	my ($result,$module,$platform,$osver) = split /\s/, $subject;
        if ( $result =~ /^(PASS|FAIL|UNKNOWN|NA)$/i ) {
		my $msg_id = ( split /:/, $xref )[1];
		my $perl_version = _extract_perl_version(\$body) || '0.0.0';
		$kernel->post( $self->{dbi} => arrayhash =>
		  {
			sql => 'SELECT * FROM CPANBot where BotNick = ? and What = ?',
			event => '_handle_dbi',
			placeholders => [ $self->{botnick}, lc ( $result ) ],
			_module => $module,
			_response => "ACTION cpan.testers: $result $module $platform $osver perl-$perl_version $from #$msg_id",
			_xref => $xref,
		  },
		);
		return;
  	}
  }
  if ( $group eq 'perl.poe' ) {
	$self->{irc}->yield( ctcp => '#PoE' => "ACTION perl.poe: \'$subject\' $from" );
	return;
  }
  undef;
}

sub _handle_dbi {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my $result = $_[ARG0]->{result};
  my $error = $_[ARG0]->{error};
  my $action = $_[ARG0]->{placeholders}->[1];
  my $response = $_[ARG0]->{_response};
  my $module = $_[ARG0]->{_module};
  my $xref = $_[ARG0]->{_xref};

  unless ( defined $error ) {
	foreach my $row ( @{ $result } ) {
	  eval {
	    if ( $module =~ /$row->{RExp}/ ) {
		$self->{irc}->yield( ctcp => $row->{Channel} => $response );
	    }
	  };
	}
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

sub _shortened {
  my ($kernel,$self,$result) = @_[KERNEL,OBJECT,ARG0];
  my $short = '';

  $short = $result->{short} if $result->{short} =~ m#^http://#i;
  $self->{irc}->yield( ctcp => $result->{_channel} => $result->{_response} => $short );
  undef;
}

sub _extract_perl_version {
  my $body = shift;

  # Summary of my perl5 (revision 5.0 version 6 subversion 1) configuration:
  my ($rev, $ver, $sub, $extra) = 
	  $$body =~ /Summary of my (?:perl\d+)? \((?:revision )?(\d+(?:\.\d+)?) (?:version|patchlevel) (\d+) subversion\s+(\d+) ?(.*?)\) configuration/s;
  
  return unless defined $rev;

  my $perl = $rev + ($ver / 1000) + ($sub / 1000000);
  $rev = int($perl);
  $ver = int(($perl*1000)%1000);
  $sub = int(($perl*1000000)%1000);

  my $version = sprintf "%d.%d.%d", $rev, $ver, $sub;
  $version .= " $extra" if $extra;
  return $version;
}

1;
