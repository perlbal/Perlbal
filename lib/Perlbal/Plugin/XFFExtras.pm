package Perlbal::Plugin::XFFExtras;

use strict;
use warnings;

use Danga::Socket 1.53;  # Need newer Danga::Socket than perlbal to have local_port
use Perlbal 1.74;        # is_ssl support was added in 1.74
use Perlbal::BackendHTTP ();
use Perlbal::Service ();

sub load {
    Perlbal::Service::add_tunable(
        send_backend_port => {
            check_role => 'reverse_proxy',
            des => "Send an X-Forwarded-Port header to backends to indicate the peer's remote address",
            check_type => 'bool',
            default => 0,
        }
    );
    Perlbal::Service::add_tunable(
        send_backend_proto => {
            check_role => 'reverse_proxy',
            des => "Send an X-Forwarded-Proto header to backends to indicate the peers connecting protocol",
            check_type => 'bool',
            default => 0,
        }
    );
}

# magical Perlbal hook return value constants
use constant HANDLE_REQUEST             => 0;
use constant IGNORE_REQUEST             => 1;

sub register {
    my ($class, $svc) = @_;

    my $cfg   = $svc->{extra_config}    ||= {};

    $svc->register_hook(XFFExtras => backend_client_assigned => sub {
        my Perlbal::BackendHTTP $be = shift;
        my $hds       = $be->{req_headers};
        my $client    = $be->{client};
        my $client_ip = $client->peer_ip_string;

        my $trusted = $svc->trusted_ip($client_ip);
        my $blind   = $svc->{blind_proxy};
        if (($trusted && !$blind) || !$trusted) {
            if ($cfg->{send_backend_port}) {
                # Danga::Socket has no accessor for the peer_port, so we break object
                # boundaries for now to implement this. Force to integer because D::S
                # also likes to store string error messages in this field too.
                $client->local_ip_string;
                my $local_port = $client->{local_port} + 0;
                $hds->header("X-Forwarded-Port", $local_port);
            }
            if ($cfg->{send_backend_proto}) {
                my $proto = $client->{is_ssl} ? 'https' : 'http';
                $hds->header("X-Forwarded-Proto", $proto);
            }
        }

        return HANDLE_REQUEST;
    });
}

1;

__END__

=head1 NAME

Perlbal::Plugin::XFFExtras - Perlbal plugin that can optionally add an
X-Forwarded-Port and/or X-Forwarded-Proto header to reverse proxied requests.

=head1 SYNOPSIS

    # in perlbal.conf

    LOAD XFFExtra

    CREATE POOL web
        POOL web ADD 10.0.0.1:80

    CREATE SERVICE proxy
        SET role                        = reverse_proxy
        SET listen                      = 0.0.0.0:80
        SET pool                        = web

        SET plugins             = XFFExtras

        SET send_backend_port   = yes
        SET send_backend_proto  = yes
    ENABLE proxy

=head1 DESCRIPTION

This plugin adds optional headers to be sent to backend servers in reverse proxy mode.

=head1 HEADERS

=over 4

=item * B<X-Forwarded-Port>

This header will contain an integer value indicating the port that the peer connected to.
This will correspond to the port number specified on the listen line of the perlbal service
that initially handled the connection.

=item * B<X-Forwarded-Proto>

This header will contain a string indicating the protocol the client connected to perlbal
via. Currently this will be either 'http' or 'https'.

=back

=head1 AUTHOR

Jonathan Steinert, E<lt>hachi@kuiki.netE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012 by Say Media Inc, E<lt>cpan@saymedia.comE<gt>

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself, either Perl version 5.8.6 or, at your option,
any later version of Perl 5 you may have available.

=cut
