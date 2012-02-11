#!/usr/bin/perl

use 5.10.1;
use warnings;
use strict;
use Switch;
our ($userID, $userPass, $tunnelID, $debug, $tunnelName, @listURL);

use Logger::Syslog;
use YAML::Tiny;
use LWP::Protocol::https;
use WWW::Mechanize;

####
# configuration section
# not all values are sanity checked
# the first three are from the Tunnel Broker site

# userID value from the Main Page
$userID = "";

# required hash of your password generated by issuing this command at shell:
# echo -n "YourPassword" | md5sum
$userPass = "";

# tunnel ID from the tunnel information page
$tunnelID = "";

# debug output - higher verbosity inherits less verbose logging
# 0 - no debugging
# 1 - errors only logged to syslog
# 2 - warnings logged to syslog
# 3 - info logged to syslog (default)
# 4 - errors+warnings+info printed
# 5 - printing of additional information
# $debug = 3;

# the name given to your IPv6 tunnel interface
$tunnelName = "he-ipv6";

# list of URLs to obtain IP from
# feel free to add/remove at your leisure.
# site must output IP only in plain text
@listURL = (
	"http://v4.ipv6-test.com/api/myip.php",
	"http://whatismyip.org/",
	"http://ifconfig.me/ip",
	"http://automation.whatismyip.com/n09230945.asp"
);

####
# end configuration section
# do not edit any further unless you know what you are doing
# or are atleast brave

# prefix for logging, checks whether debug has been defined above
logger_prefix("he-ipv4:");
$debug = 3 unless defined $debug;

# makes sure that root is running the script
my $curUser = scalar(getpwuid($<));
if ($debug == 5) { say("curUser :" . $curUser) }
if ($curUser ne "root") {
	slog("the IPv4 update script must be executed by root, not " . $curUser . ". exiting", 1);
	exit 1;
}
undef $curUser;

# set some needed stuff, config file location as well as regex for IP addresses
our $configFile = "/var/cache/he-ipv4.yml";
our $regexIP='^((?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?))(?![\\d])';

# checks if config file exists and calls create job if not
unless (-e $configFile) {
	slog("\"" . $configFile . "\" doesn't exist. attempting to create file", 3);
	ymlCreate();
}

# get the last use URL index and last externalIP from YAML file
my ($fileURL, $fileIP) = ymlGet();
if ($debug == 5) { say("from file: fileURL: " . $fileURL . " | fileIP " . $fileIP); }

# check sanity of data and give it some default if the data is out of whack
if ($fileURL !~ /^[0-9]*$/) { $fileURL = 9001; }
if ($fileIP !~ /$regexIP/) { $fileIP = "127.0.0.1" }
if ($debug == 5) { say("post sanity: fileURL: " . $fileURL . " | fileIP " . $fileIP); }

my $urlLen = @listURL;
my $urlNum;

# this next line simply gets the next index for the URL list
if ($fileURL + 1 >= $urlLen ) { $urlNum = 0; } else { $urlNum = $fileURL + 1; }
if ($debug == 5) { say("urlLen: " . $urlLen . " | urlNum: ". $urlNum); }

# gets external IP and which URL index was used
# assuming $fileURL is bad just in case there was an error with a URL
my ($extIP, $urlUsed) = getExtIP($urlNum, \@listURL, $urlLen);
if ($debug == 5) { say("extIP: " . $extIP . " | urlUsed: " . $urlUsed); }

# checks to see if the external IP has changed and processes accordingly
if ($extIP ne $fileIP) {
	# return codes are checked for any failures
	my $update = updateIP($extIP);
	if ($update == 0) {
		# save current values to yaml file
		ymlWrite($urlUsed, $extIP);
		slog("the endpoint IPv4 address has been upated to " . $extIP, 3);
		my $restart = restartTunnel();

		# if tunnel restart has non-0 return, exit with failure else exit with success
		if ($restart != 0) {
			exit 1;
		} else { exit; }
	} else {
		# if update failed, update URL used but keep old IP (want it to update on next go)
		ymlWrite($urlUsed, $fileIP);
		exit 1;
	}
} else {
	# no update needed write URL used and original IP.  exit -1 to indicate nothing done, but no failure
	ymlWrite($urlUsed, $fileIP);
	slog("the external IP address (" . $extIP . ") has not changed", 3);
	exit;
}

####
# subroutines
# splitting the work down to more manageable code

# this sub handles logging stuff
sub slog {
	# if debugging is on
	if ($debug >= 1) {
		# pull message and level and process accordingly
		my $message = shift;
		my $level = shift;
		switch ($level) {
			case 3 {
				if ($level <= $debug) { info($message); }
			}
			case 2 {
				if ($level <= $debug) { warning($message); }
			}
			case 1 {
				if ($level <= $debug) { error($message); }
			}
			else { warning("incorrect value used for message level on subroutine slog call on line " . __LINE__); }
		}

		# if print debug mode is set, print as well add some meaningful prefixes
		if ($debug >= 4) {
			my $prefix;
			if ($level == 1) { $prefix = "[error] "; }
			elsif ($level == 2) { $prefix = "[warning] "; }
			elsif ($level == 3) { $prefix = "[info] "; }
			say($prefix . $message);
		}
	}
}

# this creates a default yaml file with useless yet sane values
sub ymlCreate {
	my $yaml = YAML::Tiny->new;
	$yaml->[0]->{ipv4} = '127.0.0.5';
	$yaml->[0]->{url} = '9001';
	$yaml->write($configFile);
	if (-e $configFile) {
		slog("file created successfully", 3);
	} else {
		slog("crap, something didn't go as planned. file does not appear to have been created. exiting", 1);
		exit 1;
	}
}

# pulls values from yaml file and spits them back
sub ymlGet {
	my $yaml = YAML::Tiny->new;
	$yaml = YAML::Tiny->read($configFile);
	my $url = $yaml->[0]->{url};
	my $ip = $yaml->[0]->{ipv4};
	return($url, $ip);
}

# writes the meaningful values to the yaml file
sub ymlWrite {
	my ($url, $ipv4) = @_;
	my $yaml = YAML::Tiny->new;
	$yaml->[0]->{ipv4} = $ipv4;
	$yaml->[0]->{url} = $url;
	$yaml->write($configFile);
}

# gets the external IP address using one of the URLs from @lishURL
sub getExtIP {
	my ($index, $list, $listLen) = @_;
	my $extIP;
	my $run = 1;

	# creates new mechanize for pulling the data. sets custom user agent to pretend to be curl and catches errors
	my $mech = WWW::Mechanize->new(
		agent=>"curl/7.21.0 (i486-pc-linux-gnu) libcurl/7.21.0 WWW-Mechanize/$WWW::Mechanize::VERSION (theckman/he-ipv4.pl)",
		onerror=>sub { slog("something happened when trying to connect to " . $list->[$index], 2); } );

	# loop will run as many times as there are values in the URL list.
	while ($run <= $listLen) {
		# gets the URL and throws the content in to $extIP
		$mech->get($list->[$index]);
		$extIP = $mech->content(format=>'text');

		# the content is matched against regext to make sure we got an IP.  Also makes sure HTTP status 200
		# if not try again with different URL until loop ends. if no URL is obtained exit 1
		if ($extIP !~ /$regexIP/ && $mech->status() == 200) {
			slog("incorrect value obtained from " . $list->[$index] . ". trying next url", 2);
			next;
		} elsif ($run == $listLen && $extIP !~ /$regexIP/) {
			slog("unable to determine external IP address for some reason. do you have an active network connection? exiting", 1);
			exit 1;
		} elsif ($extIP =~ /$regexIP/ && $mech->status() == 200) {  $extIP = $1; last; }

	} continue {
		if ($index + 1 == @$list ) { $index = 0; } else { $index++; };
		$run++;
	}
	return ($extIP, $index);
}

# push to Hurricane Electric API
sub updateIP {
	# pulls IP and generates URL
	my $IPV4 = $_[0];
	my $url = "https://ipv4.tunnelbroker.net/ipv4_end.php?apikey=" . $userID . "&pass=" . $userPass . "&ip=" . $IPV4 . "&tid=" . $tunnelID;

	# creates mechanize for pushing with same UA and has an error catch. then calls the URL to set the IP
	my $mech = WWW::Mechanize->new(
		agent=>"curl/7.21.0 (i486-pc-linux-gnu) libcurl/7.21.0 WWW::Mechanize/$WWW::Mechanize::VERSION (theckman/he-ipv4.pl)",
		onerror=>sub { slog("something happened when trying to connect to http://ipv4.tunnelbroker.net. unable to update IP", 1); } );
	$mech->get($url);
	if ($debug == 5) { say("url: " . $url); }
	if ($debug == 5) { say("output: " . $mech->content(format=>'text')); }

	# kind of risky I suppose assuming HTTP 200 = success
	if ($mech->status() != 200 ) {
		return 1;
	} else { return 0; }
}

# restart the tunnel interface
# please note: this process is built/tested for Debian-derived distros
# it assumes ifup and ifdown are available also that radvd is installed with proper init script
sub restartTunnel {
	slog("killing " . $tunnelName . " interface for ten seconds", 2);

	# brings down interface checks for failure and handles accordingly
	system("/sbin/ifdown " . $tunnelName);
	if ($? != 0) {
		slog("unusual exit code detected when killing interface. issuing command again and continuing", 2);
		system("/sbin/ifdown " . $tunnelName);
	}
	sleep 10;

	# bring the interface back up. save exit status to variable and check and handle accordingly
	system("/sbin/ifup " . $tunnelName);
	my $tunnelUp = $?;
	if ($tunnelUp != 0) {
		slog("unusual exit code detected when bringing interface. issuing command again and continuing", 2);
		system("/sbin/ifup " . $tunnelName);
		$tunnelUp = $?;
	}
	sleep 2;

	# restart rdvd, save exit status, check and handle accordingly
	system("/etc/init.d/radvd restart");
	my $radvdUp = $?;
	if ($radvdUp != 0) {
		slog("unusual exit code detected when restarting radvd. issuing command again and exiting. IPv6 networking may be interrupted", 1);
		system("/etc/init.d/radvd restart");
		$radvdUp = $?;
	}

	# if one of the ifup or radvds failed.  if not, return 0 happy message
	# if something weird happened note it and return error
	if (($tunnelUp && $radvdUp) == 0) {
		slog($tunnelName . " and RAdvD have been restarted", 3);
		return 0;
	} else { slog("something when wrong when bringing networking back up. connectivity may be interrupted", 2); return 1; }
}
