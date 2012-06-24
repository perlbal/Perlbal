use strict;
use warnings;

use lib 't/lib';

use IO::Select;
use Perlbal::Test;
use Perlbal::Test::WebClient;
use Perlbal::Test::WebServer;
use Time::HiRes 'time';

use Test::More tests => 2;

SKIP: {
    skip 'TODO', 2;

my $perlbal_port = new_port();

my $web_port = start_webserver();
ok($web_port, 'webserver started');

my $conf = qq{
LOAD Throttle

CREATE POOL a
    POOL a ADD 127.0.0.1:$web_port

CREATE SERVICE proxy
    SET role                = reverse_proxy
    SET listen              = 127.0.0.1:$perlbal_port
    SET pool                = a

    SET initial_delay       = 1
    SET max_delay           = 8

    SET log_events=all

    SET plugins             = Throttle
ENABLE proxy
};

my $msock = start_server($conf);
ok($msock, 'perlbal started');

for my $n (1 .. 5) {
    my $wc = Perlbal::Test::WebClient->new;
    $wc->server("127.0.0.1:$perlbal_port");
    $wc->http_version('1.0');

    my $start = time;
    my $resp = $wc->request({ host => "example.com", }, "foo/bar.txt");
    my $end = time;

    printf "req $n took %.2fs\n", $end - $start;
    #ok($resp, "got a response");
}

#print $msock "SET whitelist_file = t/helper/whitelist.txt";
#print $msock "SET blacklist_file = t/helper/blacklist.txt";
#
#
#is($resp->code, 200, "response code correct");
#
#my @readable = $select->can_read(0.1);
#if (ok(scalar(@readable), 'syslog got messages')) {
#    my @msgs = <$syslogd>;
#    if (is(scalar(@msgs), 7, 'syslog got right number of messages')) {
#        like($msgs[0], qr/^<173>.*localhost explicit\[\d+\]: registering TestPlugin$/, 'logged Registering');
#        like($msgs[1], qr/^<174>.*localhost explicit\[\d+\]: info message in plugin$/, 'logged info message');
#        like($msgs[2], qr/^<171>.*localhost explicit\[\d+\]: error message in plugin$/, 'logged error message');
#        like($msgs[3], qr/^<173>.*localhost explicit\[\d+\]: printing to stdout$/, 'logged via STDOUT');
#        like($msgs[4], qr/^<173>.*localhost explicit\[\d+\]: printing to stderr$/, 'logged via STDERR');
#        like($msgs[5], qr/^<174>.*localhost explicit\[\d+\]: beginning run$/, 'captured internal message');
#        like($msgs[6], qr/^<173>.*localhost explicit\[\d+\]: handling request in TestPlugin$/, 'logged in request');
#    }
#}

#my $syslog_port = new_port();
#use IO::Socket::INET;
#my $syslogd = IO::Socket::INET->new(
#    Proto       => 'udp',
#    Type        => SOCK_DGRAM,
#    LocalHost   => 'localhost',
#    LocalPort   => $syslog_port,
#    Blocking    => 0,
#    Reuse       => 1,
#) or die "failed to listen on udp $syslog_port: $!";
#my $select = IO::Select->new($syslogd);
}


1;

__END__

=head1 TODO

* Throttling
* Banning
* Logging
* Memcached/local
* Filters
* White/blacklist

* Configs:
default_action
whitelist_file
blacklist_file
blacklist_action
throttle_threshold_seconds
initial_delay
max_delay
max_concurrent
path_regex
method_regex
log_only
memcached_servers
memcached_async_clients
instance_name
ban_threshold
ban_expiration
log_events

=cut
