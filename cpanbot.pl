#!/usr/local/bin/perl -w

use strict;
use Carp;
use POE qw(Component::IRC Component::EasyDBI);
use lib './lib';
use Connector;
use CPANBot;
use PoEBot;
use POE::Component::IRC::Plugin::BotAddressed;

my ($nickname) = 'GumbyNET';
my ($username) = 'cpanbot';
my ($server) = '127.0.0.1';
my ($port) = 9091;
my ($channel) = '#PoE';
my ($groups) = [ 'perl.cpan.testers', 'perl.poe' ];

POE::Component::EasyDBI->new(
        alias => 'dbi',
        dsn => 'DBI:mysql:PoEBoT:localhost',
        username => 'poebot',
        password => 'letmein',
);

my ($irc) = POE::Component::IRC->spawn( debug => 0 );

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
  $irc->plugin_add( 'CPANBot', CPANBot->new( botnick => $nickname, poll => 30, groups => [ $groups->[0] ], dbi => 'dbi' ) );
  $irc->plugin_add( 'PoEBot', PoEBot->new( botnick => $nickname, poll => 30, groups => [ $groups->[1] ], dbi => 'dbi' ) );
  warn "Starting connection to $server:$port\n";
  $irc->yield( connect => { Nick => $nickname, Server => $server, Port => $port, Username => $username } );
}

sub handle_default {
    my ( $event, $args ) = @_[ ARG0 .. $#_ ];
    print "$event: ";

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
