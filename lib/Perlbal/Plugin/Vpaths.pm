###########################################################################
# plugin to use with selectors to select by path
#
# this will not play well with the Vhosts plugin or any other selector
# behavior plugins.
#
# this has also not been optimized for huge volume sites.
#
# this allows you to optionally rewrite the URL if you want to do that
# before sending it to the destination service.
#
# example:  VPATH ^/something/(.+)$ = service /\0
#
# that rewrites "/something/foo" to "/foo"
###########################################################################

package Perlbal::Plugin::Vpaths;

use strict;
use warnings;
no  warnings qw(deprecated);

our %Services;  # service_name => $svc

# when "LOAD" directive loads us up
sub load {
    my $class = shift;

    Perlbal::register_global_hook('manage_command.vpath', sub {
        my $mc = shift->parse(qr/^vpath\s+(?:(\w+)\s+)?(\S+)\s*=\s*(\w+)(?:\s+(.+?)\s*)?$/,
                              "usage: VPATH [<service>] <path regex> = <dest_service> [rewrite regex]");
        my ($selname, $regex, $target, $replace) = $mc->args;
        unless ($selname ||= $mc->{ctx}{last_created}) {
            return $mc->err("omitted service name not implied from context");
        }

        my $ss = Perlbal->service($selname);
        return $mc->err("Service '$selname' is not a selector service")
            unless $ss && $ss->{role} eq "selector";

        my $cregex = qr/$regex/;
        return $mc->err("invalid regular expression: '$regex'")
            unless $cregex;

        $ss->{extra_config}->{_vpaths} ||= [];
        push @{$ss->{extra_config}->{_vpaths}}, [ $cregex, $target, $replace ];
  
        return $mc->ok;
    });
    return 1;
}

# unload our global commands, clear our service object
sub unload {
    my $class = shift;

    Perlbal::unregister_global_hook('manage_command.vpath');
    unregister($class, $_) foreach (values %Services);
    return 1;
}

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;
    unless ($svc && $svc->{role} eq "selector") {
        die "You can't load the vpath plugin on a service not of role selector.\n";
    }

    $svc->selector(\&vpath_selector);
    $svc->{extra_config}->{_vpaths} = [];

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

# call back from Service via ClientHTTPBase's event_read calling service->select_new_service(Perlbal::ClientHTTPBase)
sub vpath_selector {
    my Perlbal::ClientHTTPBase $cb = shift;

    my $req = $cb->{req_headers};
    return $cb->_simple_response(404, "Not Found (no reqheaders)") unless $req;

    my $uri = $req->request_uri;
    my $maps = $cb->{service}{extra_config}{_vpaths} ||= {};

    # iterate down the list of paths, find any matches
    foreach my $row (@$maps) {
        my @parts;
        next unless @parts = ($uri =~ /$row->[0]/);

        if ($row->[2]) {
            $uri = $row->[2];
            $uri =~ s/\\(\d)/$parts[$1] || ''/eg;
            $req->set_request_uri($uri);
        }

        my $svc_name = $row->[1];
        my $svc = $svc_name ? Perlbal->service($svc_name) : undef;
        unless ($svc) {
            $cb->_simple_response(404, "Not Found ($svc_name not a defined service)");
            return 1;
        }

        $svc->adopt_base_client($cb);
        return 1;
    }

    return 0;
}

1;
