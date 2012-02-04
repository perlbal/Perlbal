###########################################################################
# plugin to do name-based virtual hosts
###########################################################################

# things to test:
#   one persistent connection, first to a docs plugin, then to web proxy... see if it returns us to our base class after end of request
#   PUTing a large file to a selector, seeing if it is put correctly to the PUT-enabled web_server proxy
#   obvious cases:  non-existent domains, default domains (*), proper matching (foo.brad.lj before *.brad.lj)
#

package Perlbal::Plugin::Vhosts;

use strict;
use warnings;
no  warnings qw(deprecated);

our %Services;  # service_name => $svc

# when "LOAD" directive loads us up
sub load {
    my $class = shift;

    Perlbal::register_global_hook('manage_command.vhost', sub {
        my $mc = shift->parse(qr/^vhost\s+(?:(\w+)\s+)?(\S+)\s*=\s*(\w+)$/,
                              "usage: VHOST [<service>] <host_or_pattern> = <dest_service>");
        my ($selname, $host, $target) = $mc->args;
        unless ($selname ||= $mc->{ctx}{last_created}) {
            return $mc->err("omitted service name not implied from context");
        }

        my $ss = Perlbal->service($selname);
        return $mc->err("Service '$selname' is not a selector service")
            unless $ss && $ss->{role} eq "selector";

        $host = lc $host;
        return $mc->err("invalid host pattern: '$host'")
            unless $host =~ /^[\w\-\_\.\*\;\:]+$/;

        $ss->{extra_config}->{_vhosts} ||= {};
        $ss->{extra_config}->{_vhosts}{$host} = $target;

        return $mc->ok;
    });
    return 1;
}

# unload our global commands, clear our service object
sub unload {
    my $class = shift;

    Perlbal::unregister_global_hook('manage_command.vhost');
    unregister($class, $_) foreach (values %Services);
    return 1;
}

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;
    unless ($svc && $svc->{role} eq "selector") {
        die "You can't load the vhost plugin on a service not of role selector.\n";
    }

    $svc->selector(\&vhost_selector);
    $svc->{extra_config}->{_vhosts} = {};

    $Services{"$svc"} = $svc;
    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;
    $svc->selector(undef);
    delete $Services{"$svc"};
    return 1;
}

sub dumpconfig {
    my ($class, $svc) = @_;

    my $vhosts = $svc->{extra_config}->{_vhosts};

    return unless $vhosts;

    my @return;

    while (my ($vhost, $target) = each %$vhosts) {
        push @return, "VHOST $vhost = $target";
    }

    return @return;
}

# call back from Service via ClientHTTPBase's event_read calling service->select_new_service(Perlbal::ClientHTTPBase)
sub vhost_selector {
    my Perlbal::ClientHTTPBase $cb = shift;

    my $req = $cb->{req_headers};
    return $cb->_simple_response(404, "Not Found (no reqheaders)") unless $req;

    my $vhost = $req->header("Host");

    my $uri = $req->request_uri;
    my $maps = $cb->{service}{extra_config}{_vhosts} ||= {};

    # returns 1 if done with client, 0 if no action taken
    my $map_using = sub {
        my ($match_on, $force) = @_;

        my $map_name = $maps->{$match_on};
        my $svc = $map_name ? Perlbal->service($map_name) : undef;

        return 0 unless $svc || $force;

        unless ($svc) {
            $cb->_simple_response(404, "Not Found (no configured vhost)");
            return 1;
        }

        $svc->adopt_base_client($cb);
        return 1;
    };

    #  foo.site.com  should match:
    #      foo.site.com
    #    *.foo.site.com  -- this one's questionable, but might as well?
    #        *.site.com
    #        *.com
    #        *

    # if no vhost, just try the * mapping
    return $map_using->("*", 1) unless $vhost;

    # Strip off the :portnumber, if any
    $vhost =~ s/:\d+$//;

    # Browsers and the Apache API considers 'www.example.com.' == 'www.example.com'
    $vhost and $vhost =~ s/\.$//;

    # ability to ask for one host, but actually use another.  (for
    # circumventing javascript/java/browser host restrictions when you
    # actually control two domains).
    if ($vhost && $uri =~ m!^/__using/([\w\.]+)(?:/\w+)(?:\?.*)?$!) {
        my $alt_host = $1;

        # update our request object's Host header, if we ended up switching them
        # around with /__using/...
        my $svc_name = $maps->{"$vhost;using:$alt_host"};
        my $svc = $svc_name ? Perlbal->service($svc_name) : undef;
        unless ($svc) {
            $cb->_simple_response(404, "Vhost twiddling not configured for requested pair.");
            return 1;
        }

        $req->header("Host", $alt_host);
        $svc->adopt_base_client($cb);
        return 1;
    }

    # try the literal mapping
    return if $map_using->($vhost);

    # and now try wildcard mappings, removing one part of the domain
    # at a time until we find something, or end up at "*"

    # first wildcard, prepending the "*."
    my $wild = "*.$vhost";
    return if $map_using->($wild);

    # now peel away subdomains
    while ($wild =~ s/^\*\.[\w\-\_]+/*/) {
        return if $map_using->($wild);
    }

    # last option: use the "*" wildcard
    return $map_using->("*", 1);
}

1;
