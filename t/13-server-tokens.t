#!/usr/bin/perl

use strict;
use Perlbal::Test;

use Test::More tests => 13;
require HTTP::Request;

# Build conf files
my $dir   = tempdir();
my @confs = (
    [ new_port() => sub { my $port = shift; qq{
        CREATE SERVICE test
        SET role           = web_server
        SET listen         = 127.0.0.1:$port
        SET docroot        = $dir
        SET server_tokens  = on
        ENABLE test
    } } ],

    [ new_port() => sub { my $port = shift; qq{
        CREATE SERVICE test
        SET role           = web_server
        SET listen         = 127.0.0.1:$port
        SET docroot        = $dir
        SET server_tokens  = off
        ENABLE test
    } } ],
);

my $count = 0;
foreach my $pair (@confs) {
    my $port  = $pair->[0];
    my $conf  = $pair->[1]->($port);
    my $msock = start_server($conf);
    ok($msock, "manage sock");
    my $ua = ua();
    ok($ua, "ua");

    my $req = HTTP::Request->new( GET => "http://127.0.0.1:$port/" );
    my $res = $ua->request($req);

    ok( $res, 'Got result' );
    isa_ok( $res, 'HTTP::Response' );
    ok( $res->is_success, 'Result is successful' );

    if ( $count++ == 0 ) {
        # check it's on
        ok( $res->header('Server'), 'Server header exists' );
        is( $res->header('Server'), 'Perlbal'              );
    } else {
        # check it's off
        ok( ! $res->header('Server'), 'Server header missing' );
    }
}

