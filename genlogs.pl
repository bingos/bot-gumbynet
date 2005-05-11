#!/usr/bin/perl -w
#
# genlogs.pl
# Copyright (C) 2005 BingosNET Produktions Ltd
# Written by Kidney Bingos aka Chris Williams
# <chris@bingosnet.co.uk>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.


use Getopt::Long;
use DBI;
use Date::Format;

# Version information
my ($major) = "3";
my ($minor) = "02BETA2";
my ($usage) = "Usage: [perl] $0 [option]\n\n--nick <nickname>\n--config <configfile>\n--channel <channel>";

my ($nickname) = "";
my ($config) = "GumbyNET.cfg";
my ($channel) = "";
my ($dsn) = "";
my ($mysqluser) = "";
my ($mysqlpass) = "";

GetOptions("nick=s" => \$nickname,
	   "channel=s" => \$channel,
           "config=s" => \$config);

if ($nickname eq "") {
        print STDERR "No nickname specified.\n\n$usage\n";
        exit 1;
}

if (not -e $config) {
	print STDERR "Problem with specified config file $config\n$usage\n";
        exit 1;
}

if ($channel ne "" and $channel !~ /^#/) {
  $channel = "#" . $channel;
}

open (CONFIG,"<$config") or die ("Problem opening config file $config : $!\n");
        
while (<CONFIG>) {
        chomp;
        SWITCH: {
          if (/^\s*DSN\s*=\s*(.*)$/i) { $dsn = $1; last SWITCH; }
          if (/^\s*USER\s*=\s*(.*)$/i) { $mysqluser = $1; last SWITCH; }
          if (/^\s*PASS\s*=\s*(.*)$/i) { $mysqlpass = $1; last SWITCH; }
        }
}

close(CONFIG);
                
unless ( $dsn and $mysqluser and $mysqlpass ) {
        die "You must specify DSN, USER and PASS in the config file $config\n";
}

my $dbh = DBI->connect ($dsn,$mysqluser,$mysqlpass) or bail_out("cannot connect");
my $sth = $dbh->prepare("select * from BotConfig where NickName = \'$nickname\'") or bail_out("Cannot prepare");
$sth->execute() or bail_out("cannot execute");
my $row = $sth->fetchrow_hashref();
        
if (not defined($row)) {
  print STDERR "No configuration found for $nickname\n";
  exit 1;
}

$sth->finish;

# If we got this far then the NickName is valid \o/

my ($sth1) = $dbh->prepare(qq{ select * from BotLogs where BotNick = ? and Channel = ? order by TimeStamp,UniqID }) or bail_out("prepare failed");
$sth1->execute( $nickname, $channel ) or bail_out("execute failed");

while ($row = $sth1->fetchrow_hashref) {
  print STDOUT time2str("[%H:%M]",$row->{TimeStamp}) . " " . $row->{Entry} . "\n";
}
$sth1->finish;

exit 0;

# Handle errors from DBI
sub bail_out {
        my $message = shift;
        die "$message\nError $DBI::err ($DBI::errstr)\n";
}
