#!/opt/perl-5.10.1/bin/perl

use strict;
use warnings;
use Carp;
BEGIN { eval "use Event;"; }
use POE qw(Component::IRC Component::EasyDBI);
use lib './lib';
use Connector;
use GHFCGI;
use POE::Component::IRC::Plugin::BotAddressed;

my $nickname = 'GumbyNET3';
my $username = 'github';
my $server = '127.0.0.1';
my $httpd = 1028;
my $port = 9091;

POE::Component::EasyDBI->new(
        alias => 'dbi',
        dsn => 'dbi:SQLite:dbname=gumbynet.db',
        username => '',
        password => '',
);

my $irc = POE::Component::IRC->spawn( debug => 0, plugin_debug => 1 );

POE::Session->create(
    inline_states => {
       _start           => \&init_session,
       _default		=> \&handle_default,
    },
);

$poe_kernel->run();
exit 0;

sub init_session {
  my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];

  $irc->yield( register => 'all' );
  $irc->plugin_add( 'BotAddressed', POE::Component::IRC::Plugin::BotAddressed->new() );
  $irc->plugin_add( 'Connector', Connector->new() );
  $irc->plugin_add( 'GitHub', GHFCGI->new( bindport => $httpd, dbi => 'dbi' ) );
  warn "Starting connection to $server:$port\n";
  $irc->yield( connect => { Nick => $nickname, Server => $server, Port => $port, Username => $username } );
  undef;
}

sub handle_default {
    my ( $event, $args ) = @_[ ARG0 .. $#_ ];
    print "$event: ";

    return 0 if $event eq 'nntp_220';
    foreach (@$args) {
        if ( ref($_) eq 'ARRAY' ) {
            print "[", join ( ", ", @$_ ), "] ";
        }
        else {
            print "'$_' ";
        }
    }
    print "\n";
    return 0;    # Don't handle signals.
}
