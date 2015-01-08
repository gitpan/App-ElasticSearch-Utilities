#!/usr/bin/env perl
# PODNAME: es-daily-index-maintenance.pl
# ABSTRACT: Run to prune old indexes and optimize existing
use strict;
use warnings;

use Getopt::Long qw(:config no_ignore_case no_ignore_case_always);
use Pod::Usage;
use CLI::Helpers qw(:all);
use App::ElasticSearch::Utilities qw(:all);

#------------------------------------------------------------------------#
# Argument Collection
my %opt;
GetOptions(\%opt,
    'all',
    'delete',
    'delete-days:i',
    'close',
    'close-days:i',
    'replicas',
    'replicas',
    'replicas-min:i',
    'replicas-max:i',
    'replicas-age:s',
    'optimize',
    'optimize-days:i',
    'index-basename:s',
    'date-separator:s',
    'timezone:s',
    # Basic options
    'help|h',
    'manual|m',
);

#------------------------------------------------------------------------#
# Documentations!
pod2usage(-exitval => 0) if $opt{help};
pod2usage(-exitval => 0, -verbose => 2) if $opt{manual};

my %CFG = (
    'optimize-days'  => 1,
    'delete-days'    => 90,
    'close-days'     => 60,
    'replicas-min'   => 0,
    'replicas-max'   => 100,
    'replicas-age'   => 60,
    timezone         => 'Europe/Amsterdam',
    delete           => 0,
    close            => 0,
    optimize         => 0,
    replicas         => 0,
);
# Extract from our options if we've overridden defaults
foreach my $setting (keys %CFG) {
    $CFG{$setting} = $opt{$setting} if exists $opt{$setting} and defined $opt{$setting};
}

# Figure out what to run
my @MODES = qw(close delete optimize replicas);
if ( exists $opt{all} && $opt{all} ) {
    map {
        $CFG{$_} = 1 unless $_ eq 'replicas';
    } @MODES;
}
else {
    my $operate = 0;
    foreach my $mode (@MODES) {
        $operate++ if $CFG{$mode};
        last if $operate;
    }
    pod2usage(-message => "No operation selected, use --close, --delete, --optimize, or --replicas.", -exitval => 1) unless $operate;
}
# Can't have replicas-min below 0
$CFG{'replicas-min'} = 0 if $CFG{'replicas-min'} < 0;

# Create the target uri for the ES Cluster
my $es = es_connect();

# Ages for replica management
my $AGE = (grep { my $x = int($_); $x > 0; } split /,/, $CFG{'replicas-age'})[-1];

# Retrieve a list of indexes
my @indices = es_indices(
    check_state => 0,
    check_dates => 0,
);

# Loop through the indices and take appropriate actions;
my @alias_changes=();
foreach my $index (sort @indices) {
    verbose({level=>2},"$index being evaluated");

    my $days_old = es_index_days_old( $index );
    debug({color=>"cyan"}, "$index: index is $days_old days old");

    if( $days_old < 1 ) {
        verbose("$index for today, skipping.");
        next;
    }

    # Delete the Index if it's too old
    if( $CFG{delete} && $CFG{'delete-days'} < $days_old ) {
        output({color=>"red"}, "$index will be deleted.");
        my $rc = es_delete_index($index);
        next;
    }

    # Manage replicas
    if( $CFG{replicas} ) {
        my %shards = es_index_shards($index);
        # Default for replicas is primaries - 1;
        my $replicas = $shards{primaries} - 1;
        my $iter = int(($AGE/$replicas) + 0.5);
        my @ages = map { my $v = $_ * $iter; $v < 1 ? 1 : $v } 0 .. $replicas - 1;
        splice @ages, -1, 1, $AGE;
        foreach my $age ( @ages ) {
            if ( $days_old >= $age ) {
                $replicas--;
            }
        }
        # If we set replicas max, honor it.
        $replicas = $opt{'replicas-max'} if exists $opt{'replicas-max'} && $replicas > $opt{'replicas-max'};
        debug({indent=>1}, "+ replica aging (P:$shards{primaries} R:$shards{replicas}->$replicas): " . join(',', @ages));
        $replicas = $CFG{'replicas-min'} if $replicas < $CFG{'replicas-min'};
        if ( $shards{primaries} > 0 && $shards{replicas} != $replicas ) {
            verbose({color=>'yellow'}, "$index: should have $replicas replicas, has $shards{replicas}");
            my $result = es_request('_settings',
                { index => $index, method => 'PUT' },
                { index => { number_of_replicas => $replicas} },
            );
            if(!defined $result) {
                output({color=>'red',indent=>1}, "Error encountered.");
            }
            else {
                output({color=>"green"}, "$index: Successfully set replicas to $replicas");
            }
        }
    }

    # Run optimize?
    if( $CFG{optimize} ) {
        my $segdata = es_segment_stats( $index );

        my $segment_ratio = undef;
        if( defined $segdata && $segdata->{shards} > 0 ) {
            $segment_ratio = sprintf( "%0.2f", $segdata->{segments} / $segdata->{shards} );
        }

        if( $days_old >= $CFG{'optimize-days'} && defined($segment_ratio) && $segment_ratio > 1 ) {
            verbose({color=>"yellow"}, "$index: required (segment_ratio: $segment_ratio).");

            my $o_res = es_optimize_index($index);
            if( !defined $o_res ) {
                output({color=>"red"}, "$index: Encountered error during optimize");
            }
            else {
                output({color=>"green"}, "$index: $o_res->{_shards}{successful} of $o_res->{_shards}{total} shards optimized.");
            }
        }
        else {
            if( defined($segment_ratio) && $segment_ratio > 1 ) {
                verbose("$index is active not optimizing (segment_ratio:$segment_ratio)");
            }
            else {
                verbose("$index already optimized");
            }
        }
    }

    # Close the index?
    if( $CFG{close} && $CFG{'close-days'} < $days_old ) {
        my $status = es_request('_status',{index=>$index});
        if( defined $status ) {
            if( $status->{_shards}{total} > 0 ) {
                # retrieve aliases
                my $ars = es_request('_alias', {index=>$index});
                foreach my $alias ( keys %{ $ars->{$index}{aliases} } ) {
                    debug({indent=>1}, "- Will remove alias $alias from $index");
                    push @alias_changes, { remove => { index => $index, alias => $alias }};
                }
                verbose({indent=>1}," - closing index.");
                my $result = es_request('_close' => {method=>'POST',index=>$index});
                if( defined $result && $result->{acknowledged}) {
                    output({color=>'magenta'},"+ Closed $index.");
                }
                else {
                    output({color=>'red'},"! Attempted to close $index, but did not succeed.");
                }
            }
            else {
                debug({indent=>1},"- $index already closed.");
            }
        }
        else {
            output({color=>'red'},"! Error establishing status of $index");
        }
    }
}
# If we closed indexes with aliases, we need to remove those aliases so searches to those aliases don't fail.
if(@alias_changes) {
    verbose("+ Indexes closed had aliases, removing those aliases to prevent searches against closed indices.");
    my $result = es_request('_aliases', {method=>'POST'}, { actions => \@alias_changes });
    debug_var($result);
}

__END__

=pod

=encoding UTF-8

=head1 NAME

es-daily-index-maintenance.pl - Run to prune old indexes and optimize existing

=head1 VERSION

version 3.4.1

=head1 SYNOPSIS

es-daily-index-maintenance.pl --all --local

Options:

    --help              print help
    --manual            print full manual
    --all               Run close, delete, optimize, and replicas tools
    --close             Run close for indexes older than
    --close-days        Age of the oldest index to keep open (default:60)
    --delete            Run delete indexes older than
    --delete-days       Age of oldest index to keep (default: 90)
    --optimize          Run optimize on indexes
    --optimize-days     Age of first index to optimize (default: 1)
    --replicas          Run the replic aging hook
    --replicas-age      Age of the index to reach the minimum replicas (default:60)
    --replicas-min      Minimum number of replicas this index may have (default:0)
    --replicas-max      Maximum number of replicas this index may have (default:100)

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

This script assists in maintaining the indexes for logging clusters through
routine deletion and optimization of indexes.

Use with cron:

    22 4 * * * es-daily-index-maintenance.pl --local --all --delete-days=180 --replicas-age=90 --replicas-min=1

=head1 OPTIONS

=over 8

=item B<close>

Run the close hook

=item B<close-days>

Integer, close indexes older than this number of days

=item B<delete>

Run the delete hook

=item B<delete-days>

Integer, delete indexes older than this number of days

=item B<optimize>

Run the optimization hook

=item B<optimize-days>

Integer, optimize indexes older than this number of days

=item B<replicas>

Run the replicas hook.

=item B<replicas-age>

The age at which we reach --replicas-min, default 60

=item B<replicas-min>

The minimum number of replicas to allow replica aging to set.  The default is 0

    --replicas-min=1

=item B<replicas-max>

The maximum number of replicas to allow replica aging to set.  The default is 100

    --replicas-max=2

=back

=head1 AUTHOR

Brad Lhotsky <brad@divisionbyzero.net>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by Brad Lhotsky.

This is free software, licensed under:

  The (three-clause) BSD License

=cut
