#!/usr/bin/env perl
# PODNAME: es-nodes.pl
# ABSTRACT: Listing the nodes in a cluster with some details
use strict;
use warnings;

use CLI::Helpers qw(:all);
use App::ElasticSearch::Utilities qw(es_request);
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

my $cres = es_request('_cluster/health');
my $CLUSTER = defined $cres ? $cres->{cluster_name} : 'UNKNOWN';

output({clear=>1,color=>'magenta'}, "Cluster [$CLUSTER] contains $cres->{number_of_nodes} nodes.", '-='x20);
# Get a list of nodes
my $nres = es_request('_cluster/state', {
    uri_param => {
        filter_routing_table => 1,
        filter_metadata => 1,
        filter_blocks => 1,
        filter_indices => 1,
    },
});
if(!defined $nres) {
    output({stderr=>1,color=>'red'}, 'Fetching node status failed.');
    exit 1;
}
debug_var($nres);
foreach my $uuid (sort { $nres->{nodes}{$a}->{name} cmp $nres->{nodes}{$b}->{name} } keys %{ $nres->{nodes} }) {
    my $node = $nres->{nodes}{$uuid};
    my $color = $uuid eq $nres->{master_node} ? 'green' : 'cyan';

    output({color=>$color}, $node->{name});
    output({indent=>1,kv=>1,color=>$color}, address => $node->{transport_address});
    verbose({indent=>1,kv=>1,color=>$color}, uuid => $uuid);
    if( exists $OPT{attributes} ) {
        output({indent=>1}, "attributes:");
        foreach my $attr ( split /,/, $OPT{attributes} ) {
            next unless exists $node->{attributes}{$attr};
            output({indent=>2,kv=>1}, $attr => $node->{attributes}{$attr});
        }
    }
}

__END__

=pod

=head1 NAME

es-nodes.pl - Listing the nodes in a cluster with some details

=head1 VERSION

version 3.0

=head1 SYNOPSIS

es-nodes.pl [options]

Options:

    --help              print help
    --manual            print full manual
    --attibutes         Comma separated list of attributes to display, default is NONE

From CLI::Helpers:

    --color             Boolean, enable/disable color, default use git settings
    --verbose           Incremental, increase verbosity
    --debug             Show developer output
    --quiet             Show no output (for cron)

=head1 DESCRIPTION

This tool provides access to information on nodes in the the cluster.

=head1 NAME

es-nodes.pl - Utility for investigating the nodes in a cluster

=head1 OPTIONS

=over 8

=item B<help>

Print this message and exit

=item B<manual>

Print detailed help with examples

=item B<attributes>

Comma separated list of node attributes to display, aliased as --attr

    --attributes dc,id

=head1 AUTHOR

Brad Lhotsky <brad@divisionbyzero.net>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by Brad Lhotsky.

This is free software, licensed under:

  The (three-clause) BSD License

=cut
