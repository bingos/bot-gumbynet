package Foo;

use strict;
use warnings;
use POE::Component::IRC::Plugin qw(:ALL);
use Data::Dumper;

sub new {
  my $package = shift;
  return bless { @_ }, $package;
}

sub PCI_register {
  my ($self,$irc) = splice @_, 0, 2;
  $irc->plugin_register( $self, 'SERVER', qw(nick) );
  return 1;
}

sub PCI_unregister {
  return 1;
}

sub S_nick {
  my ($self,$irc) = splice @_, 0, 2;
  open my $foo, ">>foo" or die;
  print $foo Dumper(@_);
  close($foo);
  return PCI_EAT_NONE;
}

1;
