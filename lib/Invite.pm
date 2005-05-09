package Invite;

use POE::Component::IRC::Plugin qw( :ALL );

sub new {
  return bless { @_[1 .. $#_] }, $_[0];
}

sub PCI_register {
  my ($self,$irc) = splice @_, 0, 2;

  $self->{irc} = $irc;
  $irc->plugin_register( $self, 'SERVER', qw(invite) );
  return 1;
}

sub PCI_unregister {
  my ($self,$irc) = splice @_, 0, 2;

  delete $self->{irc};
  return 1;
}

sub S_invite {
  my ($self,$irc) = splice @_, 0, 2;
  my ($channel) = ${ $_[1] };

  $irc->yield( join => $channel ) if ( $self->_bot_owner($nick) );
  return PCI_EAT_PLUGIN;
}

sub _bot_owner {
  my ($self) = shift;
  my ($who) = $_[0] || return 0;
  my ($nick,$userhost);

  unless ( $self->{botowner} ) {
	return 0;
  }

  if ( $who =~ /!/ ) {
	($nick,$userhost) = ( split /!/, $who )[0..1];
  } else {
	($nick,$userhost) = ( split /!/, $self->{irc}->nick_long_form($who) )[0..1];
  }

  unless ( $nick and $userhost ) {
	return 0;
  }

  $who = l_irc ( $nick ) . '!' . l_irc ( $userhost );

  if ( $who eq l_irc ( $self->{botowner} ) ) {
	return 1;
  }

  print STDERR "$who not equal to " . l_irc ( $self->{botowner} ) . "\n";
  return 0;
}

sub l_irc {
  my ($value) = shift || return undef;

  $value =~ tr/A-Z[]\\~/a-z{}|^/;
  return $value;
}

1;
