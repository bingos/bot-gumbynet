#!/usr/local/bin/perl -w

use strict;
use Carp;
use POE qw(Component::IRC::State Component::RSSAggregator);
use lib './lib';
use Connector;

my @feeds = (
   {
     url   => "http://www.nntp.perl.org/rss/perl.cpan.testers.rdf",
     name  => "cpan-testers",
     delay => 60,
   },
   {
     url   => "http://cia.navi.cx/stats/project/poe/.rss",
     name  => "poe-commits",
     delay => 500,
    },
    {
     url   => "http://www.nntp.perl.org/rss/perl.poe.rdf",
     name  => "poe-list",
     delay => 300,
    },
);

my ($nickname) = 'GumbyNET';
my ($username) = 'poebot';
my ($server) = 'localhost';
my ($port) = 9091;
my ($channel) = '#PoE';

my ($irc) = POE::Component::IRC::State->spawn( );

POE::Session->create(
    inline_states => {
       _start           => \&init_session,
       _default		=> \&handle_default,
    },
    package_states => [
	'main' => [ qw(handle_feed) ],
        ],
);

$poe_kernel->run();
exit 0;

sub init_session {
  my ($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];
  warn "Starting RSSAggregator\n";
  $heap->{rssagg} = POE::Component::RSSAggregator->new(
                   alias    => 'rssagg',
                   debug    => 1,
                   callback => $session->postback("handle_feed"),
                   tmpdir   => '/tmp', # optional caching
  );
               $kernel->post('rssagg','add_feed',$_) for @feeds;

  $irc->yield( register => 'all' );
  $irc->plugin_add( 'Connector', Connector->new() );
  warn "Starting connection to localhost:9090\n";
  $irc->yield( connect => { Nick => $nickname, Server => $server, Port => $port, Username => $username } );
}

sub handle_feed {
  my ($kernel,$feed) = ($_[KERNEL], $_[ARG1]->[0]);
  my ($heap) = $_[HEAP];
  for my $headline ($feed->late_breaking_news) {
     # do stuff with the XML::RSS::Headline object
     SWITCH: {
       if ( $feed->name eq 'cpan-testers' and $headline->headline =~ /^CPAN UPLOAD: (.+?) /i ) {
	     my (@upload) = split(/\//,$1);
	     my ($author) = $upload[$#upload-1];
	     my ($module) = $upload[$#upload];
	     $module =~ s/\.tar\.gz//;
	     $irc->yield( ctcp => $channel => "ACTION CPAN Upload: $module by $author" ) if ( $irc->connected() and $module =~ /^(Bot-|ThreatNET-)/i );
	     $irc->yield( ctcp => $channel => "ACTION CPAN Upload: $module by $author" ) if ( $irc->connected() and $module =~ /^(POE-)/i and not $irc->is_channel_member('#PoE','CPAN') );
	     last SWITCH;
       }
       if ( $feed->name eq 'cpan-testers' and $headline->headline =~ /^FAIL POE-.*$/i ) {
	     $irc->yield( ctcp => $channel => "ACTION CPAN Testers: " . $headline->headline) if ( $irc->connected() );
	     last SWITCH;
       }
       if ( $feed->name eq 'poe-commits' ) {
	     my ($committer) = '?';
	     if ( $headline->description =~ /Commit by <strong>(.+?)<\/strong>/i ) {
		$committer = $1;
	     }
	     $irc->yield( ctcp => $channel => "ACTION POE Commit : '" . $headline->headline . "' by $committer" ) if ( $irc->connected() );
	     last SWITCH;
       }
       if ( $feed->name eq 'poe-list' ) {
	     $irc->yield( ctcp => $channel => "ACTION POE List: " . $headline->headline) if ( $irc->connected() );
	     last SWITCH;
       }
     }
  }
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
