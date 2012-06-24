=head1 NAME

Perlbal::Plugin::FlvStreaming - Enable FLV streaming with reverse proxy

=head1 DESCRIPTION

This plugin enable FLV streaming by modifying headers and prepending
FLV header to the body.

=head1 SYNOPSIS

    LOAD FlvStreaming
    
    CREATE SERVICE flv_proxy
      SET role    = reverse_proxy
      SET plugins = FlvStreaming
    ENABLE flv_proxy


=head1 LICENSE

This plugin is part of the Perlbal distribution, and as such can be
distributed under the same licence terms as the rest of Perlbal.

=cut

package Perlbal::Plugin::FlvStreaming;

use strict;
use warnings;
use URI;
use URI::QueryParam;

my  $FLV_HEADER = 'FLV' . pack('CCNN', 1, 1, 9, 9);

sub load { }

sub register {
    my ($class, $svc) = @_;
    unless ($svc && $svc->{role} eq "reverse_proxy") {
        die "You can't load the flvstreaming plugin on a service not of role reverse_proxy.\n";
    }

    $svc->register_hook('FlvStreaming', 'start_proxy_request',     \&start_proxy_request);
    $svc->register_hook('FlvStreaming', 'modify_response_headers', \&modify_response_headers);
    $svc->register_hook('FlvStreaming', 'prepend_body',            \&prepend_body);

    return 1;
}

sub start_proxy_request {
    my Perlbal::ClientProxy $client = shift;

    my $uri  = URI->new( $client->{req_headers}->{uri} );
    my $path = $uri->path;
    return 0 if $path !~ /\.flv$/;

    my $start = $uri->query_param('start');
    return 0 unless $start;

    $client->{req_headers}->header('range', "bytes=$start-");
    Perlbal::log('debug', "FlvStreaming: $uri") if Perlbal::DEBUG;
    Perlbal::log('debug', "FlvStreaming: Add request header 'Range: bytes=$start-'") if Perlbal::DEBUG;
    return 0;
}

sub modify_response_headers {
    my Perlbal::BackendHTTP $be     = shift;
    my Perlbal::ClientProxy $client = shift;

    my $headers = $client->{res_headers};

    my $uri  = URI->new( $client->{req_headers}->{uri} );
    my $path = $uri->path;
    return 0 if $path !~ /\.flv$/;

    my $start = $uri->query_param('start');
    return 0 unless $start;

    $headers->{responseLine}   = 'HTTP/1.0 200 OK';
    $headers->{code}           = '200';

    delete $headers->{headers}->{'accept-ranges'};
    delete $headers->{headers}->{'content-range'};

    $headers->{headers}->{'content-type'}    = 'video/x-flv';
    $headers->{headers}->{'content-length'} += length $FLV_HEADER;

    return 0;
}

sub prepend_body {
    my Perlbal::BackendHTTP $be     = shift;
    my Perlbal::ClientProxy $client = shift;

    my $uri  = URI->new( $client->{req_headers}->{uri} );
    my $path = $uri->path;
    return 0 if $path !~ /\.flv$/;

    my $start = $uri->query_param('start');
    return 0 unless $start;

    $client->write($FLV_HEADER);
    return 0;
}

1;
