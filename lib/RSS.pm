package RSS;
use strict;
use warnings;
use POE;
use POE::Component::IRC::Plugin qw( PCI_EAT_NONE PCI_EAT_ALL);
our $VERSION = 0.01;

our $nick_rx = qr([a-z0-9^`{}_|\][a-z0-9^`{}_|\-]*)i;

sub new {
    my $class = shift;

	my $self = bless {
		feeds => [
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
				url => "http://slashdot.org/index.rss",
				name => "slashdot",
				delay => (60*60),
			},
		],
		channel => '#irc.pm',
	}, $class;

	POE::Session->create(
		object_states => [
			$self => [qw(
				_start
				handle_feed
			)],
		],
	);
	
	
	return $self;
}

sub _start {
	my ($heap,$kernel,$session, $self) = @_[HEAP,KERNEL,SESSION,OBJECT];
	
	$heap->{rssagg} = POE::Component::RSSAggregator->new(
		alias    => 'rssagg',
		debug    => 1,
		callback => $session->postback("handle_feed"),
		tmpdir   => '/tmp', # optional caching
	);
	
	$kernel->post('rssagg','add_feed',$_) for @{$self->{feeds}};
}

sub handle_feed {
  my ($kernel,$heap,$self,$feed) = (@_[KERNEL,HEAP,OBJECT], $_[ARG1]->[0]);
  
  my $irc = $self->{irc};
  return unless($irc);
  
  for my $headline ($feed->late_breaking_news) {
     # do stuff with the XML::RSS::Headline object
     SWITCH: {
       if ( $feed->name eq 'cpan-testers' ) {
	   		if ($headline->headline =~ /^CPAN UPLOAD: (.+?) /i ) {
    	         my (@upload) = split(/\//,$1);
	             my ($author) = $upload[$#upload-1];
            	 my ($module) = $upload[$#upload];
           	  $module =~ s/\.tar\.gz//;
           	  $irc->yield( ctcp => $self->{channel} => $g->("ACTION CPAN Upload: $module by $author") ) if ( $irc->connected() and $module =~ /^(POE-|Bot-)/i );
            	 last SWITCH;
			 } elsif ($headline->headline =~ /^(PASS|FAIL) POE-.*$/i ) {
	             $irc->yield( ctcp => $self->{channel} => $g->("ACTION CPAN Testers: " . $headline->headline) ) if ( $irc->connected() );
    	         last SWITCH;
			}
       }
       if ( $feed->name eq 'poe-commits' ) {
             $irc->yield( ctcp => $self->{channel} => $g->("ACTION POE Commit: " . $headline->headline) ) if ( $irc->connected() );
             last SWITCH;
       }
       $irc->yield( ctcp => $self->{channel} => $g->("ACTION ".$feed->name." : " . $headline->headline) ) if ( $irc->connected() );
     }
  }
  
}

sub PCI_register {
        my ($self, $irc) = @_;
        $self->{irc} = $irc;
        $irc->plugin_register($self, 'SERVER', qw(public) );
        return 1;
}

sub PCI_unregister {
        my ($self, $irc) = @_;
        delete $self->{irc};
        return 1;
}

sub S_public {
    my ($self,$irc,$nickstring,$channels,$message) = @_;
	($message, $channels) = ($$message, $$channels);
    my $channel = $channels->[0];
    my $from_nick = _nick_via_nickstring($$nickstring);
    $self->{nick} ||= $irc->nick_name;
    my ($command) = $message =~ m/^\s*\Q$self->{nick}\E[\:\,\;\.]?\s*(.*)$/i;
	print "public from $self->{nick} command: $command\n";
    return PCI_EAT_NONE unless $command;


	if ($command =~ m/rss_add/) {
		my $f;
		foreach my $b (qw( url name delay )) {
			if ($command =~ m/$b\[([^\]]+)\]/) {
				$f->{$b} = $1;
			} else {
			  	$irc->yield(privmsg => $channel => $from_nick.": missing $b\[<data>\]");
		   		return PCI_EAT_ALL;
			}
		}
		$poe_kernel->post('rssagg','add_feed',$f);
	 	$irc->yield(privmsg => $channel => $from_nick.': feed '.$f->{name}.' added with url '.$f->{url}.' delay '.$f->{delay});
   		return PCI_EAT_ALL;
	}

    return PCI_EAT_NONE;
}

# private

sub _nick_via_nickstring {
    my ($nickstring) = @_;
    return (split(/!/, $nickstring))[0];
}

1;
