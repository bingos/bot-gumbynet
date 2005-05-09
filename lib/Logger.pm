package Logger;

use POE;
use POE::Component::IRC::Plugin qw( :ALL );
use strict;
use Time::HiRes qw( gettimeofday );
use Date::Format;

our $VERSION = '5.0';

sub new {
  my ($package) = shift;

  my (%params) = @_;

  # dbi == alias or session id
  # session == alias or session id

  return bless( \%params, $package );
}

sub PCI_register {
  my ($self, $irc) = @_;

  $irc->plugin_register( $self, 'SERVER', qw(join part topic mode kick nick quit public ctcp_action disconnect) );

  return 1;
}

sub PCI_unregister {
  my ($self, $irc) = @_;

  return 1;
}

sub S_join {
  my ($self,$irc) = splice @_, 0, 2;
  my ($nick,$userhost) = split /!/, ${ $_[0] };
  my ($channel) = ${ $_[1] };

  if ( $nick eq $irc->nick_name() ) {
	$self->_log_entry("*** Session start: " . time2str("%A %m %b %Y, %R", time() ) . " ***",$channel);
  }

  $self->_log_entry("*** $nick ($userhost) has joined $channel", $channel);

  return PCI_EAT_NONE;
}

sub S_part {
  my ($self,$irc) = splice @_, 0, 2;
  my ($nick,$userhost) = split /!/, ${ $_[0] };
  my ($channel) = ( split / :/, ${ $_[1] } )[0];

  $self->_log_entry("*** $nick ($userhost) has left channel $channel",$channel);

  if ( $nick eq $irc->nick_name() ) {
	$self->_log_entry("*** Session end: " . time2str("%A %m %b %Y, %R", time() ) . " ***",$channel);
  }

  return PCI_EAT_NONE;
}

sub S_topic {
  my ($self,$irc) = splice @_, 0, 2;
  my ($nick,$userhost) = split /!/, ${ $_[0] };
  my ($channel) = ${ $_[1] };
  my ($topic) = ${ $_[2] };

  $self->_log_entry("*** $nick changes topic to `$topic`",$channel);

  return PCI_EAT_NONE;
}

sub S_mode {
  my ($self,$irc) = splice @_, 0, 2;
  my ($nick,$userhost) = split /!/, ${ $_[0] };
  my ($channel) = ${ $_[1] };
  my ($mode) = join (' ', map { $$_ } @_[ 2 .. $#_ ] );

  $self->_log_entry("*** $nick set mode: $mode",$channel);

  return PCI_EAT_NONE;
}

sub S_kick {
  my ($self,$irc) = splice @_, 0, 2;
  my ($nick,$userhost) = split /!/, ${ $_[0] };
  my ($channel) = ${ $_[1] };
  my ($victim) = ${ $_[2] };
  my ($excuse) = ${ $_[3] };

  $self->_log_entry("*** $victim was kicked by $nick ($excuse)",$channel);

  if ( $victim eq $irc->nick_name() ) {
	$self->_log_entry("*** Session end: " . time2str("%A %m %b %Y, %R", time() ) . " ***",$channel);
  }

  return PCI_EAT_NONE;
}

sub S_nick {
  my ($self,$irc) = splice @_, 0, 2;
  my ($nick,$userhost) = split /!/, ${ $_[0] };
  my ($new) = ${ $_[1] };

  foreach my $channel ( @{ ${ $_[2] } } ) {
    $self->_log_entry("*** $nick is now known as $new",$channel);
  }

  return PCI_EAT_NONE;
}

sub S_quit {
  my ($self,$irc) = splice @_, 0, 2;
  my ($nick,$userhost) = split /!/, ${ $_[0] };
  my ($msg) = ${ $_[1] };

  foreach my $channel ( @{ ${ $_[2] } } ) {
    $self->_log_entry("*** $nick has quit IRC ($msg)",$channel);
  }

  return PCI_EAT_NONE;
}

sub S_public {
  my ($self,$irc) = splice @_, 0, 2;
  my ($nick,$userhost) = split /!/, ${ $_[0] };
  my ($channel) = ${ $_[1] }->[0];
  my ($what) = ${ $_[2] };

  $self->_log_entry("<$nick> $what",$channel);

  return PCI_EAT_NONE;
}

sub S_ctcp_action {
  my ($self,$irc) = splice @_, 0, 2;
  my ($nick,$userhost) = split /!/, ${ $_[0] };
  my ($channel) = ${ $_[1] }->[0];
  my ($what) = ${ $_[2] };

  $self->_log_entry("* $nick $what",$channel);

  return PCI_EAT_NONE;
}

sub S_disconnect {
  my ($self,$irc) = splice @_, 0, 2;

  foreach my $channel ( keys %{ $irc->channels() } ) {
	$self->_log_entry("*** Session end: " . time2str("%A %m %b %Y, %R", time() ) . " ***",$channel);
  }
  
  return PCI_EAT_NONE;
}

sub _log_entry {
  my ($self) = shift;
  my ($entry) = shift || return 0;
  my ($channel) = shift;

  my ($ts,$ms) = gettimeofday();
  my ($ui) = $ts + $ms;

  $poe_kernel->post( $self->{dbi} => insert => { 
	sql => "INSERT INTO BotLogs (TimeStamp,UniqID,BotNick,Channel,Entry) values (?,?,?,?,?)",
	placeholders => [ $ts, $ui, $self->{botnick}, $channel, $entry ],
	event => 'insert_log_entry',
	session => $self->{session},
  } );

  return 1;
}
