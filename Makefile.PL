#!/usr/bin/perl
#
#   Perl Makefile for Perlbal
#   $Id$
#
#   Invoke with 'perl Makefile.PL'
#
#   See ExtUtils::MakeMaker (3) for more information on how to influence
#    the contents of the Makefile that is written
#

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                    => 'Perlbal',
    VERSION_FROM            => 'lib/Perlbal.pm',
    AUTHOR                  => 'Brad Fitzpatrick <brad@danga.com>',
    ABSTRACT_FROM           => 'perlbal',

    (
      exists($ENV{DANGABUILD_MODULESONLY}) ?
      () :
      (EXE_FILES               => [ 'perlbal' ]),
    ),

    PREREQ_PM               => {
        # Required modules for base perlbal to operate
        'base'              => 0,
        'fields'            => 0,
        'lib'               => 0,
        'strict'            => 0,
        'vars'              => 0,
        'warnings'          => 0,
        'Carp'              => 0,
        'constant'          => 0,
        'Danga::Socket'     => '1.44',
        'Errno'             => 0,
        'Fcntl'             => 0,
        'File::Path'        => 0,
        'Getopt::Long'      => 0,
        'Hash::Util'        => 0,
        'HTTP::Date'        => 0,
        'IO::File'          => 0,
        'IO::Handle'        => 0,
        'Scalar::Util'      => 0,
        'Socket'            => 0,
        'Sys::Syscall'      => 0,
        'Time::HiRes'       => 0,

        # Recommended modules
        'BSD::Resource'     => 0,
        #'IO::AIO'           => 1.6,
        #'Perlbal::XS::HTTPHeaders'  => '0.20',

        # Optional modules
        #'Devel::Cycle'      => 0,       # Debugging
        #'Devel::Gladiator'  => 0,       # Debugging
        #'Devel::Peek'       => 0,       # Debugging
        #'Danga::Socket'     => '1.61',  # IPv6
        #'IO::Socket::INET6' => 0,       # IPv6
        #'IO::Socket::SSL'   => '0.98',  # SSL
        #'Sys::Syslog'       => 0,       # Syslogging
        #'Net::Netmask'      => 0,       # trusted_upstream_proxies

        # Required for testing (building)
        'Exporter'          => 0,
        'File::Temp'        => 0,
        'FindBin'           => 0,
        'HTTP::Request'     => 0,
        'HTTP::Response'    => 0,
        'IO::Select'        => 0,
        'IO::Socket::INET'  => 0,
        'LWP::UserAgent'    => 0,
        'Test::More'        => 0.94,    # 0.94 adds support for subtests

        # Optional for testing (building)
        #'Benchmark'         => 0,       # Benchmarking optimizations

        # Required for perlbal-check (contrib)
        #'Data::Dumper'      => 0,

        # Plugin deps
        # (AccessControl) optional: Net::Netmask
        # (AtomStream) required: URI
        # (Cgilike) required: Symbol
        # (Cgilike) required: URI
        # (Eval) required: Data::Dumper
        # (LazyCDN) required: IO::Socket::INET
        # (Palimg) optional (PNG alterations): String::CRC32
        # (Throttle) required: Danga::Socket 1.59
        # (Throttle) required: List::Util
        # (Throttle) required: Net::CIDR::Lite
        # (Throttle) optional: Cache::Memcached::Async
        # (Throttle) optional: Perlbal::Plugin::Syslogger
    },

    (
      exists($ENV{DANGABUILD_DAEMONONLY}) ?
      (PM => {}, PMLIBDIRS => []):
      (),
    ),

);

sub MY::postamble {
    my $tab = chr(9);
    return <<MAKE_FRAG;
docs :: docs/service-parameters.txt

docs/service-parameters.txt: lib/Perlbal/Service.pm
${tab}devtools/gendocs.pl service-parameters

MAKE_FRAG
}
