#!/usr/bin/perl

use strict;
use Perlbal::Test;
use IO::Socket::INET;
use HTTP::Request;
use Test::More;

BEGIN {
    eval "require Net::Netmask"
        ? plan 'no_plan'
        : plan skip_all => 'Net::Netmask not installed';
}

my $port = new_port();

my $dir = tempdir();

my $conf = qq{
SERVER aio_mode = none
LOAD AccessControl

CREATE SERVICE test
  SET test.role = web_server
  SET test.plugins = AccessControl
  SET test.listen = 127.0.0.1:$port
  SET test.docroot = $dir
  SET test.persist_client = 1
  SET test.AccessControl.use_observed_ip = 1
ENABLE test
};

my $msock = start_server($conf);

{
    my $filename = "$dir/foo.txt";
    open my $fh, ">", $filename;
    print $fh "ooblie\n";
    close $fh;

    ok(-e $filename, "File was written properly");
}


my $ua = ua();
ok($ua, "UA object defined");

ok(manage("USE test"), "Manage context switch success");

sub check {
    my $url = "http://127.0.0.1:$port/foo.txt";
    my $req = HTTP::Request->new(GET => $url, @_);
    my $res = $ua->request($req);
    return $res->is_success;
}

ok(check(), "Initial request succeeds");

ok(manage("ACCESS deny ip 127.0.0.1"), "ACCESS deny was set properly");
ok(!check(), "Denied");
ok(!check(["X-Forwarded-For" => "1.1.1.1"]), "Denied with XFF header");

ok(manage("SET always_trusted = 1"), "Turning always trusted on");

ok(!check(), "Denied");
ok(check(["X-Forwarded-For" => "1.1.1.1"]), "Allowed with XFF header");

ok(manage("SET always_trusted = 0"), "Turning always trusted off again");

ok(manage("SET trusted_upstream_proxies = 127.0.0.1"), "Turning trusted upstream proxies on for 127.0.0.1");

ok(!check(), "Denied");
ok(check(["X-Forwarded-For" => "1.1.1.1"]), "Allowed with XFF header");

ok(manage("SET trusted_upstream_proxies = 10.0.0.0/24, 127.0.0.1"), "Turning trusted upstream proxies on for multiple netmasks");

ok(!check(), "Denied");
ok(check(["X-Forwarded-For" => "1.1.1.1"]), "Allowed with XFF header");

ok(manage("SET test.AccessControl.use_observed_ip = 0"), "Turning off observed IP");
ok(!check(["X-Forwarded-For" => "1.1.1.1"]), "Denied with XFF header");

