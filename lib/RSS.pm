package RSS;
use strict;
use warnings;
use POE;
use POE::Component::RSSAggregator;
use POE::Component::IRC::Plugin qw( PCI_EAT_NONE PCI_EAT_ALL);
our $VERSION = 0.01;

sub new {
    my $class = shift;

	my $self = bless {
		feeds => [
			{
				url   => 'http://groups.google.com/group/cometd-dev/feed/rss_v2_0_msgs.xml?num=50',
				name  => "cometd-dev",
				delay => 1800,
			},
			{
				url   => 'http://groups.google.com/group/cometd-users/feed/rss_v2_0_msgs.xml?num=50',
				name  => "cometd-users",
				delay => 1800,
			},
		],
		channel => '#cometd',
	}, $class;

	
	return $self;
}

sub _start {
	my ($heap,$kernel,$session, $self) = @_[HEAP,KERNEL,SESSION,OBJECT];
	$self->{session_id} = $session->ID;
	$kernel->refcount_increment( $self->{session_id}, __PACKAGE__ );
	
	$self->{rssagg} = POE::Component::RSSAggregator->new(
		alias    => 'rssagg',
		debug    => 1,
		callback => $session->postback("handle_feed"),
		tmpdir   => '/tmp', # optional caching
	);
	
	$kernel->post('rssagg','add_feed',$_) for @{$self->{feeds}};
	undef;
}

sub handle_feed {
  my ($kernel,$heap,$self,$feed) = (@_[KERNEL,HEAP,OBJECT], $_[ARG1]->[0]);
  
  my $irc = $self->{irc};
  return unless($irc);
  
  for my $headline ($feed->late_breaking_news) {
     # do stuff with the XML::RSS::Headline object
     $irc->yield( ctcp => $self->{channel} => join ( ' ', 'ACTION', $feed->name, $headline->headline ) );
  }
  
  undef;
}

sub PCI_register {
        my ($self, $irc) = @_;
        $self->{irc} = $irc;
        $irc->plugin_register($self, 'SERVER', qw(public) );
	$self->{session_id} = POE::Session->create(
		object_states => [
			$self => [qw(_start handle_feed)],
		],
	)->ID();
        return 1;
}

sub PCI_unregister {
        my ($self, $irc) = @_;
        delete $self->{irc};
	$self->{rssagg}->shutdown;
	$poe_kernel->refcount_decrement( $self->{session_id}, __PACKAGE__ );
        return 1;
}

sub S_public {
    return PCI_EAT_NONE;
}

1;
