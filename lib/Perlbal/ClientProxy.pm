######################################################################
# HTTP Connection from a reverse proxy client
#
# Copyright 2004, Danga Interactive, Inc.
# Copyright 2005-2007, Six Apart, Ltd.
#
package Perlbal::ClientProxy;
use strict;
use warnings;
use base "Perlbal::ClientHTTPBase";
no  warnings qw(deprecated);

use Perlbal::ChunkedUploadState;
use Perlbal::Util;

use fields (
            'backend',             # Perlbal::BackendHTTP object (or undef if disconnected)
            'backend_requested',   # true if we've requested a backend for this request
            'reconnect_count',     # number of times we've tried to reconnect to backend
            'high_priority',       # boolean; 1 if we are or were in the high priority queue
            'low_priority',        # boolean; 1 if we are or were in the low priority queue
            'reproxy_uris',        # arrayref; URIs to reproxy to, in order
            'reproxy_expected_size', # int: size of response we expect to get back for reproxy
            'currently_reproxying',  # arrayref; the host info and URI we're reproxying right now
            'content_length_remain', # int: amount of data we're still waiting for
            'responded',           # bool: whether we've already sent a response to the user or not
            'last_request_time',   # int: time that we last received a request
            'primary_res_hdrs',  # if defined, we are doing a transparent reproxy-URI
                                 # and the headers we get back aren't necessarily
                                 # the ones we want.  instead, get most headers
                                 # from the provided res headers object here.
            'is_buffering',        # bool; if we're buffering some/all of a request to memory/disk
            'is_writing',          # bool; if on, we currently have an aio_write out
            'start_time',          # hi-res time when we started getting data to upload
            'bufh',                # buffered upload filehandle object
            'bufilename',          # string; buffered upload filename
            'bureason',            # string; if defined, the reason we're buffering to disk
            'buoutpos',            # int; buffered output position
            'backend_stalled',   # boolean:  if backend has shut off its reads because we're too slow.
            'unread_data_waiting',  # boolean:  if we shut off reads while we know data is yet to be read from client
            'chunked_upload_state', # bool/obj:  if processing a chunked upload, Perlbal::ChunkedUploadState object, else undef
            'request_body_length',  # integer:  request's body length, either as-declared,
                                    #           or calculated after chunked upload is complete

            # for perlbal sending out UDP packets related to upload status (for xmlhttprequest upload bar)
            'last_upload_packet',  # unixtime we last sent a UDP upload packet
            'upload_session',      # client's self-generated upload session

            # error-retrying stuff
            'retry_count',         # number of times we've retried this request so far after getting 500 errors
            );

use constant READ_SIZE         => 131072;    # 128k, ~common TCP window size?
use constant READ_AHEAD_SIZE   =>  32768;    # kinda arbitrary.  sum of these two is max stored per connection while waiting for backend.
use Errno qw( EPIPE ENOENT ECONNRESET EAGAIN );
use POSIX qw( O_CREAT O_TRUNC O_RDWR O_RDONLY );
use Time::HiRes qw( gettimeofday tv_interval );

my $udp_sock;

# ClientProxy
sub new {
    my Perlbal::ClientProxy $self = shift;
    my ($service, $sock) = @_;
    $self = fields::new($self) unless ref $self;
    $self->SUPER::new($service,  $sock );

    Perlbal::objctor($self);

    $self->init;
    $self->watch_read(1);
    return $self;
}

sub new_from_base {
    my $class = shift;
    my Perlbal::ClientHTTPBase $cb = shift;
    Perlbal::Util::rebless($cb, $class);
    $cb->init;
    $cb->watch_read(1);
    $cb->handle_request;
    return $cb;
}

sub init {
    my Perlbal::ClientProxy $self = $_[0];

    $self->{last_request_time} = 0;

    $self->{backend} = undef;
    $self->{high_priority} = 0;
    $self->{low_priority} = 0;

    $self->{responded} = 0;
    $self->{unread_data_waiting} = 0;
    $self->{content_length_remain} = undef;
    $self->{backend_requested} = 0;

    $self->{is_buffering} = 0;
    $self->{is_writing} = 0;
    $self->{start_time} = undef;
    $self->{bufh} = undef;
    $self->{bufilename} = undef;
    $self->{buoutpos} = 0;
    $self->{bureason} = undef;
    $self->{chunked_upload_state} = undef;
    $self->{request_body_length} = undef;

    $self->{reproxy_uris} = undef;
    $self->{reproxy_expected_size} = undef;
    $self->{currently_reproxying} = undef;

    $self->{retry_count} = 0;
}

# given a service name, re-request (GET/HEAD only) to that service, even though
# you've already done a request to your original service
sub start_reproxy_service {
    my Perlbal::ClientProxy $self = $_[0];
    my Perlbal::HTTPHeaders $primary_res_hdrs = $_[1];
    my $svc_name = $_[2];

    my $svc = $svc_name ? Perlbal->service($svc_name) : undef;
    unless ($svc) {
        $self->_simple_response(404, "Vhost twiddling not configured for requested pair.");
        return 1;
    }

    $self->{backend_requested} = 0;
    $self->{backend} = undef;
    $self->{res_headers} = $primary_res_hdrs;

    $svc->adopt_base_client($self);
}

# call this with a string of space separated URIs to start a process
# that will fetch the item at the first and return it to the user,
# on failure it will try the second, then third, etc
sub start_reproxy_uri {
    my Perlbal::ClientProxy $self = $_[0];
    my Perlbal::HTTPHeaders $primary_res_hdrs = $_[1];
    my $urls = $_[2];

    # at this point we need to disconnect from our backend
    $self->{backend} = undef;

    # failure if we have no primary response headers
    return unless $self->{primary_res_hdrs} ||= $primary_res_hdrs;

    # construct reproxy_uri list
    if (defined $urls) {
        my @uris = split /\s+/, $urls;
        $self->{currently_reproxying} = undef;
        $self->{reproxy_uris} = [];
        foreach my $uri (@uris) {
            next unless $uri =~ m!^http://(.+?)(?::(\d+))?(/.*)?$!;
            push @{$self->{reproxy_uris}}, [ $1, $2 || 80, $3 || '/' ];
        }
    }

    # if we get in here and we have currently_reproxying defined, then something
    # happened and we want to retry that one
    if ($self->{currently_reproxying}) {
        unshift @{$self->{reproxy_uris}}, $self->{currently_reproxying};
        $self->{currently_reproxying} = undef;
    }

    # if we have no uris in our list now, tell the user 404
    return $self->_simple_response(503)
        unless @{$self->{reproxy_uris} || []};

    # set the expected size if we got a content length in our headers
    if ($primary_res_hdrs && (my $expected_size = $primary_res_hdrs->header('X-REPROXY-EXPECTED-SIZE'))) {
        $self->{reproxy_expected_size} = $expected_size;
    }

    # pass ourselves off to the reproxy manager
    $self->state('wait_backend');
    Perlbal::ReproxyManager::do_reproxy($self);
}

# called by the reproxy manager when we can't get to our requested backend
sub try_next_uri {
    my Perlbal::ClientProxy $self = $_[0];

    if ($self->{currently_reproxying}) {
        # If we're currently reproxying to a backend, that means we want to try the next uri which is
        # ->{reproxy_uris}->[0].
    } else {
        # Since we're not currently reproxying, that means we never got a backend in the first place,
        # so we want to move on to the next uri which is ->{reproxy_uris}->[1] (shift one off)
        shift @{$self->{reproxy_uris}};
    }

    $self->{currently_reproxying} = undef;

    $self->start_reproxy_uri();
}

# returns true if this ClientProxy is too many bytes behind the backend
sub too_far_behind_backend {
    my Perlbal::ClientProxy $self    = $_[0];
    my Perlbal::BackendHTTP $backend = $self->{backend}   or return 0;

    # if a backend doesn't have a service, it's a
    # ReproxyManager-created backend, and thus it should use the
    # 'buffer_size_reproxy_url' parameter for acceptable buffer
    # widths, and not the regular 'buffer_size'.  this lets people
    # tune buffers depending on the types of webservers.  (assumption
    # being that reproxied-to webservers are event-based and it's okay
    # to tie the up longer in favor of using less buffer memory in
    # perlbal)
    my $max_buffer = defined $backend->{service} ?
        $self->{service}->{buffer_size} :
        $self->{service}->{buffer_size_reproxy_url};

    return $self->{write_buf_size} > $max_buffer;
}

# this is a callback for when a backend has been created and is
# ready for us to do something with it
sub use_reproxy_backend {
    my Perlbal::ClientProxy $self = $_[0];
    my Perlbal::BackendHTTP $be = $_[1];

    # get a URI
    my $datref = $self->{currently_reproxying} = shift @{$self->{reproxy_uris}};
    unless (defined $datref) {
        # return error and close the backend
        $be->close('invalid_uris');
        return $self->_simple_response(503);
    }

    # now send request
    $self->{backend} = $be;
    $be->{client} = $self;

    my $extra_hdr = "";
    if (my $range = $self->{req_headers}->header("Range")) {
        $extra_hdr .= "Range: $range\r\n";
    }
    if (my $host = $self->{req_headers}->header("Host")) {
        $extra_hdr .= "Host: $host\r\n";
    }

    my $req_method = $self->{req_headers}->request_method eq 'HEAD' ? 'HEAD' : 'GET';
    my $headers = "$req_method $datref->[2] HTTP/1.0\r\nConnection: keep-alive\r\n${extra_hdr}\r\n";

    $be->{req_headers} = Perlbal::HTTPHeaders->new(\$headers);
    $be->state('sending_req');
    $self->state('backend_req_sent');
    $be->write($be->{req_headers}->to_string_ref);
    $be->watch_read(1);
    $be->watch_write(1);
}

# this is called when a transient backend getting a reproxied URI has received
# a response from the server and is ready for us to deal with it
sub backend_response_received {
    my Perlbal::ClientProxy $self = $_[0];
    my Perlbal::BackendHTTP $be = $_[1];

    # we fail if we got something that's NOT a 2xx code, OR, if we expected
    # a certain size and got back something different
    my $code = $be->{res_headers}->response_code + 0;

    my $bad_code = sub {
        return 0 if $code >= 200 && $code <= 299;
        return 0 if $code == 416;
        return 1;
    };

    my $bad_size = sub {
        return 0 unless defined $self->{reproxy_expected_size};
        return $self->{reproxy_expected_size} != $be->{res_headers}->header('Content-length');
    };

    if ($bad_code->() || $bad_size->()) {
        # fall back to an alternate URL
        $be->{client} = undef;
        $be->close('non_200_reproxy');
        $self->try_next_uri;
        return 1;
    }

    return if $self->{service}->run_hook('reproxy_response_received', $be);

    # a response means that we are no longer currently waiting on a reproxy, and
    # don't want to retry this URI
    $self->{currently_reproxying} = undef;

    return 0;
}

sub start_reproxy_file {
    my Perlbal::ClientProxy $self = shift;
    my $file = shift;                      # filename to reproxy
    my Perlbal::HTTPHeaders $hd = shift;   # headers from backend, in need of cleanup

    # at this point we need to disconnect from our backend
    $self->{backend} = undef;

    # call hook for pre-reproxy
    return if $self->{service}->run_hook("start_file_reproxy", $self, \$file);

    # set our expected size
    if (my $expected_size = $hd->header('X-REPROXY-EXPECTED-SIZE')) {
        $self->{reproxy_expected_size} = $expected_size;
    }

    # start an async stat on the file
    $self->state('wait_stat');
    Perlbal::AIO::aio_stat($file, sub {

        # if the client's since disconnected by the time we get the stat,
        # just bail.
        return if $self->{closed};

        my $size = -s _;

        unless ($size) {
            # FIXME: POLICY: 404 or retry request to backend w/o reproxy-file capability?
            return $self->_simple_response(404);
        }
        if (defined $self->{reproxy_expected_size} && $self->{reproxy_expected_size} != $size) {
            # 404; the file size doesn't match what we expected
            return $self->_simple_response(404);
        }

        # if the thing we're reproxying is indeed a file, advertise that
        # we support byte ranges on it
        if (-f _) {
            $hd->header("Accept-Ranges", "bytes");
        }

        my ($status, $range_start, $range_end) = $self->{req_headers}->range($size);
        my $not_satisfiable = 0;

        if ($status == 416) {
            $hd = Perlbal::HTTPHeaders->new_response(416);
            $hd->header("Content-Range", $size ? "bytes */$size" : "*");
            $not_satisfiable = 1;
        }

        # change the status code to 200 if the backend gave us 204 No Content
        $hd->code(200) if $hd->response_code == 204;

        # fixup the Content-Length header with the correct size (application
        # doesn't need to provide a correct value if it doesn't want to stat())
        if ($status == 200) {
            $hd->header("Content-Length", $size);
        } elsif ($status == 206) {
            $hd->header("Content-Range", "bytes $range_start-$range_end/$size");
            $hd->header("Content-Length", $range_end - $range_start + 1);
            $hd->code(206);
        }

        # don't send this internal header to the client:
        $hd->header('X-REPROXY-FILE', undef);

        # rewrite some other parts of the header
        $self->setup_keepalive($hd);

        # just send the header, now that we cleaned it.
        $self->{res_headers} = $hd;
        $self->write($hd->to_string_ref);

        if ($self->{req_headers}->request_method eq 'HEAD' || $not_satisfiable) {
            $self->write(sub { $self->http_response_sent; });
            return;
        }

        $self->state('wait_open');
        Perlbal::AIO::aio_open($file, 0, 0 , sub {
            my $fh = shift;

            # if client's gone, just close filehandle and abort
            if ($self->{closed}) {
                CORE::close($fh) if $fh;
                return;
            }

            # handle errors
            if (! $fh) {
                # FIXME: do 500 vs. 404 vs whatever based on $! ?
                return $self->_simple_response(500);
            }

            # seek if partial content
            if ($status == 206) {
                sysseek($fh, $range_start, &POSIX::SEEK_SET);
                $size = $range_end - $range_start + 1;
            }

            $self->reproxy_fh($fh, $size);
            $self->watch_write(1);
        });
    });
}

# Client
# get/set backend proxy connection
sub backend {
    my Perlbal::ClientProxy $self = shift;
    return $self->{backend} unless @_;

    my $backend = shift;
    $self->state('draining_res') unless $backend;
    return $self->{backend} = $backend;
}

# invoked by backend when it wants us to start watching for reads again
# and feeding it data (if we have any)
sub backend_ready {
    my Perlbal::ClientProxy $self = $_[0];
    my Perlbal::BackendHTTP $be = $_[1];

    # if we'd turned ourselves off while we waited for a backend, turn
    # ourselves back on, because the backend is ready for data now.
    if ($self->{unread_data_waiting}) {
        $self->watch_read(1);
    }

    # normal, not-buffered-to-disk case:
    return $self->drain_read_buf_to($be) unless $self->{bureason};

    # buffered-to-disk case.

    # tell the backend it has to go into buffered_upload_mode,
    # which makes it inform us of its writable availability
    $be->invoke_buffered_upload_mode;
}

# our backend enqueues a call to this method in our write buffer, so this is called
# right after we've finished sending all of the results to the user.  at this point,
# if we were doing keep-alive, we don't close and setup for the next request.
sub backend_finished {
    my Perlbal::ClientProxy $self = shift;
    print "ClientProxy::backend_finished\n" if Perlbal::DEBUG >= 3;

    # mark ourselves as having responded (presumably if we're here,
    # the backend has responded already)
    $self->{responded} = 1;

    # our backend is done with us, so we disconnect ourselves from it
    $self->{backend} = undef;

    # backend is done sending data to us, so we can recycle this clientproxy
    # if we don't have any data yet to read
    return $self->http_response_sent unless $self->{unread_data_waiting};

    # if we get here (and we do, rarely, in practice) then that means
    # the backend read was empty/disconnected (or otherwise messed up),
    # and the only thing we can really do is close the client down.
    $self->close("backend_finished_while_unread_data");
}

# Called when this client is entering a persist_wait state, but before we are returned to base.
sub persist_wait {
    my Perlbal::ClientProxy $self = $_[0];
    # We're in keepalive, and just completed a proxy request
    $self->{service}->run_hooks('end_proxy_request', $self);
}

# called when we've sent a response to a user fully and we need to reset state
sub http_response_sent {
    my Perlbal::ClientProxy $self = $_[0];

    # persistence logic is in ClientHTTPBase
    return 0 unless $self->SUPER::http_response_sent;

    print "ClientProxy::http_response_sent -- resetting state\n" if Perlbal::DEBUG >= 3;

    if (my $be = $self->{backend}) {
        $self->{backend} = undef;
        $be->forget_client;
    }

    # if we get here we're being persistent, reset our state
    $self->{backend_requested} = 0;
    $self->{high_priority} = 0;
    $self->{reproxy_uris} = undef;
    $self->{reproxy_expected_size} = undef;
    $self->{currently_reproxying} = undef;
    $self->{content_length_remain} = undef;
    $self->{primary_res_hdrs} = undef;
    $self->{responded} = 0;
    $self->{is_buffering} = 0;
    $self->{is_writing} = 0;
    $self->{start_time} = undef;
    $self->{bufh} = undef;
    $self->{bufilename} = undef;
    $self->{buoutpos} = 0;
    $self->{bureason} = undef;
    $self->{upload_session} = undef;
    $self->{chunked_upload_state} = undef;
    $self->{request_body_length} = undef;
    return 1;
}

# to request a backend connection AFTER you've already done so, if you
# didn't like the results from the first one.  (like after a 500 error)
sub rerequest_backend {
    my Perlbal::ClientProxy $self = shift;

    $self->{backend_requested} = 0;
    $self->{backend} = undef;
    $self->request_backend;
}

sub request_backend {
    my Perlbal::ClientProxy $self = shift;
    return if $self->{backend_requested};
    $self->{backend_requested} = 1;

    $self->state('wait_backend');
    $self->{service}->request_backend_connection($self);
    $self->tcp_cork(1);  # cork writes to self
}

# Client (overrides and calls super)
sub close {
    my Perlbal::ClientProxy $self = shift;
    my $reason = shift;

    warn sprintf(
                    "Perlbal::ClientProxy closed %s%s.\n",
                    ( $self->{closed} ? "again " : "" ),
                    (defined $reason ? "saying '$reason'" : "for an unknown reason")
    ) if Perlbal::DEBUG >= 2;

    # don't close twice
    return if $self->{closed};

    # signal that we're done
    $self->{service}->run_hooks('end_proxy_request', $self);

    # kill our backend if we still have one
    if (my $backend = $self->{backend}) {
        print "Client ($self) closing backend ($backend)\n" if Perlbal::DEBUG >= 1;
        $self->backend(undef);
        $backend->close($reason ? "proxied_from_client_close:$reason" : "proxied_from_client_close");
    } else {
        # if no backend, tell our service that we don't care for one anymore
        $self->{service}->note_client_close($self);
    }

    # call ClientHTTPBase's close
    $self->SUPER::close($reason);
}

sub setup_keepalive {
    my Perlbal::ClientProxy $self = $_[0];
    my $not_done_reading = defined $self->{content_length_remain} && $self->{content_length_remain} > 0;

    return $self->SUPER::setup_keepalive($_[1], $not_done_reading ? 0 : undef);
}


sub client_disconnected { # : void
    my Perlbal::ClientProxy $self = shift;
    print "ClientProxy::client_disconnected\n" if Perlbal::DEBUG >= 2;

    # if client disconnected, then we need to turn off watching for
    # further reads and purge the existing upload if any. also, we
    # should just return and do nothing else.

    $self->watch_read(0);
    $self->purge_buffered_upload if $self->{bureason};
    return $self->close('user_disconnected');
}

# Client
sub event_write {
    my Perlbal::ClientProxy $self = shift;
    print "ClientProxy::event_write\n" if Perlbal::DEBUG >= 3;

    # obviously if we're writing the backend has processed our request
    # and we are responding/have responded to the user, so mark it so
    $self->{responded} = 1;

    # will eventually, finally reset the whole object on completion
    $self->SUPER::event_write;

    # trigger our backend to keep reading, if it's still connected
    if ($self->{backend_stalled} && (my $backend = $self->{backend})) {
        print "  unstalling backend\n" if Perlbal::DEBUG >= 3;

        $self->{backend_stalled} = 0;
        $backend->watch_read(1);
    }
}

# ClientProxy
sub event_read {
    my Perlbal::ClientProxy $self = shift;
    print "ClientProxy::event_read\n" if Perlbal::DEBUG >= 3;

    # mark alive so we don't get killed for being idle
    $self->{alive_time} = time;

    # if we have no headers, the only thing we can do is try to get some
    if (! $self->{req_headers}) {
        print "  no headers.  reading.\n" if Perlbal::DEBUG >= 3;
        $self->handle_request if $self->read_request_headers;
        return;
    }

    # if we're buffering to disk or haven't read too much from this client, keep reading,
    # otherwise shut off read notifications
    unless ($self->{is_buffering} || $self->{read_ahead} < READ_AHEAD_SIZE) {
        # our buffer is full, so turn off reads for now
        print "  disabling reads.\n" if Perlbal::DEBUG >= 3;
        $self->watch_read(0);
        return;
    }

    # deal with chunked uploads
    if (my $cus = $self->{chunked_upload_state}) {
        $cus->on_readable($self);

        # if we got more than 1MB not flushed to disk,
        # stop reading for a bit until disk catches up
        if ($self->{read_ahead} > 1024*1024) {
            $self->watch_read(0);
        }
        return;
    }

    # read more data if we're still buffering or if our current read buffer
    # is not full to the max READ_AHEAD_SIZE which is how much data we will
    # buffer in from the user before passing on to the backend

    # read the MIN(READ_SIZE, content_length_remain)
    my $read_size = READ_SIZE;
    my $remain = $self->{content_length_remain};

    $read_size = $remain if $remain && $remain < $read_size;
    print "  reading $read_size bytes (", (defined $remain ? $remain : "(undef)"), " bytes remain)\n" if Perlbal::DEBUG >= 3;

    my $bref = $self->read($read_size);

    # if the read returned undef, that means the connection was closed
    # (see: Danga::Socket::read)
    return $self->client_disconnected unless defined $bref;

    # if they didn't declare a content body length and we just got a
    # readable event that's not a disconnect, something's messed up.
    # they're overflowing us.  disconnect!
    if (! $remain) {
        $self->_simple_response(400, "Can't pipeline to HTTP/1.0");
        $self->close("pipelining_to_http10");
        return;
    }

    # now that we know we have a defined value, determine how long it is, and do
    # housekeeping to keep our tracking numbers up to date.
    my $len = length($$bref);
    print "  read $len bytes\n" if Perlbal::DEBUG >= 3;

    # when run under the program "trickle", epoll speaks the truth to
    # us, but then trickle interferes and steals our reads/writes, so
    # this fails.  normally this check isn't needed.
    return unless $len;

    $self->{read_size} += $len;
    $self->{content_length_remain} -= $len if $remain;

    my $done_reading = defined $self->{content_length_remain} && $self->{content_length_remain} <= 0;
    my $backend = $self->backend;
    print("  done_reading = $done_reading, backend = ", ($backend || "<undef>"), "\n") if Perlbal::DEBUG >= 3;

    # upload tracking
    if (my $session = $self->{upload_session}) {
        my $cl = $self->{req_headers}->content_length;
        my $remain = $self->{content_length_remain};
        my $now = time();  # FIXME: more efficient?
        if ($cl && $remain && ($self->{last_upload_packet} || 0) != $now) {
            my $done = $cl - $remain;
            $self->{last_upload_packet} = $now;
            $udp_sock ||= IO::Socket::INET->new(Proto => 'udp');
            my $since = $self->{last_request_time};
            my $send = "UPLOAD:$session:$done:$cl:$since:$now";
            if ($udp_sock) {
                foreach my $ep (@{ $self->{service}{upload_status_listeners_sockaddr} }) {
                    my $rv = $udp_sock->send($send, 0, $ep);
                }
            }
        }
    }

    # just dump the read into the nether if we're dangling. that is
    # the case when we send the headers to the backend and it responds
    # before we're done reading from the client; therefore further
    # reads from the client just need to be sent nowhere, because the
    # RFC2616 section 8.2.3 says: "the server SHOULD NOT close the
    # transport connection until it has read the entire request"
    if ($self->{responded}) {
        print "  already responded.\n" if Perlbal::DEBUG >= 3;
        # in addition, if we're now out of data (clr == 0), then we should
        # either close ourselves or get ready for another request
        return $self->http_response_sent if $done_reading;

        print "  already responded [2].\n" if Perlbal::DEBUG >= 3;
        # at this point, if the backend has responded then we just return
        # as we don't want to send it on to them or buffer it up, which is
        # what the code below does
        return;
    }

    # if we have no data left to read, stop reading.  all that can
    # come later is an extra \r\n which we handle later when parsing
    # new request headers.  and if it's something else, we'll bail on
    # the next request, not this one.
    if ($done_reading) {
        Carp::confess("content_length_remain less than zero: self->{content_length_remain}")
            if $self->{content_length_remain} < 0;
        $self->{unread_data_waiting} = 0;
        $self->watch_read(0);
    }

    # now, if we have a backend, then we should be writing it to the backend
    # and not doing anything else
    if ($backend) {
        print "  got a backend.  sending write to it.\n" if Perlbal::DEBUG >= 3;
        $backend->write($bref);
        # TODO: monitor the backend's write buffer depth?
        return;
    }

    # now, we know we don't have a backend, so we have to push this data onto our
    # read buffer... it's not going anywhere yet
    push @{$self->{read_buf}}, $bref;
    $self->{read_ahead} += $len;
    print "  no backend.  read_ahead = $self->{read_ahead}.\n" if Perlbal::DEBUG >= 3;

    # if we know we've already started spooling a file to disk, then continue
    # to do that.
    print "  bureason = $self->{bureason}\n" if Perlbal::DEBUG >= 3 && $self->{bureason};
    return $self->buffered_upload_update if $self->{bureason};

    # if we are under our buffer-to-memory size, just continue buffering here and
    # don't fall through to the backend request call below
    return if
        ! $done_reading &&
        $self->{read_ahead} < $self->{service}->{buffer_backend_connect};

    # over the buffer-to-memory size, see if we should start spooling to disk.
    return if $self->{service}->{buffer_uploads} && $self->decide_to_buffer_to_disk;

    # give plugins a chance to act on the request before we request a backend
    # (added by Chris Hondl <chris@imvu.com>, March 2006)
    my $svc = $self->{service};
    return if $svc->run_hook('proxy_read_request', $self);

    # if we fall through to here, we need to ensure that a backend is on the
    # way, because no specialized handling took over above
    print "  finally requesting a backend\n" if Perlbal::DEBUG >= 3;
    return $self->request_backend;
}

sub handle_request {
    my Perlbal::ClientProxy $self = shift;
    my $req_hd = $self->{req_headers};

    unless ($req_hd) {
        $self->close("handle_request without headers");
        return;
    }

    $self->check_req_headers;

    my $svc = $self->{service};
    # give plugins a chance to force us to bail
    return if $svc->run_hook('start_proxy_request', $self);
    return if $svc->run_hook('start_http_request',  $self);

    if ($self->handle_chunked_upload) {
        # handled in method.
    } else {
        # if defined we're waiting on some amount of data.  also, we have to
        # subtract out read_size, which is the amount of data that was
        # extra in the packet with the header that's part of the body.
        my $length = $self->{request_body_length} =
            $self->{content_length_remain} =
            $req_hd->content_length;

        if (defined $length && $length < 0) {
            $self->_simple_response(400, "Invalid request: Content-Length < 0");
            $self->close("negative_content_length");
            return;
        }

        $self->{unread_data_waiting} = 1 if $self->{content_length_remain};
    }

    # upload-tracking stuff.  both starting a new upload track session,
    # and checking on status of ongoing one
    return if $svc->{upload_status_listeners} && $self->handle_upload_tracking;

    # note that we've gotten a request
    $self->{requests}++;
    $self->{last_request_time} = $self->{alive_time};

    # either start buffering some of the request to memory, or
    # immediately request a backend connection.
    if ($self->{chunked_upload_state}) {
        $self->{request_body_length} = 0;
        $self->{is_buffering} = 1;
        $self->{bureason} = 'chunked';
        $self->buffered_upload_update;
    } elsif ($self->{content_length_remain} && $self->{service}->{buffer_backend_connect}) {
        # the deeper path
        $self->start_buffering_request;
    } else {
        # get the backend request process moving, since we aren't buffering
        $self->{is_buffering} = 0;

        # if reproxy-caching is enabled, we can often bypass needing to allocate a BackendHTTP connection:
        return if $svc->{reproxy_cache} && $self->satisfy_request_from_cache;

        $self->request_backend;
    }
}

sub handle_chunked_upload {
    my Perlbal::ClientProxy $self = shift;
    my $req_hd = $self->{req_headers};
    my $te = $req_hd->header("Transfer-Encoding");
    return unless $te && $te eq "chunked";
    return unless $self->{service}->{buffer_uploads};

    $req_hd->header("Transfer-Encoding", undef); # remove it (won't go to backend)

    my $eh = $req_hd->header("Expect");
    if ($eh && $eh =~ /\b100-continue\b/) {
        $self->write(\ "HTTP/1.1 100 Continue\r\n\r\n");
        $req_hd->header("Expect", undef); # remove it (won't go to backend)
    }

    my $max_size = $self->{service}{max_chunked_request_size};

    my $args = {
        on_new_chunk => sub {
            my $cref = shift;
            my $len = length($$cref);
            push @{$self->{read_buf}}, $cref;
            $self->{read_ahead}          += $len;
            $self->{request_body_length} += $len;

            # if too large, disconnect them...
            if ($max_size && $self->{request_body_length} > $max_size) {
                $self->purge_buffered_upload;
                $self->close;
                return;
            }
            $self->buffered_upload_update;
        },
        on_disconnect => sub {
            $self->client_disconnected;
        },
        on_zero_chunk => sub {
            $self->send_buffered_upload;
        },
    };

    $self->{chunked_upload_state} = Perlbal::ChunkedUploadState->new(%$args);
    return 1;
}

sub satisfy_request_from_cache {
    my Perlbal::ClientProxy $self = shift;

    my $req_hd = $self->{req_headers};
    my $svc    = $self->{service};
    my $cache  = $svc->{reproxy_cache};
    $svc->{_stat_requests}++;

    my $requri   = $req_hd->request_uri    || '';
    my $hostname = $req_hd->header("Host") || '';

    my $key      = "$hostname|$requri";

    my $reproxy  = $cache->get($key) or
        return 0;

    my ($timeout, $headers, $urls) = @$reproxy;
    return 0 if time() > $timeout;

    $svc->{_stat_cache_hits}++;
    my %headers = map { ref $_ eq 'SCALAR' ? $$_ : $_ } @{$headers || []};

    if (my $ims = $req_hd->header("If-Modified-Since")) {
        my ($lm_key) = grep { uc($_) eq "LAST-MODIFIED" } keys %headers;
        my $lm = $headers{$lm_key} || "";

        # remove the IE length suffix
        $ims =~ s/; length=(\d+)//;

        # If 'Last-Modified' is same as 'If-Modified-Since', send a 304
        if ($ims eq $lm) {
            my $res_hd = $self->{res_headers} = Perlbal::HTTPHeaders->new_response(304);
            $res_hd->header("Content-Length", "0");
            $self->setup_keepalive($res_hd);
            $self->tcp_cork(1);
            $self->state('xfer_resp');
            $self->write($res_hd->to_string_ref);
            $self->write(sub { $self->http_response_sent; });
            return 1;
        }
    }

    my $res_hd = Perlbal::HTTPHeaders->new_response(200);
    $res_hd->header("Date", HTTP::Date::time2str(time()));
    while (my ($key, $value) = each %headers) {
        $res_hd->header($key, $value);
    }

    $self->start_reproxy_uri($res_hd, $urls);
    return 1;
}

# return 1 to steal this connection (when they're asking status of an
# upload session), return 0 to return it to handle_request's control.
sub handle_upload_tracking {
    my Perlbal::ClientProxy $self = shift;
    my $req_hd = $self->{req_headers};

    return 0 unless
        $req_hd->request_uri =~ /[\?&]client_up_sess=(\w{5,50})\b/;

    my $sess = $1;

    # getting status?
    if ($req_hd->request_uri =~ m!^/__upload_status\?!) {
        my $status = Perlbal::UploadListener::get_status($sess);
        my $now = time();
        my $body = $status ?
            "{done:$status->{done},total:$status->{total},starttime:$status->{starttime},nowtime:$now}" :
            "{}";

        my $res = $self->{res_headers} = Perlbal::HTTPHeaders->new_response(200);
        $res->header("Content-Type", "text/plain");
        $res->header('Content-Length', length $body);
        $self->setup_keepalive($res);
        $self->tcp_cork(1);  # cork writes to self
        $self->write($res->to_string_ref);
        $self->write(\ $body);
        $self->write(sub { $self->http_response_sent; });
        return 1;
    }

    # otherwise just tagging this upload as a new upload session
    $self->{upload_session} = $sess;
    return 0;
}

# continuation of handle_request, in the case where we need to start buffering
# a bit of the request body to memory, either hoping that's all of it, or to
# make a determination of whether or not we should save it all to disk first
sub start_buffering_request {
    my Perlbal::ClientProxy $self = shift;

    # buffering case:
    $self->{is_buffering} = 1;

    # shortcut: if we know that we're buffering by size, and the size
    # of this upload is bigger than that value, we can just turn on spool
    # to disk right now...
    if ($self->{service}->{buffer_uploads} && $self->{service}->{buffer_upload_threshold_size}) {
        my $req_hd = $self->{req_headers};
        if ($req_hd->content_length >= $self->{service}->{buffer_upload_threshold_size}) {
            $self->{bureason} = 'size';
            if ($ENV{PERLBAL_DEBUG_BUFFERED_UPLOADS}) {
                $self->{req_headers}->header('X-PERLBAL-BUFFERED-UPLOAD-REASON', 'size');
            }
            $self->state('buffering_upload');
            $self->buffered_upload_update;
            return;
        }
    }

    # well, we're buffering, but we're not going to disk just yet (but still might)
    $self->state('buffering_request');

    # only need time if we are using the buffer to disk functionality
    $self->{start_time} = [ gettimeofday() ]
        if $self->{service}->{buffer_uploads};
}

# looks at our states and decides if we should start writing to disk
# or should just go ahead and blast this to the backend.  returns 1
# if the decision was made to buffer to disk
sub decide_to_buffer_to_disk {
    my Perlbal::ClientProxy $self = shift;
    return unless $self->{is_buffering};
    return $self->{bureason} if defined $self->{bureason};

    # this is called when we have enough data to determine whether or not to
    # start buffering to disk
    my $dur = tv_interval($self->{start_time}) || 1;
    my $rate = $self->{read_ahead} / $dur;
    my $etime = $self->{content_length_remain} / $rate;

    # see if we have enough data to make the determination
    my $reason = undef;

    # see if we blow the rate away
    if ($self->{service}->{buffer_upload_threshold_rate} > 0 &&
            $rate < $self->{service}->{buffer_upload_threshold_rate}) {
        # they are slower than the minimum rate
        $reason = 'rate';
    }

    # and finally check estimated time exceeding
    if ($self->{service}->{buffer_upload_threshold_time} > 0 &&
            $etime > $self->{service}->{buffer_upload_threshold_time}) {
        # exceeds
        $reason = 'time';
    }

    unless ($reason) {
        $self->{is_buffering} = 0;
        return 0;
    }

    # start saving it to disk
    $self->state('buffering_upload');
    $self->buffered_upload_update;
    $self->{bureason} = $reason;

    if ($ENV{PERLBAL_DEBUG_BUFFERED_UPLOADS}) {
        $self->{req_headers}->header('X-PERLBAL-BUFFERED-UPLOAD-REASON', $reason);
    }

    return 1;
}

# take ourselves and send along our buffered data to the backend
sub send_buffered_upload {
    my Perlbal::ClientProxy $self = shift;

    # make sure our buoutpos is the same as the content length...
    return if $self->{is_writing};

    # set the content-length that goes to the backend...
    if ($self->{chunked_upload_state}) {
        $self->{req_headers}->header("Content-Length", $self->{request_body_length});
    }

    my $clen = $self->{req_headers}->content_length;
    if ($clen != $self->{buoutpos}) {
        Perlbal::log('crit', "Content length of $clen declared but $self->{buoutpos} bytes written to disk");
        return $self->_simple_response(500);
    }

    # reset our position so we start reading from the right spot
    $self->{buoutpos} = 0;
    sysseek($self->{bufh}, 0, 0) if ($self->{bufh}); # But only if it exists at all

    # notify that we want the backend so we get the ball rolling
    $self->request_backend;
}

sub continue_buffered_upload {
    my Perlbal::ClientProxy $self = shift;
    my Perlbal::BackendHTTP $be = shift;
    return unless $self && $be;

    # now send the data
    my $clen = $self->{request_body_length};

    if ($self->{buoutpos} < $clen) {
        my $sent = Perlbal::Socket::sendfile($be->{fd}, fileno($self->{bufh}), $clen - $self->{buoutpos});
        if ($sent < 0) {
            return $self->close("epipe") if $! == EPIPE;
            return $self->close("connreset") if $! == ECONNRESET;
            print STDERR "Error w/ sendfile: $!\n";
            return $self->close('sendfile_error');
        }
        $self->{buoutpos} += $sent;
    }

    # if we're done, purge the file and move on
    if ($self->{buoutpos} >= $clen) {
        $be->{buffered_upload_mode} = 0;
        $self->purge_buffered_upload;
        return;
    }

    # we will be called again by the backend since buffered_upload_mode is on
}

# write data to disk
sub buffered_upload_update {
    my Perlbal::ClientProxy $self = shift;
    # Reading too far ahead of our AIO subsystem will cause us to buffer it in memory.
    $self->watch_read(0) if $self->{read_ahead} >= 1024 * 1024; # arbitrary
    return if $self->{is_writing};
    return unless $self->{is_buffering} && $self->{read_ahead};

    # so we're not writing now and we have data to write...
    unless ($self->{bufilename}) {
        # create a filename and see if it exists or not
        $self->{is_writing} = 1;
        my $fn = join('-', $self->{service}->name, $self->{service}->listenaddr, "client", $self->{fd}, int(rand(0xffffffff)));
        $fn = $self->{service}->{buffer_uploads_path} . '/' . $fn;

        # good, now we need to create the file
        Perlbal::AIO::aio_open($fn, O_CREAT | O_TRUNC | O_RDWR, 0644, sub {
            $self->{is_writing} = 0;
            $self->{bufh} = shift;

            # throw errors back to the user
            if (! $self->{bufh}) {
                Perlbal::log('crit', "Failure to open $fn for buffered upload output");
                return $self->_simple_response(500);
            }

            # save state and info and bounce it back to write data
            $self->{bufilename} = $fn;
            $self->buffered_upload_update;
        });

        return;
    }

    # can't proceed if we have no disk file to async write to
    # people reported seeing this crash rarely in production...
    # must be a race between previously in-flight's write
    # re-invoking a write immediately after something triggered
    # a buffered upload purge.
    unless ($self->{bufh}) {
        $self->close;
        return;
    }

    # at this point, we want to do some writing
    my $bref = \join("", map { $$_ } @{$self->{read_buf}});
    $self->{read_buf} = []; # clear these out
    $self->{read_ahead} = 0;
    my $len = length $$bref;

    # After copying out and clearing the buffer, turn reads back on again to fill up another buffer.
    $self->watch_read(1) if $self->{content_length_remain} || $self->{chunked_upload_state};

    # so at this point we have a valid filename and file handle and should write out
    # the buffer that we have
    $self->{is_writing} = 1;
    Perlbal::AIO::aio_write($self->{bufh}, $self->{buoutpos}, $len, $$bref, sub {
        my $bytes = shift;
        $self->{is_writing} = 0;

        # check for error
        unless ($bytes > 0) {
            Perlbal::log('crit', "Error writing buffered upload: $!.  Tried to do $len bytes at $self->{buoutpos}.");
            return $self->_simple_response(500);
        }

        # update our count of data written
        $self->{buoutpos} += $bytes;

        # now check if we wrote less than we had in this chunk of buffer.  if that's
        # the case then we need to re-enqueue the part of the chunk that wasn't
        # written out and update as appropriate.
        if ($bytes < $len) {
            my $diff = $len - $bytes;
            unshift @{$self->{read_buf}}, \ substr($$bref, $bytes, $diff);
            $self->{read_ahead} += $diff;
        }

        # if we're processing a chunked upload, ...
        if ($self->{chunked_upload_state}) {
            # turn reads back on, if we haven't hit the end yet.
            if ($self->{unread_data_waiting} && $self->{read_ahead} < 1024*1024) {
                $self->watch_read(1);
                $self->{unread_data_waiting} = 0;
            }

            if ($self->{read_ahead} == 0 && $self->{chunked_upload_state}->hit_zero_chunk) {
                $self->watch_read(0);
                $self->send_buffered_upload;
                return;
            }
        }

        # if we're done (no clr and no read ahead!) then send it
        elsif ($self->{read_ahead} <= 0 && $self->{content_length_remain} <= 0) {
            $self->send_buffered_upload;
            return;
        }

        # spawn another writer!
        $self->buffered_upload_update;
    });
}

# destroy any files we've created
sub purge_buffered_upload {
    my Perlbal::ClientProxy $self = shift;

    # Main reason for failure below is a 0-length chunked upload, where the file is never created.
    return unless $self->{bufh};

    # FIXME: it's reported that sometimes the two now-in-eval blocks
    # fail, hence the eval blocks and warnings.  the FIXME is to
    # figure this out, why it happens sometimes.

    # first close our filehandle... not async
    eval {
        CORE::close($self->{bufh});
    };
    if ($@) { warn "Error closing file in ClientProxy::purge_buffered_upload: $@\n"; }

    $self->{bufh} = undef;

    eval {
        # now asynchronously unlink the file
        Perlbal::AIO::aio_unlink($self->{bufilename}, sub {
            if ($_[0] != 0 && $!) {
                # note an error, but whatever, we'll either overwrite the file later (O_TRUNC | O_CREAT)
                # or a cleaner will come through and do it for us someday (if the user runs one)
                Perlbal::log('warning', "Unable to link $self->{bufilename}: $!");
              }
        });
    };
    if ($@) { warn "Error unlinking file in ClientProxy::purge_buffered_upload: $@\n"; }
}

# returns bool; whether backend should hide the 500 error from the client
#   and have us try a new backend.  return true to retry, false to get a 500 error.
sub should_retry_after_500 {
    my Perlbal::ClientProxy $self = shift;
    my Perlbal::BackendHTTP $be   = shift;
    my $svc = $be->{service};
    return 0 unless $svc->{enable_error_retries};
    my @sched = split(/\s*,\s*/, $svc->{error_retry_schedule});
    return 0 if ++$self->{retry_count} > @sched;
    return 1;
}

# called by Backend to tell us it got a 500 error and we should retry another backend.
sub retry_after_500 {
    my Perlbal::ClientProxy $self = shift;
    my Perlbal::Service     $svc  = shift;

    my @sched = split(/\s*,\s*/, $svc->{error_retry_schedule});
    my $delay = $sched[$self->{retry_count} - 1];

    if ($delay) {
        Danga::Socket->AddTimer($delay, sub {
            return if $self->{closed};
            $self->rerequest_backend;
        });
    } else {
        $self->rerequest_backend;
    }

}

sub as_string {
    my Perlbal::ClientProxy $self = shift;

    my $ret = $self->SUPER::as_string;
    if ($self->{backend}) {
        my $ipport = $self->{backend}->{ipport};
        $ret .= "; backend=$ipport";
    } else {
        $ret .= "; write_buf_size=$self->{write_buf_size}"
            if $self->{write_buf_size} > 0;
    }
    $ret .= "; highpri" if $self->{high_priority};
    $ret .= "; lowpri" if $self->{low_priority};
    $ret .= "; responded" if $self->{responded};
    $ret .= "; waiting_for=" . $self->{content_length_remain}
        if defined $self->{content_length_remain};
    $ret .= "; reproxying" if $self->{currently_reproxying};

    return $ret;
}

sub set_queue_low {
    my Perlbal::ClientProxy $self = shift;
    $self->{low_priority} = 1;
    return;
}

sub set_queue_high {
    my Perlbal::ClientProxy $self = shift;
    $self->{high_priority} = 1;
    return;
}


sub DESTROY {
    Perlbal::objdtor($_[0]);
    $_[0]->SUPER::DESTROY;
}

1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
