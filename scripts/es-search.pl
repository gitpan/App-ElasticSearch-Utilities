#!/usr/bin/env perl
# PODNAME: es-search.pl
# ABSTRACT: Provides a CLI for quick searches of data in ElasticSearch daily indexes
$|=1;           # Flush STDOUT
use strict;
use warnings;

use CLI::Helpers qw(:all);
use App::ElasticSearch::Utilities qw(:all);
use Carp;
use Getopt::Long qw(:config no_ignore_case no_ignore_case_always);
use Pod::Usage;
use Data::Dumper;
use POSIX qw(strftime);
use YAML;

# For Elements which are data structures
local $Data::Dumper::Indent = 0;
local $Data::Dumper::Terse = 1;
local $Data::Dumper::Sortkeys = 1;

#------------------------------------------------------------------------#
# Argument Parsing
my %OPT;
GetOptions(\%OPT,
    'asc',
    'desc',
    'exists:s',
    'missing:s',
    'size|n:i',
    'show:s',
    'top:s',
    'tail',
    'fields',
    'no-header',
    'help|h',
    'manual|m',
);

# Search string is the rest of the argument string
my $search_string = join(' ', expand_ip_to_range(@ARGV));

#------------------------------------------------------------------------#
# Documentation
pod2usage(1) if $OPT{help};
pod2usage(-exitval => 0, -verbose => 2) if $OPT{manual};
my $unknown_options = join ', ', grep /^--/, @ARGV;
pod2usage({-exitval => 1, -msg =>"Unknown option(s): $unknown_options"}) if $unknown_options;

#--------------------------------------------------------------------------#
# App Config
my %CONFIG = (
    size => (exists $OPT{size} && $OPT{size} > 0 ? int($OPT{size}) : 20),
);

#------------------------------------------------------------------------#
# Handle Indices
my $ORDER = exists $OPT{asc} && $OPT{asc} ? 'asc' : 'desc';
$ORDER = 'asc' if exists $OPT{tail};
my %by_age = ();
my %indices = map { $_ => es_index_days_old($_) } es_indices();
my %FIELDS = ();
foreach my $index (sort by_index_age keys %indices) {
    my $age = $indices{$index};
    $by_age{$age} ||= [];
    push @{ $by_age{$age} }, $index;
    @FIELDS{es_index_fields($index)} = ();
}
debug_var(\%by_age);
my @AGES = sort { $ORDER eq 'asc' ? $b <=> $a : $a <=> $b } keys %by_age;
debug({color=>"cyan"}, "Fields discovered.");
debug_var(\%FIELDS);

# Which fields to show
my @SHOW = ();
my %HASH_FIELDS = ();
if ( exists $OPT{show} && length $OPT{show} ) {
    @SHOW = grep { exists $FIELDS{$_} } split /,/, $OPT{show};
    # hash will contain '{fieldname.key1.key2.key3}' => { field => 'fieldname', key => [ 'key1', 'key2', 'key3' ] }
    %HASH_FIELDS = map { my @v = split( /\./, substr( $_, 1, -1 ) ); $_ => { field => shift( @v ), key => \@v  } } grep { /^\{.+\..+\}$/ } @SHOW;
    debug_var(\%HASH_FIELDS);
}

if( $OPT{fields} ) {
    show_fields();
    exit 0;
}
pod2usage({-exitval => 1, -msg => 'No search string specified'}) unless defined $search_string and length $search_string;
pod2usage({-exitval => 1, -msg => 'Cannot use --tail and --top together'}) if exists $OPT{tail} && $OPT{top};
pod2usage({-exitval => 1, -msg => 'Please specify --show with --tail'}) if exists $OPT{tail} && !@SHOW;

# Fix common mistakes
$search_string =~ s/\s+and\s+/ AND /g;
$search_string =~ s/\s+or\s+/ OR /g;
$search_string =~ s/\s+not\s+/ NOT /g;

# Process extra parameters
my %extra = ();
my @filters = ();
if( exists $OPT{exists} ) {
    foreach my $field (split /[,:]/, $OPT{exists}) {
        push @filters, { exists => { field => $OPT{exists} } };
    }
}
if( exists $OPT{missing} ) {
    foreach my $field (split /[,:]/, $OPT{missing}) {
        push @filters, { missing => { field => $OPT{exists} } };
    }
}
if( @filters ) {
    $extra{filter} = @filters > 1 ? { and => \@filters } : shift @filters;
}

my $DONE = 1;
local $SIG{INT} = sub { $DONE=1 };

my $facet_header = '';
if( exists $OPT{top} ) {
    my @facet_fields = grep { length($_) && exists $FIELDS{$_} } map { s/^\s+//; s/\s+$//; lc } split ',', $OPT{top};
    croak(sprintf("Option --top takes up to two fields, found %d fields: %s\n", scalar(@facet_fields),join(',',@facet_fields)))
        unless @facet_fields > 0 && @facet_fields < 3;

    my @facet;
    if ( scalar @facet_fields == 1 ) {
        @facet = ( field => $facet_fields[0] );
        $facet_header = "count\t" . $facet_fields[0];
    } else {
        #generate a script as
        my $script_field = join " + ':' + ", map { "_doc['$_'].value" } @facet_fields;
        @facet = ( script_field => $script_field );
        $facet_header = "count\t" . join ':', @facet_fields;
    }
    $extra{facets} = { top => { terms => { size => $CONFIG{size}, @facet }, facet_filter => exists $extra{filter} ? $extra{filter} : {} } };
    $CONFIG{size} = 0;  # and we do not want any results other than the facet data
}
elsif(exists $OPT{tail}) {
    $CONFIG{size} = 10;
    @AGES = ($AGES[-1]);
    $DONE = 0;
}

my $size = $CONFIG{size} > 50 ? 50 : $CONFIG{size};
my %displayed_indices = ();
my $TOTAL_HITS = 0;
my $last_hit_ts = undef;
my $duration = 0;
my $displayed = 0;
my $header = exists $OPT{'no-header'};
my $age = undef;
my %last_batch_id=();

AGES: while( !$DONE || @AGES ) {
    $age = @AGES ? shift @AGES : $age;
    select(undef,undef,undef,1) if exists $OPT{tail} && $last_hit_ts;
    my $start=time();
    $last_hit_ts ||= strftime('%Y-%m-%dT%H:%M:%S%z',localtime($start));
    my $local_search_string = exists $OPT{tail} ? sprintf('%s AND @timestamp:[%s TO *]', $search_string, $last_hit_ts)
                                                : $search_string;
    debug({color=>'yellow'},"Search String is $local_search_string");
    output({color=>'yellow'}, "Faceting for on " . join(',', @{ $by_age{$age} })) if $OPT{top};
    my $result = es_request('_search',
        # Search Parameters
        {
            index     => $by_age{$age},
            uri_param => {
                timeout     => '10s',
                scroll      => '30s',
            },
            method => 'POST',
        },
        # Search Body
        {
            size       => $size,
            query      => { query_string => { query => $local_search_string } } ,
            sort       => [ { '@timestamp' => $ORDER } ],
            %extra,
        }
    );
    debug_var($result);
    $duration += time() - $start;
    next unless defined $result;

    $displayed_indices{$_} = 1 for @{ $by_age{$age} };
    $TOTAL_HITS += $result->{hits}{total};

    my @always = qw(@timestamp);
    $header++ == 0 && @SHOW && output({color=>'cyan'}, join("\t", @always,@SHOW));
    while( $result || !$DONE ) {
        my $hits = ref $result->{hits}{hits} eq 'ARRAY' ? $result->{hits}{hits} : [];

        # Handle Faceting
        my $facets = exists $result->{facets} ? $result->{facets}{top}{terms} : [];
        if( @$facets ) {
            output({color=>'cyan'},$facet_header);
            foreach my $facet ( @$facets ) {
                output("$facet->{count}\t$facet->{term}");
                $displayed++;
            }
            $TOTAL_HITS = $result->{facets}{top}{other} + $displayed;
            next AGES;
        }

        # Reset the last batch ID if we have new data
        %last_batch_id = () if @{$hits} > 0 && $last_hit_ts ne $hits->[-1]->{_source}{'@timestamp'};
        debug({color=>'magenta'}, "+ ID cache is now empty.") unless keys %last_batch_id;

        foreach my $hit (@{ $hits }) {
            # Skip if we've seen this record
            next if exists $last_batch_id{$hit->{_id}};

            $last_hit_ts = $hit->{_source}{'@timestamp'};
            $last_batch_id{$hit->{_id}}=1;
            my $record = {};
            if( @SHOW ) {
                foreach my $f (@always) {
                    $record->{$f} = $hit->{_source}{$f};
                }
                foreach my $f (@SHOW) {
                    $record->{$f} = exists $HASH_FIELDS{$f} ? extract_value( $HASH_FIELDS{$f}{key}, $hit->{_source}{$HASH_FIELDS{$f}{field}}, $hit->{_source}{'@fields'}{$HASH_FIELDS{$f}{field}} )
                                  : exists $hit->{_source}{$f} ? $hit->{_source}{$f}
                                  : exists $hit->{_source}{'@fields'}{$f} ? $hit->{_source}{'@fields'}{$f}
                                  : undef;
                }
            }
            else {
                $record = $hit->{_source};
            }
            # Determine how this record is output
            my $output = undef;
            if( @SHOW ) {
                my @cols=();
                foreach my $f (@always,@SHOW) {
                    my $v = '-';
                    if( exists $record->{$f} && defined $record->{$f} ) {
                        $v = ref $record->{$f} ? Dumper $record->{$f} : $record->{$f};
                    }
                    push @cols,$v;
                }
                $output = join("\t",@cols);
            }
            else {
                $output = Dump $record;
            }

            output($output);
            $displayed++;
            last if $DONE && $displayed >= $CONFIG{size};
        }
        last if $DONE && $displayed >= $CONFIG{size};

        # Scroll forward
        $start = time;
        $result = es_request('_search/scroll', {
            uri_param => {
                scroll_id => $result->{_scroll_id},
                scroll    => '30s',
            }
        });
        $duration += time - $start;
        last unless @{ $result->{hits}{hits} } > 0;
    }
    last if $DONE && $displayed >= $CONFIG{size};
}
output({stderr=>1,color=>'yellow'},
    "# Search string: $search_string",
    "# Displaying $displayed of $TOTAL_HITS in $duration seconds.",
    sprintf("# Indexes (%d of %d) searched: %s\n",
            scalar(keys %displayed_indices),
            scalar(keys %indices),
            join(',', sort keys %displayed_indices)
    ),
);

sub extract_value {
    my ($key, $v1, $v2) = @_;
    my $value = $v1 ? $v1 : $v2;
    $value = ref($value) eq 'HASH' ? $value->{$_} : ref($value) eq 'ARRAY' ? $value->[$_] : undef for @{ $key };
    return $value;
}

sub show_fields {
    output({color=>'cyan'}, 'Fields available for search:' );
    my $total = 0;
    foreach my $field (sort keys %FIELDS) {
        $total++;
        output(" - $field");
    }
    output({color=>"yellow"},
        sprintf("# Fields: %d from a combined %d indices.\n",
            $total,
            scalar(keys %indices),
        )
    );
}


sub by_index_age {
    return $ORDER eq 'asc'
        ? $indices{$b} <=> $indices{$a}
        : $indices{$a} <=> $indices{$b};
}

sub expand_ip_to_range {
    for ( @_ ) {
        s/^([^:]+_ip):(\d+\.\d+)\.\*(?:\.\*)?$/$1:[$2.0.0 $2.255.255]/;
        s/^([^:]+_ip):(\d+\.\d+\.\d+)\.\*$/$1:[$2.0 $2.255]/;
    }
    @_;
}

__END__

=pod

=head1 NAME

es-search.pl - Provides a CLI for quick searches of data in ElasticSearch daily indexes

=head1 VERSION

version 2.9

=head1 SYNOPSIS

es-search.pl [search string]

Options:

    --help              print help
    --manual            print full manual
    --show              Comma separated list of fields to display, default is ALL, switches to tab output
    --tail              Continue the query until CTRL+C is sent
    --top               Perform a facet on the fields, by a comma separated list of up to 2 items
    --exists            Field which must be present in the document
    --missing           Field which must not be present in the document
    --size              Result size, default is 20
    --asc               Sort by ascending timestamp
    --desc              Sort by descending timestamp (Default)
    --no-header         Do not show the header with field names in the query results
    --fields            Display the field list for this index!

From CLI::Helpers:

    --color             Boolean, enable/disable color, default use git settings
    --verbose           Incremental, increase verbosity
    --debug             Show developer output
    --quiet             Show no output (for cron)

=head1 DESCRIPTION

This tool takes a search string parameter to search the cluster.  It is in the format of the Lucene
L<query string|http://lucene.apache.org/core/2_9_4/queryparsersyntax.html>

Examples might include:

    # Search for past 10 days vhost admin.example.com and client IP 1.2.3.4
    es-search.pl --days=10 --size=100 dst:"admin.example.com" AND src_ip:"1.2.3.4"

    # Search for all apache logs past 5 days with status 500
    es-search.pl program:"apache" AND crit:500

    # Search for all apache logs past 5 days with status 500 show only file and out_bytes
    es-search.pl program:"apache" AND crit:500 --show file,out_bytes

    # Search for ip subnet client IP 1.2.3.0 to 1.2.3.255 or 1.2.0.0 to 1.2.255.255
    es-search.pl --size=100 dst:"admin.example.com" AND src_ip:"1.2.3.*"
    es-search.pl --size=100 dst:"admin.example.com" AND src_ip:"1.2.*"

    # Show the top src_ip for 'www.example.com'
    es-search.pl --base access dst:www.example.com --top src_ip

    # Tail the access log for www.example.com 404's
    es-search.pl --base access --tail --show src_ip,file,referer_domain dst:www.example.com AND crit:404

Helpful in building queries is the --fields options which lists the fields:

    es-search.pl --fields

=head1 NAME

es-search.pl - Search a logging cluster for information

=head1 OPTIONS

=over 8

=item B<help>

Print this message and exit

=item B<manual>

Print detailed help with examples

=item B<show>

Comma separated list of fields to display in the dump of the data

    --show src_ip,crit,file,out_bytes

=item B<tail>

Repeats the query every second until CTRL+C is hit, displaying new results.  Due to the implementation,
this mode enforces that only the most recent indices are searched.  Also, given the output is continuous, you must
specify --show with this option.

=item B<top>

Comma separated list of fields to facet on.  Given that this uses scripted facets for multi-field facets,
it is limited to faceting on up to 2 fields.  This option is not available when using --tail

    --top src_ip

=item B<exists>

Filter results to those containing a valid, not null field

    --exists referer

Only show records with a referer field in the document.

=item B<missing>

Filter results to those not containing a valid, not null field

    --missing referer

Only show records without a referer field in the document.

=item B<fields>

Display a list of searchable fields

=item B<index>

Search only this index for data, may also be a comma separated list

=item B<days>

The number of days back to search, the default is 5

=item B<base>

Index base name, will be expanded using the days back parameter.  The default
is 'logstash' which will expand to 'logstash-YYYY.MM.DD'

=item B<size>

The number of results to show, default is 20.

=back

=head1 AUTHOR

Brad Lhotsky <brad@divisionbyzero.net>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by Brad Lhotsky.

This is free software, licensed under:

  The (three-clause) BSD License

=cut
