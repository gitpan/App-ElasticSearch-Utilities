
use strict;
use warnings;

use 5.010;

use ExtUtils::MakeMaker 6.30;



my %WriteMakefileArgs = (
  "ABSTRACT" => "Utilities for Monitoring ElasticSearch",
  "AUTHOR" => "Brad Lhotsky <brad\@divisionbyzero.net>",
  "BUILD_REQUIRES" => {},
  "CONFIGURE_REQUIRES" => {
    "ExtUtils::MakeMaker" => "6.30"
  },
  "DISTNAME" => "App-ElasticSearch-Utilities",
  "EXE_FILES" => [
    "scripts/es-alias-manager.pl",
    "scripts/es-apply-settings.pl",
    "scripts/es-daily-index-maintenance.pl",
    "scripts/es-graphite-dynamic.pl",
    "scripts/es-graphite-static.pl",
    "scripts/es-nagios-check.pl",
    "scripts/es-nodes.pl",
    "scripts/es-search.pl",
    "scripts/es-status.pl",
    "scripts/es-storage-data.pl"
  ],
  "LICENSE" => "bsd",
  "NAME" => "App::ElasticSearch::Utilities",
  "PREREQ_PM" => {
    "CLI::Helpers" => 0,
    "Carp" => 0,
    "Data::Dumper" => 0,
    "DateTime" => 0,
    "Elastijk" => 0,
    "Getopt::Long" => 0,
    "IO::Socket::INET" => 0,
    "JSON::XS" => 0,
    "POSIX" => 0,
    "Pod::Usage" => 0,
    "Sub::Exporter" => 0,
    "Time::Local" => 0,
    "YAML" => 0,
    "feature" => 0,
    "strict" => 0,
    "warnings" => 0
  },
  "TEST_REQUIRES" => {
    "File::Spec" => 0,
    "IO::Handle" => 0,
    "IPC::Open3" => 0,
    "Pod::Coverage::TrustPod" => 0,
    "Test::More" => 0,
    "Test::Perl::Critic" => 0
  },
  "VERSION" => "2.2",
  "test" => {
    "TESTS" => "t/*.t"
  }
);


unless ( eval { ExtUtils::MakeMaker->VERSION(6.63_03) } ) {
  my $tr = delete $WriteMakefileArgs{TEST_REQUIRES};
  my $br = $WriteMakefileArgs{BUILD_REQUIRES};
  for my $mod ( keys %$tr ) {
    if ( exists $br->{$mod} ) {
      $br->{$mod} = $tr->{$mod} if $tr->{$mod} > $br->{$mod};
    }
    else {
      $br->{$mod} = $tr->{$mod};
    }
  }
}

unless ( eval { ExtUtils::MakeMaker->VERSION(6.56) } ) {
  my $br = delete $WriteMakefileArgs{BUILD_REQUIRES};
  my $pp = $WriteMakefileArgs{PREREQ_PM};
  for my $mod ( keys %$br ) {
    if ( exists $pp->{$mod} ) {
      $pp->{$mod} = $br->{$mod} if $br->{$mod} > $pp->{$mod};
    }
    else {
      $pp->{$mod} = $br->{$mod};
    }
  }
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

WriteMakefile(%WriteMakefileArgs);



