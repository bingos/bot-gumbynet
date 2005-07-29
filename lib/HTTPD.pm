package HTTPD;

use POE qw(Component::Server::SimpleHTTP);
use POE::Component::IRC::Plugin qw( :ALL );
use CGI qw(:standard);
use Date::Format;

sub new {
  my ($package) = shift;

  my $self = bless { @_ }, $package;

  $self->{SESSION_ID} = POE::Session->create(
	object_states => [
	  $self => [ qw(_start _dbi_handler _http_handler _http_root _http_404) ],
	],
	options => { trace => 0 },
  )->ID();
  return $self;
}

sub PCI_register {
  my ($self,$irc) = splice @_, 0, 2;

  $self->{irc} = $irc;

  $irc->plugin_register( $self, 'SERVER', qw(all) );

  return 1;
}

sub PCI_unregister {
  my ($self,$irc) = splice @_, 0, 2;

  delete ( $self->{irc} );

  $poe_kernel->call( 'httpd' => 'SHUTDOWN' );
  $poe_kernel->refcount_decrement( $self->{SESSION_ID}, __PACKAGE__ );

  return 1;
}

sub _default {
  my ($self,$irc) = splice @_, 0, 2;
  $self->{seen_traffic} = 1;
  return PCI_EAT_NONE;
}

sub _start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $self->{SESSION_ID} = $_[SESSION]->ID();

  POE::Component::Server::SimpleHTTP->new(
	ALIAS => 'httpd',
	ADDRESS => '192.168.1.252',
	PORT => $self->{bindport} || 0,
	HANDLERS => [
		{ 
			DIR => '^/$',
			SESSION => $self->{SESSION_ID},
			EVENT => '_http_root',
		},
		{	DIR => '^/channel$',
			SESSION => $self->{SESSION_ID},
			EVENT => '_http_handler',
		},
		{
			DIR => '.*',
			SESSION => $self->{SESSION_ID},
			EVENT => '_http_404',
		},
	],
	HEADERS => { Server => 'GumbyNET/0.9' },
  );

  $kernel->refcount_increment( $self->{SESSION_ID}, __PACKAGE__ );
  undef;
}

sub _http_404 {
  my ($kernel, $self, $request, $response, $dirmatch ) = @_[ KERNEL, OBJECT, ARG0 .. ARG2 ];

  # Check for errors
  if ( ! defined $request ) {
    $kernel->call( 'httpd', 'DONE', $response );
    return;
  }

  # Do our stuff to HTTP::Response
  $response->code( 404 );
  $response->content( "Hi visitor from " . $response->connection->remote_ip . ", Page not found -> '" . $request->uri->path . "'\n\n" );

  # We are done!
  # For speed, you could use $_[KERNEL]->call( ... )
  $kernel->call( 'httpd', 'DONE', $response );

  print STDERR "Request from " . $response->connection->remote_ip . " " . $request->uri->path_query . "\n";
}

sub _http_root {
  my ($kernel, $self, $request, $response, $dirmatch ) = @_[ KERNEL, OBJECT, ARG0 .. ARG2 ];

  # Check for errors
  if ( ! defined $request ) {
    $kernel->call( 'httpd', 'DONE', $response );
    return;
  }

  my ($irc) = $self->{irc};

  # Do our stuff to HTTP::Response
  $response->code( 200 );
  my ($content);
  if ( $irc->connected() ) {
    $content = start_html("Blah Blah Blah") . h1( $irc->nick_name() ) . "\n";

    foreach my $channel ( keys %{ $irc->channels() } ) {
	my ($fixed) = $channel =~ /^#(.*)$/;
	$content .= "<table border=1><th><a href=\"/channel?$fixed\">" . $channel . '</a></th>' . "\n";
	my $server_count = { };
	foreach my $nick ( sort { lc($a) cmp lc($b) } $irc->channel_list( $channel ) ) {
	   if ( my $nickref = $irc->nick_info( $nick ) ) {
		$content .= '<tr><td>' . $nick . '</td><td>' . $nickref->{User} . '@' . $nickref->{Host} . '</td><td>';
		if ( $irc->is_channel_operator( $channel, $nick ) ) {
			$content .= '@';
		}
		if ( $irc->is_channel_halfop( $channel, $nick ) ) {
			$content .= '%';
		}
		if ( $irc->has_channel_voice( $channel, $nick ) ) {
			$content .= '+';
		}
		if ( $nickref->{IRCop} ) {
			$content .= '*';
		}
		$server_count->{ $nickref->{Server} }++;
		$content .= '</td><td>' . $nickref->{Server} . '</td><td>' . $nickref->{Real} . '</td></tr>';
	   }
	}
	my ($highest) = ( sort { $server_count->{$b} <=> $server_count->{$a} } keys %{ $server_count } )[0];
	if ( $highest ) {
		$content .= '<tr><td colspan="5">Highest server count: ' . $highest . '</td></tr>';
	}
	$content .= "</table>\n\n";
    }
    $content .= end_html();

  } else {
    $content = start_html('Blah Blah Blah') . "<p>The bot is not currently connected</p>" . end_html();
  }

  $response->content( $content );

  $kernel->call( 'httpd', 'DONE', $response );
  print STDERR "Request from " . $response->connection->remote_ip . " " . $request->uri->path_query . "\n";
}

sub _http_handler {
  my ($kernel, $self, $request, $response, $dirmatch ) = @_[ KERNEL, OBJECT, ARG0 .. ARG2 ];

  # Check for errors
  if ( ! defined $request ) {
    $kernel->call( 'httpd', 'DONE', $response );
    return;
  }

  my ($query) = $request->uri->query;

  unless ( $query ) {
    $response->code( 200 );
    $response->content( start_html('Error') . '<p>You must specify a channel to query</p>' . end_html() );
    $kernel->call( 'httpd', 'DONE', $response );
    return;
  }
  
  if ( $self->{dbi} ) {
	$kernel->post( $self->{dbi} => arrayhash => {
		sql => 'select TimeStamp,Entry from BotLogs where BotNick = ? and Channel = ? order by TimeStamp desc,UniqID desc limit 30',
		event => '_dbi_handler',
		placeholders => [ $self->{botnick}, '#' . $query ],
		_response => $response,
	} );
  }
  print STDERR "Request from " . $response->connection->remote_ip . " " . $request->uri->path_query . "\n";
}

sub _dbi_handler {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my ($result) = $_[ARG0]->{result};
  my ($error) = $_[ARG0]->{error};
  my ($response) = $_[ARG0]->{_response};

  if ( not defined ( $error ) ) {
	$response->code( 200 );
	my ($content) = start_html( $_[ARG0]->{placeholders}->[1] ) . '<table border=0>';
	foreach my $row ( reverse @{ $result } ) {
	  $row->{Entry} =~ s/>/&gt;/g;
	  $row->{Entry} =~ s/</&lt;/g;
	  $content .= '<tr><td>' . time2str( "[%c] ", $row->{TimeStamp} ) . $row->{Entry} . "</td></tr>\n";
	}
	$content .= '</table>' . end_html();
	$response->content( $content );
  } else {
	$response->code( 200 );
	$response->content( start_html('Error') . '<p>Something wicked happened</p>' . end_html() );
  }

  $kernel->call( 'httpd', 'DONE', $response );
}

1;
