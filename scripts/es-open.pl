#!/usr/bin/env perl
# PODNAME: es-open.pl
# ABSTRACT: Open any closed indices matching your paramters.
use strict;
use warnings;

use App::ElasticSearch::Utilities qw(es_indices es_request);
use CLI::Helpers qw(:output);
use Getopt::Long qw(:config no_ignore_case no_ignore_case_always);
use Pod::Usage;

#------------------------------------------------------------------------#
# Argument Parsing
my %OPT;
GetOptions(\%OPT,
    'attributes|attr:s',
    'help|h',
    'manual|m',
);

#------------------------------------------------------------------------#
# Documentation
pod2usage(1) if $OPT{help};
pod2usage(-exitval => 0, -verbose => 2) if $OPT{manual};

# Return all closed indexes within our constraints.
my @indices = es_indices(state => 'closed');

foreach my $idx (reverse sort @indices) {
    verbose("Opening index: $idx");
    my $result = es_request('_open', { index=>$idx, method => 'POST'});
    debug_var($result);
    my $color = 'green';
    output({color=>$color}, "+ Opened '$idx'");
}

__END__

=pod

=head1 NAME

es-open.pl - Open any closed indices matching your paramters.

=head1 VERSION

version 3.0

=head1 SYNOPSIS

es-open.pl [options]

Options:

    --help              print help
    --manual            print full manual

From CLI::Helpers:

    --color             Boolean, enable/disable color, default use git settings
    --verbose           Incremental, increase verbosity
    --debug             Show developer output
    --quiet             Show no output (for cron)

=head1 DESCRIPTION

This tool provides access to open any closed indices in the cluster
matching the parameters.

Open the last 45 days of logstash indices:

    es-open.pl --base logstash --days 45

=head1 NAME

es-open.pl - Utility for opening indices that are closed mathcing the constraints.

=head1 OPTIONS

=over 8

=item B<help>

Print this message and exit

=item B<manual>

Print detailed help with examples

=head1 AUTHOR

Brad Lhotsky <brad@divisionbyzero.net>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by Brad Lhotsky.

This is free software, licensed under:

  The (three-clause) BSD License

=cut
