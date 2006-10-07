package CoreList;

use POE;
use Module::CoreList;
use POE::Component::IRC::Plugin qw( :ALL );

sub new {
    my $package = shift;
    return bless {@_}, $package;
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
  return PCI_EAT_NONE unless ( $command and $command =~ /^core\s+/i );

  my ($query,$type) = ( split /\s+/, $command )[1..2];
  $type = 'A' unless ( $type and $type =~ /^(A|MX|PTR|TXT|AAAA|SRV)$/i );

  if ( my $response = Module::CoreList->first_release($query) ) {
	$irc->yield( privmsg => $channel => "$nick: $response" );
  } else {
	$irc->yield( privmsg => $channel => "$nick: Nope" );
  }

  return PCI_EAT_NONE;
}

1;
