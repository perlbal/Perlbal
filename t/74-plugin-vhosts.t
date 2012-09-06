#!/usr/bin/perl

use strict;
use Perlbal::Test;
use Perlbal::Test::WebServer;
use Perlbal::Test::WebClient;
use Test::More 'no_plan';

my $port = new_port();

my $web_port = start_webserver();
ok($web_port, 'webserver started');

my $conf = qq{
LOAD Vhosts

CREATE POOL a
    POOL a ADD 127.0.0.1:$web_port

CREATE SERVICE ss
    SET role = selector
    SET listen = 127.0.0.1:$port
    SET persist_client = 1
    SET plugins = Vhosts
    VHOST doesnotexist.example.com = doesnotexist
    VHOST * = test
ENABLE ss

CREATE SERVICE test
    SET role = reverse_proxy
    SET pool = a
ENABLE test
};

my $msock = start_server($conf);
ok($msock, 'perlbal started');

# make first web client
my $wc = Perlbal::Test::WebClient->new;
$wc->server("127.0.0.1:$port");
$wc->http_version('1.0');
$wc->keepalive(1);

{
    my $resp = $wc->request({ host => "example.com", }, "test");
    ok($resp->is_success, "Got a successful response");
}

{
    my $resp = $wc->request({ host => "doesnotexist.example.com", }, "test");
    is($resp->code, 404, "Got a 404 for non-existing service");
}

1;
