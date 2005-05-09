-- MySQL dump 8.22
--
-- Host: localhost    Database: PoEBoT
---------------------------------------------------------
-- Server version	3.23.55

--
-- Table structure for table 'Banlist'
--

CREATE TABLE Banlist (
  Channel varchar(200) NOT NULL default '',
  Banmask varchar(92) NOT NULL default '',
  KEY Channel (Channel)
) TYPE=MyISAM;

--
-- Table structure for table 'BotChannels'
--

CREATE TABLE BotChannels (
  NickName varchar(15) NOT NULL default '',
  Channel varchar(200) NOT NULL default '',
  KEY NickName (NickName),
  KEY Channel (Channel)
) TYPE=MyISAM;

--
-- Table structure for table 'BotConfig'
--

CREATE TABLE BotConfig (
  NickName varchar(15) NOT NULL default '',
  NickAway varchar(15) default NULL,
  IRCName varchar(50) default NULL,
  IRCServer varchar(67) NOT NULL default 'irc.quakenet.org',
  IRCPort int(5) default '6667',
  IRCUser varchar(10) NOT NULL default 'binbot',
  IRCUmode varchar(10) default 'i',
  QAuth varchar(15) default NULL,
  QPass varchar(10) default NULL,
  PassWord varchar(10) NOT NULL default 'changeme',
  StatsURL varchar(250) NOT NULL default 'http://localhost/',
  IdleTime int(4) default '30',
  UNIQUE KEY NickName (NickName)
) TYPE=MyISAM;

--
-- Table structure for table 'BotLogs'
--

CREATE TABLE BotLogs (
  TimeStamp bigint(20) NOT NULL default '0',
  UniqID bigint(20) default NULL,
  BotNick varchar(15) default NULL,
  Channel varchar(200) default NULL,
  Entry text,
  KEY TimeStamp (TimeStamp),
  KEY UniqID (UniqID,BotNick)
) TYPE=MyISAM;

--
-- Table structure for table 'HTTPDLogs'
--

CREATE TABLE HTTPDLogs (
  TimeStamp bigint(20) default NULL,
  UniqID bigint(20) default NULL,
  BotNick varchar(15) default NULL,
  Peer varchar(30) default NULL,
  Result char(3) default NULL,
  Path varchar(255) default NULL
) TYPE=MyISAM;

--
-- Table structure for table 'OfflineLogs'
--

CREATE TABLE OfflineLogs (
  TimeStamp bigint(20) NOT NULL default '0',
  UniqID bigint(20) default NULL,
  BotNick varchar(15) default NULL,
  Channel varchar(200) default NULL,
  Entry text,
  KEY TimeStamp (TimeStamp),
  KEY BotNick (BotNick),
  KEY Channel (Channel),
  KEY UniqID (UniqID,BotNick)
) TYPE=MyISAM;

--
-- Table structure for table 'Salutes'
--

CREATE TABLE Salutes (
  Salute varchar(200) default NULL,
  Action char(2) default NULL,
  KEY Action (Action)
) TYPE=MyISAM;

--
-- Table structure for table 'Trust'
--

CREATE TABLE Trust (
  BotNick varchar(19) default NULL,
  Channel varchar(200) default NULL,
  Identity varchar(100) default NULL,
  Mode char(1) default NULL
) TYPE=MyISAM;

