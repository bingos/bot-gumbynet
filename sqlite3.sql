CREATE TABLE BotChannels (
  NickName varchar(15) NOT NULL PRIMARY KEY,
  Channel varchar(200) NOT NULL
);

CREATE TABLE BotConfig (
  NickName varchar(15) NOT NULL UNIQUE PRIMARY KEY,
  IRCName varchar(50) default NULL,
  IRCServer varchar(67) NOT NULL,
  IRCPort int(5) default '6667',
  IRCUser varchar(10) NOT NULL default 'binbot',
  IRCUmode varchar(10) default 'i'
);

CREATE TABLE BotLogs (
  TimeStamp bigint(20) NOT NULL default '0' PRIMARY KEY,
  UniqID bigint(20) default NULL,
  BotNick varchar(15) default NULL,
  Channel varchar(200) default NULL,
  Entry text
);

CREATE TABLE Trust (
  BotNick varchar(19) default NULL,
  Channel varchar(200) default NULL,
  Identity varchar(100) default NULL,
  Mode char(1) default NULL
);

CREATE TABLE GitHub ( 
  Channel varchar(200) default NULL, 
  Repository varchar(200) default NULL
);
