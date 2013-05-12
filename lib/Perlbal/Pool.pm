######################################################################
# Pool class
######################################################################
#
# Copyright 2004, Danga Interactive, Inc.
# Copyright 2005-2007, Six Apart, Ltd.
#

package Perlbal::Pool;
use strict;
use warnings;

use Perlbal::BackendHTTP;

# how often to reload the nodefile
use constant NODEFILE_RELOAD_FREQ => 3;

# balance methods we support (note: sendstats mode is now removed)
use constant BM_ROUNDROBIN => 2;
use constant BM_RANDOM => 3;

use fields (
            'name',            # string; name of this pool
            'use_count',       # int; number of services using us
            'nodes',           # arrayref; [ip, port] values (port defaults to 80)
            'node_count',      # int; number of nodes
            'node_used',       # hashref; { ip:port => use count }
            'balance_method',  # int; BM_ constant from above

            # used in nodefile mode
            'nodefile',           # string; filename to read nodes from
            'nodefile.lastmod',   # unix time nodefile was last modified
            'nodefile.lastcheck', # unix time nodefile was last stated
            'nodefile.checking',  # boolean; if true AIO is stating the file for us
            'waiting_services',   # a hash of services waiting for this pool
            );

sub new {
    my Perlbal::Pool $self = shift;
    $self = fields::new($self) unless ref $self;

    my ($name) = @_;

    $self->{name} = $name;
    $self->{use_count} = 0;

    $self->{nodes} = [];
    $self->{node_count} = 0;
    $self->{node_used} = {};

    $self->{nodefile} = undef;
    $self->{balance_method} = BM_RANDOM;
	$self->{waiting_services} = {};

    return $self;
}

sub set {
    my Perlbal::Pool $self = shift;

    my ($key, $val, $mc) = @_;
    my $set = sub { $self->{$key} = $val; return $mc->ok; };

    if ($key eq 'nodefile') {
        # allow to unset it, which stops us from checking it further,
        # but doesn't clear our current list of nodes
        if ($val =~ /^(?:none|undef|null|""|'')$/) {
            $self->{'nodefile'} = undef;
            $self->{'nodefile.lastmod'} = 0;
            $self->{'nodefile.checking'} = 0;
            $self->{'nodefile.lastcheck'} = 0;
            return $mc->ok;
        }

        # enforce that it exists from here on out
        return $mc->err("File not found")
            unless -e $val;

        # force a reload
        $self->{'nodefile'} = $val;
        $self->{'nodefile.lastmod'} = 0;
        $self->{'nodefile.checking'} = 0;
        $self->load_nodefile;
        $self->{'nodefile.lastcheck'} = time;
        return $mc->ok;
    }

    if ($key eq "balance_method") {
        $val = {
            'random' => BM_RANDOM,
        }->{$val};
        return $mc->err("Unknown balance method")
            unless $val;
        return $set->();
    }

}

sub dumpconfig {
    my Perlbal::Pool $self = shift;
    my $name = $self->{name};

    my @return;

    if (my $nodefile = $self->{'nodefile'}) {
        push @return, "SET nodefile = $nodefile";
    } else {
        foreach my $node (@{$self->{nodes}}) {
            my ($ip, $port) = @$node;
            push @return, "POOL ADD $name $ip:$port";
        }
    }
    return @return;
}

# returns string of balance method
sub balance_method {
    my Perlbal::Pool $self = $_[0];
    my $methods = {
        &BM_ROUNDROBIN => "round_robin",
        &BM_RANDOM => "random",
    };
    return $methods->{$self->{balance_method}} || $self->{balance_method};
}

sub load_nodefile {
    my Perlbal::Pool $self = shift;
    return 0 unless $self->{'nodefile'};

    if ($Perlbal::OPTMOD_LINUX_AIO) {
        return $self->_load_nodefile_async;
    } else {
        return $self->_load_nodefile_sync;
    }
}

sub _parse_nodefile {
    my Perlbal::Pool $self = shift;
    my $dataref = shift;

    my @nodes = split(/\r?\n/, $$dataref);

    # prepare for adding nodes
    $self->{nodes} = [];
    $self->{node_used} = {};

    foreach (@nodes) {
        s/\#.*//;
        if (/(\d+\.\d+\.\d+\.\d+)(?::(\d+))?/) {
            my ($ip, $port) = ($1, $2);
            $port ||= 80;
            $self->{node_used}->{"$ip:$port"} ||= 0; # set to 0 if not set
            push @{$self->{nodes}}, [ $ip, $port ];
        }
    }

    # setup things using new data
    $self->{node_count} = scalar @{$self->{nodes}};
}

sub _load_nodefile_sync {
    my Perlbal::Pool $self = shift;

    my $mod = (stat($self->{nodefile}))[9];
    return if $mod == $self->{'nodefile.lastmod'};
    $self->{'nodefile.lastmod'} = $mod;

    open NODEFILE, $self->{nodefile} or return;
    my $nodes;
    { local $/ = undef; $nodes = <NODEFILE>; }
    close NODEFILE;
    $self->_parse_nodefile(\$nodes);
}

sub _load_nodefile_async {
    my Perlbal::Pool $self = shift;

    return if $self->{'nodefile.checking'};
    $self->{'nodefile.checking'} = 1;

    Perlbal::AIO::aio_stat($self->{nodefile}, sub {
        $self->{'nodefile.checking'} = 0;

        # this might have gotten unset while we were out statting the file, which
        # means that the user has instructed us not to use a node file, and may
        # have changed the nodes in the pool, so we should do nothing and return
        return unless $self->{'nodefile'};

        # ignore if the file doesn't exist
        return unless -e _;

        my $mod = (stat(_))[9];
        return if $mod == $self->{'nodefile.lastmod'};
        $self->{'nodefile.lastmod'} = $mod;

        # construct a filehandle (we only have a descriptor here)
        open NODEFILE, $self->{nodefile}
            or return;
        my $nodes;
        { local $/ = undef; $nodes = <NODEFILE>; }
        close NODEFILE;

        $self->_parse_nodefile(\$nodes);
        return;
    });

    return 1;
}

sub add {
    my Perlbal::Pool $self = shift;
    my ($ip, $port) = @_;

    $self->remove($ip, $port); # no dupes

    $self->{node_used}->{"$ip:$port"} = 0;
    push @{$self->{nodes}}, [ $ip, $port ];
    $self->{node_count} = scalar(@{$self->{nodes}});

	if ($self->{waiting_services}) {
		foreach my $service (values %{$self->{waiting_services}}) {
			next unless $service;
			delete $self->{waiting_services}->{$service->{name}};
			if ($service->{waiting_client_count} >0) {
				Perlbal::log('info', "Pool $self->{name} was added much needed node. Now has " . $self->node_count . " nodes");
				$service->spawn_backends;
				last; # We only have enough for one.
			}
		}
	}
}

sub remove {
    my Perlbal::Pool $self = shift;
    my ($ip, $port) = @_;

    delete $self->{node_used}->{"$ip:$port"};
    @{$self->{nodes}} = grep { "$_->[0]:$_->[1]" ne "$ip:$port" } @{$self->{nodes}};
    $self->{node_count} = scalar(@{$self->{nodes}});
}

sub get_backend_endpoint {
    my Perlbal::Pool $self = $_[0];

    my @endpoint;  # (IP,port)

    # re-load nodefile if necessary
    if ($self->{nodefile}) {
        my $now = time;
        if ($now > $self->{'nodefile.lastcheck'} + NODEFILE_RELOAD_FREQ) {
            $self->{'nodefile.lastcheck'} = $now;
            $self->load_nodefile;
        }
    }

    # no nodes?
    return () unless $self->{node_count};

    # pick one randomly
    return @{$self->{nodes}[int(rand($self->{node_count}))]};
}

sub backend_should_live {
    my Perlbal::Pool $self = $_[0];
    my Perlbal::BackendHTTP $be = $_[1];

    # a backend stays alive if we still have users.  eventually this whole
    # function might do more and actually take into account the individual
    # backend, but for now, this suits us.
    return 1 if $self->{use_count};
    return 0;
}

sub node_count {
    my Perlbal::Pool $self = $_[0];
    return $self->{node_count};
}

sub nodes {
    my Perlbal::Pool $self = $_[0];
    return $self->{nodes};
}

sub node_used {
    my Perlbal::Pool $self = $_[0];
    return $self->{node_used}->{$_[1]};
}

sub mark_node_used {
    my Perlbal::Pool $self = $_[0];
    $self->{node_used}->{$_[1]}++;
}

sub increment_use_count {
    my Perlbal::Pool $self = $_[0];
    $self->{use_count}++;
}

sub decrement_use_count {
    my Perlbal::Pool $self = $_[0];
    $self->{use_count}--;
}

sub name {
    my Perlbal::Pool $self = $_[0];
    return $self->{name};
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
