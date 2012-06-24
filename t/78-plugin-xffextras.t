use strict;
use warnings;

use lib 't/lib';

use Perlbal::Test;
use Perlbal::Test::WebClient;
use Perlbal::Test::WebServer;

use Test::More tests => 4;

my $perlbal_address = '127.0.0.1';
my $perlbal_port = new_port();

my $web_port = start_webserver();
ok($web_port, 'webserver started');

my $conf = qq{
LOAD XFFExtras

CREATE POOL a
    POOL a ADD 127.0.0.1:$web_port

CREATE SERVICE proxy
    SET role                = reverse_proxy
    SET listen              = $perlbal_address:$perlbal_port
    SET pool                = a

    SET plugins             = XFFExtras

    SET send_backend_port   = yes
    SET send_backend_proto  = yes
ENABLE proxy
};

my $msock = start_server($conf);
ok($msock, 'perlbal started');

my $wc = Perlbal::Test::WebClient->new;
$wc->server("127.0.0.1:$perlbal_port");
$wc->http_version('1.0');

my $resp = $wc->request("reflect_request_headers");

my $content = $resp->content;

like($content, qr/^X-Forwarded-Port: \Q$perlbal_port\E$/mi, "Got an X-Forwarded-Port header that seems reasonable");
like($content, qr/^X-Forwarded-Proto: (?-i:http)$/mi, "Got an X-Forwarded-Proto header that seems reasonable");
