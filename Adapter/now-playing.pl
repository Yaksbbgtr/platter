#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils), Resources/now-playing.pl.
#
# Loads the Now Playing adapter library into perl (a platform binary, which
# MediaRemote still answers on macOS 15.4+) and runs it.
use strict;
use warnings;
use DynaLoader;

$| = 1;
my ($library, $mode) = @ARGV;
$mode //= "get";
my %entries = (get => "platter_now_playing_get", watch => "platter_now_playing_watch");
die "now-playing: unknown mode\n" unless exists $entries{$mode};
die "usage: now-playing.pl <adapter library> [get|watch]\n" unless defined $library && -f $library;
my $handle = DynaLoader::dl_load_file($library, 0)
    or die "now-playing: cannot load adapter: " . DynaLoader::dl_error() . "\n";
my $symbol = DynaLoader::dl_find_symbol($handle, $entries{$mode})
    or die "now-playing: entry point missing: " . DynaLoader::dl_error() . "\n";
DynaLoader::dl_install_xsub("main::platter_now_playing_run", $symbol);
platter_now_playing_run();
