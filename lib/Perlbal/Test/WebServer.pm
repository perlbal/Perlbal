#!/usr/bin/perl

package Perlbal::Test::WebServer;

use strict;
use IO::Socket::INET;
use HTTP::Request;
use Socket qw(MSG_NOSIGNAL IPPROTO_TCP TCP_NODELAY SOL_SOCKET);
use Perlbal::Test;

use Perlbal::Test::WebClient;

require Exporter;
use vars qw(@ISA @EXPORT);
@ISA = qw(Exporter);
@EXPORT = qw(start_webserver);

our @webserver_pids;

my $testpid; # of the test suite's main program, the one running the HTTP client

END {
    # ensure we kill off the webserver
    kill 9, @webserver_pids if $testpid && $testpid == $$;
}


sub start_webserver {
    my $port = new_port();

    # dummy mode
    if ($ENV{'TEST_PERLBAL_USE_EXISTING'}) {
        return $port;
    }

    $testpid = $$;

    if (my $child = fork) {
        # i am parent, wait for child to startup
        push @webserver_pids, $child;
        my $sock = wait_on_child($child, $port);
        die "Unable to spawn webserver on port $port\n"
            unless $sock;
        print $sock "GET /reqdecr,status HTTP/1.0\r\n\r\n";
        my $line = <$sock>;
        die "Didn't get 200 OK: " . (defined $line ? $line : "(undef)")
            unless $line && $line =~ /200 OK/;
        return $port;
    }

    # i am child, start up
    my $ssock = IO::Socket::INET->new(LocalPort => $port, ReuseAddr => 1, Listen => 3)
        or die "Unable to start socket: $!\n";
    while (my $csock = $ssock->accept) {
        exit 0 unless $csock;
        fork and next; # parent starts waiting for next request
        setsockopt($csock, IPPROTO_TCP, TCP_NODELAY, pack("l", 1)) or die;
        serve_client($csock);
    }
}

sub serve_client {
    my $csock = shift;
    my $req_num = 0;
    my $did_options = 0;
    my @reqs;

  REQ:
    while (1) {
        my $req = '';
        my $clen = undef;
        while (<$csock>) {
            $req .= $_;
            if (/^content-length:\s*(\d+)/i) { $clen = $1; };
            last if ! $_ || /^\r?\n/;
        }
        exit 0 unless $req;

        # parse out things we want to have
        my @cmds;
        my $httpver = 0; # 0 = 1.0, 1 = 1.1, undef = neither
        my $method;
        if ($req =~ m!^([A-Z]+) /?(\S+) HTTP/(1\.\d+)\r?\n?!) {
            $method = $1;
            my $cmds = durl($2);
            @cmds = split(/\s*,\s*/, $cmds);
            $req_num++;
            $httpver = ($3 eq '1.0' ? 0 : ($3 eq '1.1' ? 1 : undef));
        }
        my $msg = HTTP::Request->parse($req);
        my $keeping_alive = undef;

        my $body;
        if ($clen) {
            die "Can't read a body on a GET or HEAD" if $method =~ /^GET|HEAD$/;
            my $read = read $csock, $body, $clen;
            die "Didn't read $clen bytes.  Got $read." if $clen != $read;
        }

        my $response = sub {
            my %opts = @_;
            my $code = delete $opts{code};
            my $codetext = delete $opts{codetext};
            my $content = delete $opts{content};
            my $ctype = delete $opts{type};
            my $extra_hdr = delete $opts{headers};
            die "unknown data in opts: %opts" if %opts;

            $extra_hdr ||= '';
            $code ||= $content ? 200 : 200;
            $codetext ||= { 200 => 'OK', 500 => 'Internal Server Error', 204 => "No Content" }->{$code};
            $content ||= "";

            my $clen = length $content;
            $ctype ||= "text/plain" unless $code == 204;
            $extra_hdr .= "Content-Type: $ctype\r\n" if $ctype;

            my $hdr_keepalive = "";

            unless (defined $keeping_alive) {
                my $hdr_connection = $msg->header('Connection') || '';
                if ($httpver == 1) {
                    if ($hdr_connection =~ /\bclose\b/i) {
                        $keeping_alive = 0;
                    } else {
                        $keeping_alive = "1.1implicit";
                    }
                }
                if ($httpver == 0 && $hdr_connection =~ /\bkeep-alive\b/i) {
                    $keeping_alive = "1.0keepalive";
                }
            }

            if ($keeping_alive) {
                $hdr_keepalive = "Connection: keep-alive\n";
            } else {
                $hdr_keepalive = "Connection: close\n";
            }

            return "HTTP/1.0 $code $codetext\r\n" .
                $hdr_keepalive .
                "Content-Length: $clen\r\n" .
                $extra_hdr .
                "\r\n" .
                "$content";
        };

        my $send = sub {
            my $res = shift;
            print $csock $res;
            exit 0 unless $keeping_alive;
        };

        # 500 if no commands were given or we don't know their HTTP version
        # or we didn't parse a proper HTTP request
        unless (@cmds && defined $httpver && $msg) {
            print STDERR "500 response!\n";
            $send->($response->(code => 500));
            next REQ;
        }

        if ($method eq "OPTIONS") {
            $did_options = 1;
            $send->($response->(code => 200));
            next REQ;
        }

        # prepare a simple 200 to send; undef this if you want to control
        # your own output below
        my $to_send;

        foreach my $cmd (@cmds) {
            $cmd =~ s/^\s+//;
            $cmd =~ s/\s+$//;

            if ($cmd =~ /^sleep:([\d\.]+)$/i) {
                my $sleeptime = $1;
                #print "I, $$, should sleep for $sleeptime.\n";
                use Time::HiRes;
                my $t1 = Time::HiRes::time();
                select undef, undef, undef, $1;
                my $t2 = Time::HiRes::time();
                my $td = $t2 - $t1;
                #print "I, $$, slept for $td\n";
            }

            if ($cmd =~ /^keepalive:([01])$/i) {
                $keeping_alive = $1;
            }

            if ($cmd eq "status") {
                my $len = $clen || 0;
                my $bu = $msg->header('X-PERLBAL-BUFFERED-UPLOAD-REASON') || '';
                $to_send = $response->(content =>
                                       "pid = $$\nreqnum = $req_num\nmethod = $method\n".
                                       "length = $len\nbuffered = $bu\noptions = $did_options\n");
            }

            if ($cmd eq "reqdecr") {
                $req_num--;
            }

            if ($cmd =~ /^kill:(\d+):(\w+)$/) {
                kill $2, $1;
            }

            if ($cmd =~ /^reproxy_url:(.+)/i) {
                $to_send = $response->(headers => "X-Reproxy-URL: $1\r\n",
                                       code => 204,
                                       );
            }

            if ($cmd =~ /^reproxy_url204:(.+)/i) {
                $to_send = $response->(headers => "X-Reproxy-URL: $1\r\n");
            }

            if ($cmd =~ /^reproxy_url_cached:(\d+):(.+)/i) {
                kill 'USR1', $testpid;
                $to_send = $response->(headers =>
                                       "X-Reproxy-URL: $2\r\nX-Reproxy-Cache-For: $1; Last-Modified Content-Type\r\nLast-Modified: 199\r\nContent-Type: application/badger\r\n");
            }

            if ($cmd =~ /^reproxy_url_multi:((?:\d+:){2,})(\S+)/i) {
                my $ports = $1;
                my $path = $2;
                my @urls;
                foreach my $port (split(/:/, $ports)) {
                    push @urls, "http://127.0.0.1:$port$path";
                }
                $to_send = $response->(headers => "X-Reproxy-URL: @urls\r\n");
            }

            if ($cmd =~ /^reproxy_file:(.+)/i) {
                $to_send = $response->(headers => "X-Reproxy-File: $1\r\n");
            }

            if ($cmd =~ /^subreq:(\d+)$/) {
                my $port = $1;
                my $wc = Perlbal::Test::WebClient->new;
                $wc->server("127.0.0.1:$port");
                $wc->keepalive(0);
                $wc->http_version('1.0');
                my $resp = $wc->request("status");
                my $subpid;
                if ($resp && $resp->content =~ /^pid = (\d+)$/m) {
                    $subpid = $1;
                }
                $to_send = $response->(content => "pid = $$\nsubpid = $subpid\nreqnum = $req_num\n");
            }

            if ($cmd =~ /^reflect_request_headers$/) {
                $to_send = $response->(content => $msg->headers->as_string);
            }
        }

        $send->($to_send || $response->());
    } # while(1)
}

# de-url escape
sub durl {
    my ($a) = @_;
    $a =~ tr/+/ /;
    $a =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    return $a;
}

1;
