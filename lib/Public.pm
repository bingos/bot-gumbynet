package Public;

use POE::Component::IRC::Plugin qw( :ALL );
use Date::Format;
use LWP::UserAgent;
use XML::RSS;
use HTTP::Request::Common qw(GET);
use Time::Duration;

our $VERSION = '0.199';
our $MAXDATA = 498;

# REGEXES
our $punc_rx = qr([?.!]?);
our $messages = qr/^(version|uptime|time|stats|clock|slashdot|rootprompt|elreg|fmeat)$punc_rx\s*$/;

sub new {
  my ($package) = shift;
  my (%parms) = @_;

  $parms{connect} = time() unless $parms{connect};
  $parms{start} = time() unless $parms{start};

  return bless \%parms, $package;
}

##########################
# Plugin related methods #
##########################

sub PCI_register {
  my ($self,$irc) = @_;

  $self->{irc} = $irc;

  $irc->plugin_register( $self, 'SERVER', qw(public) );

  return 1;
}

sub PCI_unregister {
  my ($self,$irc) = @_;

  delete ( $self->{irc} );

  return 1;
}

sub S_public {
  my ($self,$irc) = splice @_, 0 , 2;
  my ($nick,$userhost) = ( split /!/, ${ $_[0] } )[0..1];
  my ($channel) = ${ $_[1] }->[0];
  my ($what) = ${ $_[2] };
  
  my ($mynick) = $irc->nick_name();
  my ($command) = $what =~ m/^\s*\Q$mynick\E[\:\,\;\.]?\s*(.*)$/i;
  return PCI_EAT_NONE unless $command;

  if ( my ($cmd) = $command =~ /$messages/i ) {
     $cmd = '_' . lc $cmd;
     $self->$cmd($channel,$nick);
     return PCI_EAT_PLUGIN;
  }

  return PCI_EAT_NONE;
}

sub _version {
  my ($self,$channel,$nick) = splice @_, 0, 3;
  my ($reply) = 'ACTION is running ';

  if ( $self->{botver} ) {
	$reply .= $self->{botver};
  } else {
	$reply .= join( '-', __PACKAGE__ , $VERSION );
	$reply = join( ' ', $reply, 'PoCo-IRC-' . $POE::Component::IRC::VERSION, 'PoE-' . $POE::VERSION );
  }
  $self->{irc}->yield( ctcp => $channel => $reply );
  return 1;
}

sub _uptime {
  my ($self,$channel,$nick) = splice @_, 0, 3;
  my ($ts) = timestring( $self->{connect} );
  $self->{irc}->yield( ctcp => $channel => "ACTION has been connected $ts" );
  $ts = timestring( $self->{start} );
  $self->{irc}->yield( ctcp => $channel => "ACTION has been running $ts" );
  return 1;
}

sub _stats {
  my ($self,$channel,$nick) = splice @_, 0, 3;
  my ($channels) = scalar keys %{ $self->{irc}->channels() };
  my ($nicks) = scalar $self->{irc}->nicks();

  $self->{irc}->yield( privmsg => $channel => "Monitoring $channels channels, with $nicks registered users." );
  return 1;
}

sub _time {
  my ($self,$channel,$nick) = splice @_, 0, 3;

  $self->{irc}->yield( privmsg => $channel => "$nick: the time is " . time2str( "%a %h %e %T %Y %Z", time() ) );
  return 1;
}

sub _clock {
  my ($self,$channel,$nick) = splice @_, 0, 3;
  my ($return) = get_headlines('http://rjbs.manxome.org/rss/clock.cgi');

  $MAXDATA = 498 - length( $channel ) - length( $nick );
  $self->{irc}->yield( privmsg => $channel => "$nick: $return" );
  return 1;
}

sub _slashdot {
  my ($self,$channel,$nick) = splice @_, 0, 3;
  my ($return) = get_headlines('http://slashdot.org/index.rss');

  $MAXDATA = 498 - length( $channel ) - length( $nick );
  $self->{irc}->yield( privmsg => $channel => "$nick: $return" );
  return 1;
}

sub _rootprompt {
  my ($self,$channel,$nick) = splice @_, 0, 3;
  my ($return) = get_headlines('http://rootprompt.org/rss/');

  $MAXDATA = 498 - length( $channel ) - length( $nick );
  $self->{irc}->yield( privmsg => $channel => "$nick: $return" );
  return 1;
}

sub _elreg {
  my ($self,$channel,$nick) = splice @_, 0, 3;
  my ($return) = get_headlines('http://www.theregister.co.uk/headlines.rss');

  $MAXDATA = 498 - length( $channel ) - length( $nick );
  $self->{irc}->yield( privmsg => $channel => "$nick: $return" );
  return 1;
}

sub _fmeat {
  my ($self,$channel,$nick) = splice @_, 0, 3;
  my ($return) = get_headlines('http://download.freshmeat.net/backend/fm-releases-global.xml');

  $MAXDATA = 498 - length( $channel ) - length( $nick );
  $self->{irc}->yield( privmsg => $channel => "$nick: $return" );
  return 1;
}

sub timestring {
      my ($timeval) = shift || return 0;
      return duration_exact( time() - $timeval );
}

sub u_irc {
  my ($value) = shift || return undef;

  $value =~ tr/a-z{}|/A-Z[]\\/;
  return $value;
}

sub get_headlines {
  my ($rdf_loc) = @_;

  if ($rdf_loc) {
    #&status("getting headlines from $rdf_loc");

    my $ua = new LWP::UserAgent;
    #if (my $proxy = main::getparam('httpproxy')) { $ua->proxy('http', $proxy) };
    $ua->timeout(10);

    my $request = new HTTP::Request ("GET", $rdf_loc);
    my $result = $ua->request ($request);

    if ($result->is_success) {
      my ($str);
      $str = $result->content;
      $rss = new XML::RSS;
      eval { $rss->parse($str); };
      if ($@) {
        return "that gave some error";
      } else {
        my $return;

        foreach my $item (@{$rss->{"items"}}) {
          $return .= $item->{"title"} . "; ";
          last if length($return) > $MAXDATA;
        }

        $return =~ s/; $//;

        return $return;
      }
    } else {
      return "error: $rdf_loc wasn't successful";
    }
  } else {
    return "error: no location stored for $where";
  }
}

1;
