package Plugins::MIPMixer::Settings;

#
# LMS-MIPMixer
#
# Copyright (c) 2020-2021 Craig Drummond <craig.p.drummond@gmail.com>
#
# GPLv2 license.
#

# - Initially based upon MusicMagic Plugin of LMS 8.0 -

# Logitech Media Server Copyright 2001-2020 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Web::Settings);

use Plugins::MIPMixer::Common;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.mipmixer',
	'defaultLevel' => 'ERROR',
});

my $prefs = preferences('plugin.mipmixer');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('MIPMIXER');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/MIPMixer/settings/mipmixer.html');
}

sub prefs {
	return ($prefs, qw(host port filter_genres filter_xmas exclude_artists exclude_albums min_duration max_duration mix_filter mix_variety mix_style mix_type mip_path convert_ext no_repeat_artist no_repeat_album no_repeat_track genre_groups));
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	if ( !$params->{'saveSettings'} && !$params->{'filters'} ) {
		Plugins::MIPMixer::Common::grabFilters($class, $client, $params, $callback, @args);
		return undef;
	}
	
	$params->{'filters'} = Plugins::MIPMixer::Common->getFilterList();
	return $class->SUPER::handler($client, $params);
}

1;

__END__
