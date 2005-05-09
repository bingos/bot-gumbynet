package CTCP;

use POE::Component::IRC::Plugin qw( :ALL );
use Date::Format;
use vars qw($VERSION);

$VERSION = '1.0';

sub new {
  return bless ( { @_[1 .. $#_] }, $_[0] );
}

sub PCI_register {
  my ($self,$irc) = splice @_, 0, 2;

  $self->{irc} = $irc;
  $irc->plugin_register( $self, 'SERVER', qw(ctcp_version ctcp_userinfo ctcp_time) );

  return 1;
}

sub PCI_unregister {
  delete ( $_[0]->{irc} );
  return 1;
}

sub S_ctcp_version {
  my ($self,$irc) = splice @_, 0, 2;
  my ($nick) = ( split /!/, ${ $_[0] } )[0];
  
  $irc->yield( ctcpreply => $nick => 'VERSION ' . ( $self->{botver} ? $self->{botver} : 'BingosBOT-' . ref($self) . '-' . $VERSION ) );
  return PCI_EAT_CLIENT;
}

sub S_ctcp_time {
  my ($self,$irc) = splice @_, 0, 2;
  my ($nick) = ( split /!/, ${ $_[0] } )[0];
  
  $irc->yield( ctcpreply => $nick => 'TIME ' . time2str( "%a %h %e %T %Y %Z", time() ) );
  return PCI_EAT_CLIENT;
}

sub S_ctcp_userinfo {
  my ($self,$irc) = splice @_, 0, 2;
  my ($nick) = ( split /!/, ${ $_[0] } )[0];

  $irc->yield( ctcpreply => $nick => 'USERINFO ' . ( $self->{info} ? $self->{info} : 'm33p' ) );
  return PCI_EAT_CLIENT;
}
