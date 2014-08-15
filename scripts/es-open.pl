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

=encoding UTF-8

=head1 NAME

es-open.pl - Open any closed indices matching your paramters.

=head1 VERSION

version 3.2

=head1 SYNOPSIS

es-open.pl [options]

Options:

    --help              print help
    --manual            print full manual

From App::ElasticSearch::Utilities:

    --local         Use localhost as the elasticsearch host
    --host          ElasticSearch host to connect to
    --port          HTTP port for your cluster
    --noop          Any operations other than GET are disabled
    --timeout       Timeout to ElasticSearch, default 30
    --keep-proxy    Do not remove any proxy settings from %ENV
    --index         Index to run commands against
    --base          For daily indexes, reference only those starting with "logstash"
                     (same as --pattern logstash-* or logstash-DATE)
    --datesep       Date separator, default '.' also (--date-separator)
    --pattern       Use a pattern to operate on the indexes
    --days          If using a pattern or base, how many days back to go, default: all

=head2 ARGUMENT GLOBALS

Some options may be specified in the B</etc/es-utils.yaml> or B<$HOME/.es-utils.yaml> file:

    ---
    host: esproxy.example.com
    port: 80
    timeout: 10

From CLI::Helpers:

    --data-file         Path to a file to write lines tagged with 'data => 1'
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
