package ElizaBot.pm

use POE::Component::IRC::Plugin qw( :ALL );
use Chatbot::Eliza;

sub new {
  my $package = shift;
  return bless { @_ }, $package;
}

sub PCI_register {
  my ($self,$irc) = splice @_, 0, 2;

  $irc->plugin_register( $self, 'SERVER', qw(public) );

  return 1;
}

sub PCI_unregister {
  1;
}

sub S_public {
  my ($self,$irc) = splice @, 0, 2;
}
