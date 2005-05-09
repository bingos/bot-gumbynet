package BanKick;

use POE::Component::IRC::Plugin qw( :ALL );
our $VERSION = '0.01';

##################
# Plugin methods #
##################

sub new {
  my $self = bless { }, shift;

  foreach ( @_ ) {
	next unless ( /^#/ );
	$self->{CHANNELS}->{ u_irc ( $_ ) } = 1;
  }
  return $self;
}

sub PCI_register {
  my ($self,$irc) = splice @_, 0 , 2;

  $self->{irc} = $irc;
  $irc->plugin_register( $self, 'SERVER', qw(mode) );
  return 1;
}

sub PCI_unregister {
  my ($self,$irc) = splice @_, 0 , 2;

  delete $self->{irc};
  return 1;
}

sub S_mode {
  my ($self,$irc) = splice @_, 0 , 2;
  my ($channel) = ${ $_[1] };
  return unless ( $self->monitored($channel) );
  my ($nick,$userhost) = ( split /!/, ${ $_[0] } )[0..1];
  my ($mynick) = $irc->nick_name();
  return PCI_EAT_NONE if ( u_irc ( $nick ) eq u_irc ( $mynick ) );
  return PCI_EAT_NONE if ( u_irc ( $channel ) eq u_irc ( $mynick ) );
  my ($parsed_mode) = parse_mode_line( map { $$_ } @_[ 2 .. $#_ ] );

  while ( my $mode = shift ( @{ $parsed_mode->{modes} } ) ) {
    my $arg = shift ( @{ $parsed_mode->{args} } ) if ( $mode =~ /^(\+[hovklbIe]|-[hovbIe])/ );
    next if ( $mode ne '+b' );
    $self->_check_channel( $channel, $arg );
  }

  return PCI_EAT_NONE;
}

####################
# Ban/Kick Methods #
####################

sub _check_channel {
  my ($self,$channel,$mask) = @_;

  print STDERR "Checking channel $channel with $mask\n";
  foreach my $nick ( $self->{irc}->ban_mask( $channel, $mask ) ) {
	print STDERR "$nick\n";
	next if ( $self->{irc}->is_channel_operator( $channel, $nick ) );
	$self->{irc}->yield( kick => $channel => $nick => 'AutoKick[tm]' );
  }
  return 1;
}

sub monitored { 
  my ($self) = shift;
  my ($channel) = u_irc ( $_[0] ) || return 0;

  return 1 if ( $self->{CHANNELS}->{ $channel } );
  return 0;
}

sub channel {
  my ($self) = shift;

  foreach my $channel ( @_ ) {
	$channel = u_irc ( $channel );
	if ( $self->{CHANNELS}->{ $channel } ) {
	   delete $self->{CHANNELS}->{ $channel };
	} else {
	   $self->{CHANNELS}->{ $channel } = 1;
	}
  }
  return 1;
}

###########################
# Miscellaneous Functions #
###########################

sub u_irc {
  my ($value) = shift || return undef;

  $value =~ tr/a-z{}|/A-Z[]\\/;
  return $value;
}

sub parse_mode_line {
  my ($hashref) = { };

  my ($count) = 0;
  foreach my $arg ( @_ ) {
        if ( $arg =~ /^(\+|-)/ or $count == 0 ) {
           my ($action) = '+';
           foreach my $char ( split (//,$arg) ) {
                if ( $char eq '+' or $char eq '-' ) {
                   $action = $char;
                } else {
                   push ( @{ $hashref->{modes} }, $action . $char );
                }
           }
         } else {
                push ( @{ $hashref->{args} }, $arg );
         }
         $count++;
  }
  return $hashref;
}

1;
