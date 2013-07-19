
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
    "scripts/es-copy-index.pl",
    "scripts/es-daily-index-maintenance.pl",
    "scripts/es-metrics-to-graphite.pl",
    "scripts/es-nagios-check.pl",
    "scripts/es-status.pl"
  ],
  "LICENSE" => "bsd",
  "NAME" => "App::ElasticSearch::Utilities",
  "PREREQ_PM" => {
    "Carp" => 0,
    "DateTime" => 0,
    "ElasticSearch" => 0,
    "File::Basename" => 0,
    "File::Spec" => 0,
    "FindBin" => 0,
    "Getopt::Long" => 0,
    "IO::Socket::INET" => 0,
    "IPC::Run3" => 0,
    "JSON" => 0,
    "JSON::XS" => 0,
    "LWP::Simple" => 0,
    "MIME::Lite" => 0,
    "Pod::Usage" => 0,
    "Sub::Exporter" => 0,
    "Sys::Hostname" => 0,
    "Term::ANSIColor" => 0,
    "YAML" => 0,
    "strict" => 0,
    "warnings" => 0
  },
  "TEST_REQUIRES" => {
    "File::Find" => 0,
    "File::Temp" => 0,
    "Pod::Coverage::TrustPod" => 0,
    "Test::More" => 0,
    "Test::Perl::Critic" => 0
  },
  "VERSION" => "1.003",
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



