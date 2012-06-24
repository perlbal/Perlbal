#!/usr/bin/perl -w

package Perlbal::Test;

=head1 NAME

Perlbal::Test - Test harness for perlbal server

=head1 SYNOPSIS

#  my $msock = Perlbal::Test::start_server();

=head1 DESCRIPTION

Perlbal::Test provides access to a perlbal server running on the
local host, for testing purposes.

The server can be an already-existing server, a child process, or
the current process.

Various functions are provided to interact with the server.

=head1 FUNCTIONS

=cut

use strict;
use POSIX qw( :sys_wait_h );
use IO::Socket::INET;
use Socket qw(MSG_NOSIGNAL IPPROTO_TCP TCP_NODELAY SOL_SOCKET);
use HTTP::Response;

require Exporter;
use vars qw(@ISA @EXPORT);
@ISA = qw(Exporter);
@EXPORT = qw(ua start_server foreach_aio manage filecontent tempdir new_port
             manage_multi
             mgmt_port wait_on_child dump_res resp_from_sock msock);

our $i_am_parent = 0;
our $msock;  # management sock of child
our $to_kill = 0;
our $mgmt_port;

our $free_port = 60000;

=head1 I<mgmt_port()>

Return the current management port number.

=cut

sub mgmt_port {
	return $mgmt_port;
}

END {
    manage("shutdown") if $i_am_parent;
}

=head1 I<dump_res($http_response)>

Return a readable string formatted from an HTTP::Response object.
Only the first 80 characters of returned content are returned.

=cut

sub dump_res {
    my $res = shift;
    my ($pkg, $filename, $line) = caller;
    my $ret = "$filename:$line ==> ";
    unless ($res) {
        $ret .= "[response undefined]\n";
        return $ret;
    }
    my $ct = $res->content;
    my $len = length $ct;
    if ($len > 80) {
        $ct = substr($ct, 0, 80) . "...";
    }
    my $status = $res->status_line;
    $status =~ s/[\r\n]//g;
    return $ret . "status=[$status] content=$len" . "[$ct]\n";
}

=head1 I<tempdir()>

Return a newly created temporary directory. The directory will be
removed automatically upon program exit.

=cut

sub tempdir {
    require File::Temp;
    return File::Temp::tempdir( CLEANUP => 1 );
}

=head1 I<new_port()>

Return the next free port number in the series. Port numbers are assigned
starting at 60000.

=cut

sub new_port {
    test_port() ? return $free_port++ : return new_port($free_port++);
}

=head1 I<test_port()>

Return 1 if the port is free to use for listening on $free_port else return 0.

=cut

sub test_port {
    my $sock = IO::Socket::INET->new(LocalPort => $free_port) or return 0;
    $sock->close();
    return 1;
}

=head1 I<filecontent($file>>

Return a string containing the contents of the file $file. If $file
cannot be opened, then return undef.

=cut

sub filecontent {
    my $file = shift;
    my $ct;
    open (F, $file) or return undef;
    $ct = do { local $/; <F>; };
    close F;
    return $ct;
}

=head1 I<foreach_aio($callback)>

Set the server into each AIO mode (none, ioaio) and call the specified
callback function with the mode name as argument.

=cut

sub foreach_aio (&) {
    my $cb = shift;

    foreach my $mode (qw(none ioaio)) {
        my $line = manage("SERVER aio_mode = $mode");
        next unless $line;
        $cb->($mode);
    }
}

=head1 I<manage($cmd, %opts)>

Send a command $cmd to the server, and return the response line from
the server.

Optional arguments are:

  quiet_failure => 1

Output a warning if the response indicated an error,
unless $opts{quiet_failure} is true, or the command
was 'shutdown' (which doesn't return a response).

=cut

sub manage {
    my $cmd = shift;
    my %opts = @_;

    print $msock "$cmd\r\n";
    my $res = <$msock>;

    if (!$res || $res =~ /^ERR/) {
        # Make the result visible in failure cases, unless
        # the command was 'shutdown'... cause that never
        # returns anything.
        warn "Manage command failed: '$cmd' '$res'\n"
            unless($opts{quiet_failure} || $cmd eq 'shutdown');

        return 0;
    }
    return $res;
}

=head1 I<manage_multi($cmd)>

Send a command $cmd to the server, and return a multi-line
response. Return the number zero if there was an error or
no response.

=cut

sub manage_multi {
    my $cmd = shift;

    print $msock "$cmd\r\n";
    my $res;
    while (<$msock>) {
        last if /^\./;
        last if /^ERROR/;
        $res .= $_;
    }
    return 0 if !$res || $res =~ /^ERR/;
    return $res;
}

=head1 I<start_server($conf)>

Optionally start a perlbal server and return a socket connected to its
management port.

The argument $conf is a string specifying initial configuration
commands.

If the environment variable TEST_PERLBAL_FOREGROUND is set to a true
value then a server will be started in the foreground, in which case
this function does not return. When the server function finishes,
exit() will be called to terminate the process.

If the environment variable TEST_PERLBAL_USE_EXISTING is set to a true
value then a socket will be returned which is connected to an existing
server's management port.

Otherwise, a child process is forked and a socket is returned which is
connected to the child's management port.

The management port is assigned automatically, a new port number each
time this function is called. The starting port number is 60000.

=cut

sub start_server {
    my $conf = shift;
    $mgmt_port = new_port();

    if ($ENV{'TEST_PERLBAL_FOREGROUND'}) {
        _start_perbal_server($conf, $mgmt_port);
    }

    if ($ENV{'TEST_PERLBAL_USE_EXISTING'}) {
        my $msock = wait_on_child(0, $mgmt_port);
        return $msock;
    }

    my $child = fork;
    if ($child) {
        $i_am_parent = 1;
        $to_kill = $child;
        my $msock = wait_on_child($child, $mgmt_port);
        my $rv = waitpid($child, WNOHANG);
        if ($rv) {
            die "Child process (webserver) died.\n";
        }
        print $msock "proc\r\n";
        my $spid = undef;
        while (<$msock>) {
            last if m!^\.\r?\n!;
            next unless /^pid:\s+(\d+)/;
            $spid = $1;
        }
        die "Our child was $child, but we connected and it says it's $spid."
            unless $child == $spid;

        return $msock;
    }

    # child process...
    _start_perbal_server($conf, $mgmt_port);
}

# Start a perlbal server running and tell it to listen on the specified
# management port number. This function does not return.

sub _start_perbal_server {
    my ($conf, $mgmt_port) = @_;

    require Perlbal;

    $conf .= qq{
CREATE SERVICE mgmt
SET mgmt.listen = 127.0.0.1:$mgmt_port
SET mgmt.role = management
ENABLE mgmt
};

    my $out = sub { print STDOUT "$_[0]\n"; };
    die "Configuration error" unless Perlbal::run_manage_commands($conf, $out);

    unless (Perlbal::Socket->WatchedSockets() > 0) {
        die "Invalid configuration.  (shouldn't happen?)  Stopping (self=$$).\n";
    }

    Perlbal::run();
    exit 0;
}


=head1 I<msock()>

Return a reference to the socket connected to the server's management
port.

=cut

sub msock {
    return $msock;
}


=head1 I<ua()>

Return a new instance of LWP::UserAgent.

=cut

sub ua {
    require LWP::UserAgent;
    return LWP::UserAgent->new;
}

=head1 I<wait_on_child($pid, $port)>

Return a socket which is connected to a child process.

$pid specifies the child process id, and $port is the port number on
which the child is listening.

Several attempts are made; if the child dies or a connection cannot
be made within 5 seconds then this function dies with an error message.

=cut

sub wait_on_child {
    my $pid = shift;
    my $port = shift;

    my $start = time;
    while (1) {
        $msock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port");
        return $msock if $msock;
        select undef, undef, undef, 0.25;
        if ($pid && waitpid($pid, WNOHANG) > 0) {
            die "Child process (webserver) died.\n";
        }
        die "Timeout waiting for port $port to startup" if time > $start + 5;
    }
}

=head1 I<resp_from_sock($sock)>

Read an HTTP response from a socket and return it
as an HTTP::Response object

In scalar mode, return only the $http_response object.

In array mode, return an array of ($http_response, $firstline) where
$firstline is the first line read from the socket, for example:

"HTTP/1.1 200 OK"

=cut

sub resp_from_sock {
    my $sock = shift;

    my $res = "";
    my $firstline = undef;

    while (<$sock>) {
        $res .= $_;
        $firstline ||= $_;
        last if ! $_ || /^\r?\n/;
    }

    unless ($firstline) {
        print STDERR "Didn't get a firstline in HTTP response.\n";
        return undef;
    }

    my $resp = HTTP::Response->parse($res);
    return undef unless $resp;

    my $cl = $resp->header('Content-Length');
    if (defined $cl && $cl > 0) {
        my $content = '';
        my $rv;
        while (($rv = read($sock, $content, $cl)) &&
               ($cl -= $rv) > 0) {
            # don't do anything, the loop is it
        }
        $resp->content($content);
    }

    return wantarray ? ($resp, $firstline) : $resp;
}

1;
