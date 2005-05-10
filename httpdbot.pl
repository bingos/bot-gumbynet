#!/usr/local/bin/perl -w

use strict;
use Carp;
use POE qw(Component::IRC::State Component::EasyDBI);
use lib './lib';
use Connector;
use HTTPD;

my ($nickname) = 'GumbyNET';
my ($username) = 'httpdbot';
my ($server) = 'localhost';
my ($port) = 9091;
my ($channel) = '#PoE';

my ($irc) = POE::Component::IRC::State->spawn( );

POE::Component::EasyDBI->new(
        alias => 'dbi',
        dsn => 'DBI:mysql:PoEBoT:localhost',
        username => 'poebot',
        password => 'letmein',
);

POE::Session->create(
    inline_states => {
       _start           => \&init_session,
       #_default		=> \&handle_default,
    },
);

$poe_kernel->run();
exit 0;

sub init_session {
  my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];

  $irc->yield( register => 'all' );
  $irc->plugin_add( 'Connector', Connector->new() );
  $irc->plugin_add( 'HTTPD', HTTPD->new( botnick => $nickname, dbi => 'dbi', bindport => 9092 ) );
  warn "Starting connection to localhost:9090\n";
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
