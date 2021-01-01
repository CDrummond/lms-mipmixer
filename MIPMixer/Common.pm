package Plugins::MIPMixer::Common;

#
# LMS-MIPMixer
#
# Copyright (c) 2020-2021 Craig Drummond <craig.p.drummond@gmail.com>
#
# GPLv2 license.
#

# - Initially based upon MusicMagic Plugin of LMS 8.0 -

# Logitech Media Server Copyright 2001-2020 Logitech
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use URI::Escape;

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::Strings;
use Slim::Utils::Prefs;
use Slim::Utils::Unicode;

*escape = main::ISWINDOWS ? \&URI::Escape::uri_escape : \&URI::Escape::uri_escape_utf8;

my $log = logger('plugin.musicip');

my %filterHash = ();

my $prefs = preferences('plugin.musicip');

$prefs->setValidate('num', qw(scan_interval port mix_variety mix_style reject_size));

sub grabFilters {
	my ($class, $client, $params, $callback, @args) = @_;
	
	my $MMSport = $prefs->get('port');

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&_gotFilters,
		sub {
			$log->error('Failed fetching filters from MusicIP');
			_fetchingFiltersDone(shift);
		},
		{
			client   => $client,
			params   => $params,
			callback => $callback,
			class    => $class,
			args     => \@args,
			timeout  => 5,
#			cacheTime => 0
		}
	);

	$http->get( "http://localhost:$MMSport/api/filters" );
}

sub getFilterList {
	return \%filterHash;
}

sub _gotFilters {
	my $http = shift;

	my @filters = ();

	if ($http) {

		@filters = split(/\n/, decode($http->content));

		if ($log->is_debug && scalar @filters) {

			main::DEBUGLOG && $log->debug("Found filters:");

			for my $filter (@filters) {

				main::DEBUGLOG && $log->debug("\t$filter");
			}
		}
	}

	my $none = sprintf('(%s)', Slim::Utils::Strings::string('NONE'));

	push @filters, $none;
	%filterHash = ();

	foreach my $filter ( @filters ) {

		if ($filter eq $none) {

			$filterHash{0} = $filter;
			next
		}

		$filterHash{$filter} = $filter;
	}

	# remove filter from client settings if it doesn't exist any more
	foreach my $client (Slim::Player::Client::clients()) {

		unless ( $filterHash{ $prefs->client($client)->get('mix_filter') } ) {

			$log->warn('Filter "' . $prefs->client($client)->get('mix_filter') . '" does no longer exist - resetting');
			$prefs->client($client)->set('mix_filter', 0);

		}

	}

	unless ( $filterHash{ $prefs->get('mix_filter') } ) {

		$log->warn('Filter "' . $prefs->get('mix_filter') . '" does no longer exist - resetting');
		$prefs->set('mix_filter', 0);

	}
	
	_fetchingFiltersDone($http);
}

sub _fetchingFiltersDone {
	my $http = shift;

	my $client   = $http->params('client');
	my $params   = $http->params('params');
	my $callback = $http->params('callback');
	my $class    = $http->params('class');
	my @args     = @{$http->params('args')};

	$params->{'filters'} = \%filterHash;

	if ($callback && $class) {
		my $body = $class->handler($client, $params);
		$callback->( $client, $params, $body, @args );	
	}
}

sub decode {
	my $data = shift;
	
	my $enc = Slim::Utils::Unicode::encodingFromString($data);
	return Slim::Utils::Unicode::utf8decode_guess($data, $enc);
}

1;

__END__
