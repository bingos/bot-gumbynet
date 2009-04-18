package Acronym;

use POE;
use Acme::POE::Acronym::Generator;
use POE::Component::IRC::Plugin qw( :ALL );

sub new {
    my $package = shift;
    my $poegen = Acme::POE::Acronym::Generator->new();
    return bless { poegen => $poegen, @_ }, $package;
}

sub PCI_register {
    my ( $self, $irc ) = splice @_, 0, 2;
    $irc->plugin_register( $self, 'SERVER', qw(public) );
    return 1;
}

sub PCI_unregister {
    return 1;
}

sub S_public {
  my ($self,$irc) = splice @_, 0 , 2;
  my ($nick,$userhost) = ( split /!/, ${ $_[0] } )[0..1];
  my $channel = ${ $_[1] }->[0];
  my $what = ${ $_[2] };

  my $mynick = $irc->nick_name();
  my ($command) = $what =~ m/^\s*\Q$mynick\E[\:\,\;\.]?\s*(.*)$/i;
  return PCI_EAT_NONE unless ( $command and $command =~ /^poe it\s*/i );

  my $poeit = $self->{poegen}->generate();
  $irc->yield( privmsg => $channel => "$nick: $poeit" );

  return PCI_EAT_NONE;
}

1;
