# Base class for all socket types
#
# Copyright 2004, Danga Interactive, Inc.
# Copyright 2005-2007, Six Apart, Ltd.

package Perlbal::Socket;
use strict;
use warnings;
no  warnings qw(deprecated);

use Perlbal::HTTPHeaders;

use Sys::Syscall;
use POSIX ();

use Danga::Socket 1.44;
use base 'Danga::Socket';

use fields (
            'headers_string',  # headers as they're being read

            'req_headers',     # the final Perlbal::HTTPHeaders object inbound
            'res_headers',     # response headers outbound (Perlbal::HTTPHeaders object)

            'create_time',     # creation time
            'alive_time',      # last time noted alive
            'state',           # general purpose state; used by descendants.
            'do_die',          # if on, die and do no further requests

            'read_buf',        # arrayref of scalarref read from client
            'read_ahead',      # bytes sitting in read_buf
            'read_size',       # total bytes read from client, ever

            'ditch_leading_rn', # if true, the next header parsing will ignore a leading \r\n

            'observed_ip_string', # if defined, contains the observed IP string of the peer
                                  # we're serving. this is intended for holding the value of
                                  # the X-Forwarded-For and using it to govern ACLs.
            );

use constant MAX_HTTP_HEADER_LENGTH => 102400;  # 100k, arbitrary

use constant TRACK_OBJECTS => 0;            # see @created_objects below
if (TRACK_OBJECTS) {
    use Scalar::Util qw(weaken isweak);
}

# kick-off one cleanup
_do_cleanup();

our %state_changes = (); # { "objref" => [ state, state, state, ... ] }
our $last_callbacks = 0; # time last ran callbacks
our $callbacks = []; # [ [ time, subref ], [ time, subref ], ... ]

# this one deserves its own section.  we keep track of every Perlbal::Socket object
# created if the TRACK_OBJECTS constant is on.  we use weakened references, though,
# so this list will hopefully contain mostly undefs.  users can ask for this list if
# they want to work with it via the get_created_objects_ref function.
our @created_objects; # ( $ref, $ref, $ref ... )
our $last_co_cleanup = 0; # clean the list every few seconds

sub get_statechange_ref {
    return \%state_changes;
}

sub get_created_objects_ref {
    return \@created_objects;
}

sub write_debuggy {
    my $self = shift;

    my $cref = $_[0];
    my $content = ref $cref eq "SCALAR" ? $$cref : $cref;
    my $clen = defined $content ? length($content) : "undef";
    $content = substr($content, 0, 17) . "..." if defined $content && $clen > 30;
    my ($pkg, $filename, $line) = caller;
    print "write($self, <$clen>\"$content\") from ($pkg, $filename, $line)\n" if Perlbal::DEBUG >= 4;
    $self->SUPER::write(@_);
}

if (Perlbal::DEBUG >= 4) {
    no warnings 'redefine';
    *write = \&write_debuggy;
}

sub new {
    my Perlbal::Socket $self = shift;
    $self = fields::new( $self ) unless ref $self;

    Perlbal::objctor($self);

    $self->SUPER::new( @_ );
    $self->{headers_string} = '';
    $self->{state} = undef;
    $self->{do_die} = 0;

    $self->{read_buf} = [];        # arrayref of scalar refs of bufs read from client
    $self->{read_ahead} = 0;       # bytes sitting in read_buf
    $self->{read_size} = 0;        # total bytes read from client

    my $now = time;
    $self->{alive_time} = $self->{create_time} = $now;

    # now put this item in the list of created objects
    if (TRACK_OBJECTS) {
        # clean the created objects list if necessary
        if ($last_co_cleanup < $now - 5) {
            # remove out undefs, because those are natural byproducts of weakening
            # references
            @created_objects = grep { $_ } @created_objects;

            # however, the grep turned our weak references back into strong ones, so
            # we have to re-weaken them
            weaken($_) foreach @created_objects;

            # we've cleaned up at this point
            $last_co_cleanup = $now;
        }

        # now add this one to our cleaned list and weaken it
        push @created_objects, $self;
        weaken($created_objects[-1]);
    }

    return $self;
}

# We need to maintain a cache of socket classes and what cleanup
# handler (if any) we perform on them. This is because classes based
# on Perlbal::Socket get one method, and Perlbal::SocketSSL gets a
# different handler. Caching this information is done rather than a
# static list because you can make new client classes in Perlbal.

# If perl cached ->isa($class) call results we can make this shorter.
my %class_isa_cache;

# A list of socket classes that we are interested in, listed in
# the order which they should be probed for.
my %socket_class_handlers = (
    'Perlbal::Socket' => sub {
        my Perlbal::Socket $v = shift;

        my $max_age = eval { $v->max_idle_time } || 0;
        return unless $max_age;

        # We're inside the class where ->{alive_time} is defined, safe to use.
        $v->close("perlbal_timeout")
            if $v->{alive_time} < $Perlbal::tick_time - $max_age;
    },
);

sub set_socket_idle_handler {
    my $class = shift;
    my $handler_class = shift;
    my $handler = shift;
    $socket_class_handlers{$handler_class} = $handler;
}

# FIXME: this doesn't scale in theory, but it might use less CPU in
# practice than using the Heap:: modules and manipulating the
# expirations all the time, thus doing things properly
# algorithmically.  and this is definitely less work, so it's worth
# a try.

sub _do_cleanup {
    my $sf = Perlbal::Socket->get_sock_ref;

    SOCKET: while (my $k = each %$sf) {
        my $sock = $sf->{$k};
        my $sock_class = ref $sf->{$k};
        if (exists $class_isa_cache{$sock_class}) {
            my $handler = $class_isa_cache{$sock_class};
            next unless defined $handler;
            $handler->($sock);
            next SOCKET;
        }

        # No entry in the cache, find out what handler we should assign.
        my $handler;
        foreach my $check_class (keys %socket_class_handlers) {
            next unless $sock->isa($check_class);
            $handler = $socket_class_handlers{$check_class};
            last;
        }
        # Outside the loop, so that we assign undef if none of the loop passes find anything.
        $class_isa_cache{$sock_class} = $handler;
    }

    Danga::Socket->AddTimer(5, \&_do_cleanup);
}

# CLASS METHOD: given a delay (in seconds) and a subref, this will call
# that subref in AT LEAST delay seconds. if the subref returns 0, the
# callback is discarded, but if it returns a positive number, the callback
# is pushed onto the callback stack to be called again in at least that
# many seconds.
sub register_callback {
    # adds a new callback to our list
    my ($delay, $subref) = @_;
    push @$callbacks, [ time + $delay, $subref ];
    return 1;
}

# CLASS METHOD: runs through the list of registered callbacks and executes
# any that need to be executed
# FIXME: this doesn't scale.  need a heap.
sub run_callbacks {
    my $now = time;
    return if $last_callbacks == $now;
    $last_callbacks = $now;

    my @destlist = ();
    foreach my $ref (@$callbacks) {
        # if their time is <= now...
        if ($ref->[0] <= $now) {
            # find out if they want to run again...
            my $rv = $ref->[1]->();

            # and if they do, push onto list...
            push @destlist, [ $rv + $now, $ref->[1] ]
                if defined $rv && $rv > 0;
        } else {
            # not time for this one, just shove it
            push @destlist, $ref;
        }
    }
    $callbacks = \@destlist;
}

# CLASS METHOD:
# default is for sockets to never time out.  classes
# can override.
sub max_idle_time { 0; }

# Socket: specific to HTTP socket types (only here and not in
# ClientHTTPBase because ClientManage wants it too)
sub read_request_headers  { read_headers($_[0], 0); }
sub read_response_headers { read_headers($_[0], 1); }
sub read_headers {
    my Perlbal::Socket $self = shift;
    my $is_res = shift;
    print "Perlbal::Socket::read_headers($self) is_res=$is_res\n" if Perlbal::DEBUG >= 2;

    my $sock = $self->{sock};

    my $to_read = MAX_HTTP_HEADER_LENGTH - length($self->{headers_string});

    my $bref = $self->read($to_read);
    unless (defined $bref) {
        # client disconnected
        print "  client disconnected\n" if Perlbal::DEBUG >= 3;
        return $self->close('remote_closure');
    }

    $self->{headers_string} .= $$bref;
    my $idx = index($self->{headers_string}, "\r\n\r\n");
    my $delim_len = 4;

    # can't find the header delimiter? check for LFLF header delimiter.
    if ($idx == -1) {
        $idx = index($self->{headers_string}, "\n\n");
        $delim_len = 2;
    }
    # still can't find the header delimiter?
    if ($idx == -1) {

        # usually we get the headers all in one packet (one event), so
        # if we get in here, that means it's more than likely the
        # extra \r\n and if we clean it now (throw it away), then we
        # can avoid a regexp later on.
        if ($self->{ditch_leading_rn} && $self->{headers_string} eq "\r\n") {
            print "  throwing away leading \\r\\n\n" if Perlbal::DEBUG >= 3;
            $self->{ditch_leading_rn} = 0;
            $self->{headers_string}   = "";
            return 0;
        }

        print "  can't find end of headers\n" if Perlbal::DEBUG >= 3;
        $self->close('long_headers')
            if length($self->{headers_string}) >= MAX_HTTP_HEADER_LENGTH;
        return 0;
    }

    my $hstr = substr($self->{headers_string}, 0, $idx);
    print "  pre-parsed headers: [$hstr]\n" if Perlbal::DEBUG >= 3;

    my $extra = substr($self->{headers_string}, $idx+$delim_len);
    if (my $len = length($extra)) {
        print "  pushing back $len bytes after header\n" if Perlbal::DEBUG >= 3;
        $self->push_back_read(\$extra);
    }

    # some browsers send an extra \r\n after their POST bodies that isn't
    # in their content-length.  a base class can tell us when they're
    # on their 2nd+ request after a POST and tell us to be ready for that
    # condition, and we'll clean it up
    $hstr =~ s/^\r\n// if $self->{ditch_leading_rn};

    unless (($is_res ? $self->{res_headers} : $self->{req_headers}) =
                Perlbal::HTTPHeaders->new(\$hstr, $is_res)) {
        # bogus headers?  close connection.
        print "  bogus headers\n" if Perlbal::DEBUG >= 3;
        return $self->close("parse_header_failure");
    }

    print "  got valid headers\n" if Perlbal::DEBUG >= 3;

    $Perlbal::reqs++ unless $is_res;
    $self->{ditch_leading_rn} = 0;

    return $is_res ? $self->{res_headers} : $self->{req_headers};
}

### METHOD: drain_read_buf_to( $destination )
### Write read-buffered data (if any) from the receiving object to the
### I<destination> object.
sub drain_read_buf_to {
    my ($self, $dest) = @_;
    return unless $self->{read_ahead};

    while (my $bref = shift @{$self->{read_buf}}) {
        print "draining readbuf from $self to $dest: [$$bref]\n" if Perlbal::DEBUG >= 3;
        $dest->write($bref);
        $self->{read_ahead} -= length($$bref);
    }
}

### METHOD: die_gracefully()
### By default, if we're in persist_wait state, close.  Else, ignore.  Children
### can override if they want to do some other processing.
sub die_gracefully {
    my Perlbal::Socket $self = $_[0];
    if (defined $self->state && $self->state eq 'persist_wait') {
        $self->close('graceful_shutdown');
    }
    $self->{do_die} = 1;
}

### METHOD: write()
### Overridden from Danga::Socket to update our alive time on successful writes
### Stops sockets from being closed on long-running write operations
sub write {
    my $self = shift;

    my $ret;
    if ($ret = $self->SUPER::write(@_)) {
        # Mark this socket alive so we don't time out
        $self->{alive_time} = $Perlbal::tick_time;
    }

    return $ret;
}

### METHOD: close()
### Set our state when we get closed.
sub close {
    my Perlbal::Socket $self = $_[0];
    $self->state('closed');
    return $self->SUPER::close($_[1]);
}

### METHOD: state()
### If you pass a parameter, sets the state, else returns it.
sub state {
    my Perlbal::Socket $self = shift;
    return $self->{state} unless @_;

    push @{$state_changes{"$self"} ||= []}, $_[0] if Perlbal::TRACK_STATES;
    return $self->{state} = $_[0];
}

sub observed_ip_string {
    my Perlbal::Socket $self = shift;

    if (@_) {
        return $self->{observed_ip_string} = $_[0];
    } else {
        return $self->{observed_ip_string};
    }
}

sub as_string_html {
    my Perlbal::Socket $self = shift;
    return $self->SUPER::as_string;
}

sub DESTROY {
    my Perlbal::Socket $self = shift;
    delete $state_changes{"$self"} if Perlbal::TRACK_STATES;
    Perlbal::objdtor($self);
}

# package function (not a method).  returns bytes sent, or -1 on error.
our $sf_defined = Sys::Syscall::sendfile_defined;
our $max_sf_readwrite = 128 * 1024;
sub sendfile {
    my ($sfd, $fd, $bytes) = @_;
    return Sys::Syscall::sendfile($sfd, $fd, $bytes) if $sf_defined;

    # no support for sendfile.  ghetto version:  read and write.
    my $buf;
    $bytes = $max_sf_readwrite if $bytes > $max_sf_readwrite;

    my $rv = POSIX::read($fd, $buf, $bytes);
    return -1 unless defined $rv;
    return -1 unless $rv == $bytes;

    my $wv = POSIX::write($sfd, $buf, $rv);
    return -1 unless defined $wv;

    if (my $over_read = $rv - $wv) {
        POSIX::lseek($fd, -$over_read, &POSIX::SEEK_CUR);
    }

    return $wv;
}

1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
