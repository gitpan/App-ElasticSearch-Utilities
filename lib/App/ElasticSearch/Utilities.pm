# ABSTRACT: Utilities for Monitoring ElasticSearch
package App::ElasticSearch::Utilities;

our $VERSION = '2.1'; # VERSION

use strict;
use warnings;

our $ES_CLASS = undef;
our $_OPTIONS_PARSED;
our %_GLOBALS = ();
our @_CONFIGS = (
    '/etc/es-utils.yaml',
    '/etc/es-utils.yml',
    "$ENV{HOME}/.es-utils.yaml",
    "$ENV{HOME}/.es-utils.yml",
);

use CLI::Helpers qw(:all);
use Time::Local;
use Getopt::Long qw(:config pass_through);
use JSON::XS;
use YAML;
use Elastijk;
use Sub::Exporter -setup => {
    exports => [ qw(
        es_pattern
        es_connect
        es_request
        es_nodes
        es_indices
        es_indices_meta
        es_index_valid
        es_index_days_old
        es_index_shards
        es_index_segments
        es_index_stats
        es_settings
        es_node_stats
        es_segment_stats
        es_close_index
        es_open_index
        es_delete_index
        es_optimize_index
        es_apply_index_settings
    )],
    groups => {
        default => [qw(es_connect es_indices es_request)],
        indices => [qw(:default es_indices_meta)],
        index   => [qw(:default es_index_valid es_index_fields es_index_days_old es_index_shard_replicas)],
    },
};


my %opt = ();
if( !defined $_OPTIONS_PARSED ) {
    GetOptions(\%opt,
        'local',
        'host:s',
        'port:i',
        'timeout:i',
        'keep-proxy',
        'index:s',
        'pattern:s',
        'base|index-basename:s',
        'days:i',
        'noop',
        'datesep|date-separator:s',
    );
    $_OPTIONS_PARSED = 1;
}
foreach my $config_file (@_CONFIGS) {
    next unless -f $config_file;
    debug("Loading options from $config_file");
    my %from_file = ();
    eval {
        my $ref = YAML::LoadFile($config_file);
        %from_file = %{$ref};
        debug_var($ref);
    };
    debug({color=>"red"}, "[$config_file] $@") if $@;
    $_GLOBALS{$_} = $from_file{$_} for keys %from_file;
}
# Set defaults
my %DEF = (
    # Connection Options
    HOST        => exists $opt{host} ? $opt{host} :
                   exists $_GLOBALS{host} ? $_GLOBALS{host} :
                   exists $opt{local} ? 'localhost' : 'localhost',
    PORT        => exists $opt{port} ? $opt{port} :
                   exists $_GLOBALS{port} ? $_GLOBALS{port} : 9200,
    TIMEOUT     => exists $opt{timeout} ? $opt{timeout} :
                   exists $_GLOBALS{timeout} ? $_GLOBALS{timeout} : 30,
    NOOP        => exists $opt{noop} ? $opt{noop} :
                   exists $_GLOBALS{noop} ? $_GLOBALS{noop} :
                   undef,
    NOPROXY     => exists $opt{'keep-proxy'} ? 0 :
                   exists $_GLOBALS{'keep-proxy'} ? $_GLOBALS{'keep-proxy'} :
                   1,
    # Index selection options
    INDEX       => exists $opt{index} ? $opt{index} : undef,
    BASE        => exists $opt{base} ? lc $opt{base} :
                   exists $opt{'index-basename'} ? lc $opt{'index-basename'} :
                   undef,
    PATTERN     => exists $opt{pattern} ? $opt{pattern} : '*',
    DAYS        => exists $opt{days} ? $opt{days} :
                   exists $_GLOBALS{days} ? $_GLOBALS{days} : undef,
    DATESEP     => exists $opt{datesep} ? $opt{datesep} :
                   exists $opt{'date-separator'} ? lc $opt{'date-separator'} :
                   '.',
);
debug_var(\%DEF);

if( $DEF{NOPROXY} ) {
    debug("Removing any active HTTP Proxies from ENV.");
    delete $ENV{$_} for qw(http_proxy HTTP_PROXY);
}

# Regexes for Pattern Expansion
my %PATTERN_REGEX = (
    '*'  => qr/.*/,
    '?'  => qr/.?/,
    DATE => qr/\d{4}(?:\Q$DEF{DATESEP}\E)?\d{2}(?:\Q$DEF{DATESEP}\E)?\d{2}/,
    ANY  => qr/.*/,
);

if( index($DEF{DATESEP},'-') >= 0 ) {
    output({stderr=>1,color=>'yellow'}, "=== Using a '-' as your date separator may cause problems with other utilities. ===");
}

# Build the Index Pattern
my $PATTERN = $DEF{PATTERN};
foreach my $literal ( keys %PATTERN_REGEX ) {
    $PATTERN =~ s/\Q$literal\E/$PATTERN_REGEX{$literal}/g;
}


my %_pattern=(
    re     => $PATTERN,
    string => $DEF{PATTERN},
);
sub es_pattern {
    return wantarray ? %_pattern : \%_pattern;
}


my $ES = undef;

sub es_connect {
    my ($override_servers) = @_;

    my $server = $DEF{HOST};
    my $port   = $DEF{PORT};

    # If we're overriding, return a unique handle
    if(defined $override_servers) {
        my @overrides = ref $override_servers eq 'ARRAY' ? @$override_servers : $override_servers;
        my @servers;
        foreach my $entry ( @overrides ) {
            my ($s,$p) = split /\:/, $entry;
            $p ||= $port;
            push @servers, { host => $s, port => $p };
        }

        if( @servers > 0 ) {
            my $pick = @servers > 1 ? $servers[int(rand(@servers))] : $servers[0];
            return Elastijk->new(%{$pick});
        }
    }

    # Otherwise, cache our handle
    $ES ||= Elastijk->new(
        host => $server,
        port => $port
    );

    return $ES;
}


sub es_request {
    my $instance = ref $_[0] eq 'Elastijk::oo' ? shift @_ : es_connect();
    my($url,$options,$body) = @_;

    # Pull connection options
    $options->{$_} = $instance->{$_} for qw(host port);

    $options->{method} ||= 'GET';
    $options->{body} = $body if defined $body && ref $body eq 'HASH';
    $options->{command} = $url;
    my $index = 'NoIndex';

    if( exists $options->{index} ) {
        my $index_in = delete $options->{index};
        #
        # No need to validate _all
        if( $index_in eq '_all') {
            $index = $index_in;
        }
        else {
            # Validate each included index
            my @valid;
            my @test = ref $index_in eq 'ARRAY' ? @{ $index_in } : split /\,/, $index_in;
            foreach my $i (@test) {
                push @valid, $i if es_index_valid($i);
            }
            $index = join(',', @valid);
        }
    }
    $options->{index} = $index if $index ne 'NoIndex';

    my ($status,$res);
    if( $DEF{NOOP} && $options->{method} ne 'GET' ) {
        output({color=>'cyan'}, "Called es_request($index / $options->{command}), but --noop and method is $options->{method}");
        return;
    }
    eval {
        debug("calling es_request($index / $options->{command})");
        ($status,$res) = Elastijk::request($options);
    };
    my $err = $@;
    if( $err || !defined $res ) {
        output({color=>'red',stderr=>1}, "es_request($index / $options->{command}) failed[$status]: $err");
    }
    elsif($status != 200) {
        verbose({color=>'yellow'},"es_request($index / $options->{command}) returned HTTP Status $status");
    }

    return $res;
}



my %_nodes;
sub es_nodes {
    if(!keys %_nodes) {
        my $res = es_request('_cluster/state', {
            uri_param => {
                filter_nodes         => 0,
                filter_routing_table => 1,
                filter_indices       => 1,
                filter_metadata      => 1,
            },
        });
        if( !defined $res  ) {
            output({color=>"red"}, "es_nodes(): Unable to locate nodes in status!");
            exit 1;
        }
        debug_var($res);
        foreach my $id ( keys %{ $res->{nodes} } ) {
            $_nodes{$id} = $res->{nodes}{$id}{name};
        }
    }

    return wantarray ? %_nodes : { %_nodes };
}


my $_indices_meta;
sub es_indices_meta {

    if(!defined $_indices_meta) {
        my $result = es_request('_cluster/state', {
            uri_param => {
                filter_routing_table => 1,
                filter_nodes         => 1,
                filter_blocks        => 1,
            },
        });
        $_indices_meta = $result->{metadata}{indices};
        if ( !defined $_indices_meta ) {
            output({stderr=>1,color=>"red"}, "es_indices(): Unable to locate indices in status!");
            exit 1;
        }
    }

    my %copy = %{ $_indices_meta };
    return wantarray ? %copy : \%copy;
}


my %_valid_index = ();
sub es_indices {
    my %args = (
        state       => 'open',
        check_state => 1,
        check_dates => 1,
        @_
    );
    my @indices = ();

    # Simplest case, single index
    if( defined $DEF{INDEX} ) {
        push @indices, $DEF{INDEX} if es_index_valid( $DEF{INDEX} );
    }
    else {
        my %meta = es_indices_meta();
        foreach my $index (keys %meta) {
            debug("Evaluating '$index'");
            if(!exists $args{_all}) {
                # State Check Disqualification
                next if $args{check_state} && $args{state} ne $meta{$index}->{state} && $args{state} ne 'all';

                if( defined $DEF{BASE} ) {
                    debug({indent=>1}, "+ method:base - $DEF{BASE}");
                    my @parts = split /\-/, $index;
                    my %parts = map { lc($_) => 1 } @parts;
                    next unless exists $parts{$DEF{BASE}};
                }
                else {
                    my $p = es_pattern;
                    debug({indent=>1}, "+ method:pattern - $p->{string}");
                    next unless $index =~ /^$p->{re}/;
                }
                if( $args{check_dates} && defined $DEF{DAYS} ) {
                    debug({indent=>2,color=>"yellow"}, "+ checking to see if index is in the past $DEF{DAYS} days.");

                    my $days_old = es_index_days_old( $index );
                    debug("$index is $days_old days old");
                    if( $days_old < 0 ) {
                        debug({indent=>2,color=>'red'}, "! error locating date in string, skipping !");
                        next;
                    }
                    elsif( $DEF{DAYS} >= 0 && $days_old >= $DEF{DAYS} ) {
                        next;
                    }
                }
            }
            else {
                debug({indent=>1}, "Called with _all, all checks skipped.");
            }
            debug({indent=>1,color=>"green"}, "+ match!");
            push @indices, $index;
        }
    }

    # We retrieved these from the cluster, so preserve them here.
    $_valid_index{$_} = 1 for @indices;

    return wantarray ? @indices : \@indices;
}


my $NOW = timelocal(0,0,0,(localtime)[3,4,5]);
sub es_index_days_old {
    my ($index) = @_;

    return -1 unless defined $index;

    if( my ($dateStr) = ($index =~ /($PATTERN_REGEX{DATE})/) ) {
        my @date = reverse map { int } split /\Q$DEF{DATESEP}\E/, $dateStr;
        $date[1]--; # move 1-12 -> 0-11
        my $idx_time = timelocal( 0,0,0, @date );
        my $diff = $NOW - $idx_time;
        return int($diff / 86400);
    }
    return -1;
}



sub es_index_shards {
    my ($index) = @_;

    my %shards = map { $_ => 0 } qw(primaries replicas);
    my $result = es_request('_settings', {index=>$index});
    if( defined $result && ref $result eq 'HASH')  {
        $shards{primaries} = $result->{$index}{settings}{'index.number_of_shards'};
        $shards{replicas}  = $result->{$index}{settings}{'index.number_of_replicas'};
    }

    return wantarray ? %shards : \%shards;
}


sub es_index_valid {
    my ($index) = @_;

    return unless defined $index && length $index;
    return $_valid_index{$index} if exists $_valid_index{$index};

    my $es = es_connect();

    my $result;
    eval {
        debug("Running index_exists");
        $result = $es->exists( index => $index );
    };
    return $_valid_index{$index} = $result;
}


sub es_close_index {
    my($index) = @_;

    return es_request('_close',{ method => 'POST', index => $index });
}


sub es_open_index {
    my($index) = @_;

    return es_request('_open',{ method => 'POST', index => $index });
}


sub es_delete_index {
    my($index) = @_;

    return es_request('',{ method => 'DELETE', index => $index });
}


sub es_optimize_index {
    my($index) = @_;

    return es_request('_optimize',{
            method    => 'POST',
            index     => $index,
            uri_param => {
                max_num_segments => 1,
                wait_for_merge   => 0,
            },
    });
}

sub es_apply_index_settings {
    my($index,$settings) = @_;

    if(ref $settings ne 'HASH') {
        output({stderr=>1,color=>'red'}, 'usage is es_apply_index_settings($index,$settings_hashref)');
        return;
    }

    return es_request('_settings',{ method => 'PUT', index => $index },$settings);
}


sub es_index_segments {
    my ($index) = @_;

    if( !defined $index || !length $index || !es_index_valid($index) ) {
        output({stderr=>1,color=>'red'}, "es_index_segments('$index'): invalid index");
        return undef;
    }

    return es_request('_segments', {
        index => $index,
    });

}


sub es_segment_stats {
    my ($index) = @_;

    my %segments =  map { $_ => 0 } qw(shards segments);
    my $result = es_index_segments($index);

    if(defined $result) {
        my $shard_data = $result->{indices}{$index}{shards};
        foreach my $id (keys %{$shard_data}) {
            $segments{segments} += $shard_data->{$id}[0]{num_search_segments};
            $segments{shards}++;
        }
    }
    return wantarray ? %segments : \%segments;
}



sub es_index_stats {
    my ($index) = @_;

    return es_request('_stats', {
        index     => $index,
        uri_param => { all => 'true' },
    });
}



sub es_settings {
    return es_request('_settings');
}


sub es_node_stats {
    my (@nodes) = @_;

    my @cmd = qw(_nodes);
    push @cmd, join(',', @nodes) if @nodes;
    push @cmd, 'stats';

    return es_request(join('/',@cmd), { uri_param => {all => 'true'} });
}


sub def {
    my($key)= map { uc }@_;

    return exists $DEF{$key} ? $DEF{$key} : undef;
}




1;

__END__

=pod

=head1 NAME

App::ElasticSearch::Utilities - Utilities for Monitoring ElasticSearch

=head1 VERSION

version 2.1

=head1 SYNOPSIS

This library contains utilities for unified interfaces in the scripts.

This a set of utilities to make monitoring ElasticSearch clusters much simpler.

Included are:

B<SEARCHING>:

    scripts/es-search.pl - Utility to interact with LogStash style indices from the CLI

B<MONITORING>:

    scripts/es-nagios-check.pl - Monitor ES remotely or via NRPE with this script
    scripts/es-graphite-dynamic.pl - Perform index maintenance on daily indexes
    scripts/es-status.pl - Command line utility for ES Metrics
    scripts/es-storage-data.pl - View how shards/data is aligned on your cluster

B<MAINTENANCE>:

    scripts/es-daily-index-maintenance.pl - Perform index maintenance on daily indexes
    scripts/es-alias-manager.pl - Manage index aliases automatically

B<MANAGEMENT>:

    scripts/es-copy-index.pl - Copy an index from one cluster to another
    scripts/es-apply-settings.pl - Apply settings to all indexes matching a pattern
    scripts/es-storage-data.pl - View how shards/data is aligned on your cluster

B<DEPRECATED>:

    scripts/es-graphite-static.pl - Send ES Metrics to Graphite or Cacti

The App::ElasticSearch::Utilities module simply serves as a wrapper around the scripts for packaging and
distribution.

=head1 FUNCTIONS

=head2 es_pattern

Returns a hashref of the pattern filter used to get the indexes
    {
        string => '*',
        re     => '.*',
    }

=head2 es_connect

Without options, this connects to the server defined in the args.  If passed
an array ref, it will use that as the connection definition.

=head2 es_request([$handle],$command,{ method => 'GET', parameters => { a => 1 } }, {})

Retrieve URL from ElasticSearch, returns a hash reference

First hash ref contains options, including:

    uri_param           Query String Parameters
    index               Index name
    type                Index type
    method              Default is GET

=head2 es_nodes

Returns the hash of index meta data.

=head2 es_indices_meta

Returns the hash of index meta data.

=head2 es_indices

Returns a list of active indexes matching the filter criteria specified on the command
line.  Can handle indices named:

    logstash-YYYY.MM.DD
    dcid-logstash-YYYY.MM.DD
    logstash-dcid-YYYY.MM.DD
    logstash-YYYY.MM.DD-dcid

Makes use of --datesep to determine where the date is.

=head2 es_index_days_old( 'index-name' )

Return the number of days old this index is.

=head2 es_index_shard_replicas( 'index-name' )

Returns the number of replicas for a given index.

=head2 es_index_valid( 'index-name' )

Checks if the specified index is valid

=head2 es_close_index('index-name')

Closes an index

=head2 es_open_index('index-name')

Open an index

=head2 es_delete_index('index-name')

Deletes an index

=head2 es_optimize_index('index-name')

Optimize an index to a single segment per shard

=head2 es_index_segments( 'index-name' )

Exposes GET /$index/_segments

Returns the segment data from the index in hashref:

=head2 es_segment_stats($index)

Return the number of shards and segments in an index as a hashref

=head2 es_index_stats( 'index-name' )

Exposes GET /$index/_stats

Returns a hashref

=head2 es_settings()

Exposes GET /_settings

Returns a hashref

=head2 es_node_stats()

Exposes GET /_nodes/stats

Returns a hashref

=head2 def('key')

Exposes Definitions grabbed by options parsing

=head1 ARGS

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

=head1 INSTALL

Recommended install with L<CPAN Minus|http://cpanmin.us>:

    cpanm App::ElasticSearch::Utilities

You can also use CPAN:

    cpan App::ElasticSearch::Utilities

Or if you'd prefer to manually install:

    export RELEASE=<CurrentRelease>

    wget --no-check-certificate https://github.com/reyjrar/es-utils/blob/master/releases/App-ElasticSearch-Utilities-$RELEASE.tar.gz?raw=true -O es-utils.tgz

    tar -zxvf es-utils.tgz

    cd App-ElasticSearch-Utilities-$RELEASE

    perl Makefile.PL

    make

    make install

This will take care of ensuring all the dependencies are satisfied and will install the scripts into the same
directory as your Perl executable.

=head2 USAGE

The tools are all wrapped in their own documentation, please see:

    $UTILITY --help
    $UTILITY --manual

For individual options and capabilities

=head2 PATTERNS

Patterns are used to match an index to the aliases it should have.  A few symbols are expanded into
regular expressions.  Those patterns are:

    *       expands to match any number of any characters.
    ?       expands to match any single character.
    DATE    expands to match YYYY.MM.DD, YYYY-MM-DD, or YYYYMMDD
    ANY     expands to match any number of any characters.

=head2 CONTRIBUTORS

    Mihai Oprea <mishu@mishulica.com>
    Samit Badle

=head1 AUTHOR

Brad Lhotsky <brad@divisionbyzero.net>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by Brad Lhotsky.

This is free software, licensed under:

  The (three-clause) BSD License

=cut
