use strict;
use warnings;

use Test::More tests => 5;    # last test to print

for my $class (qw/Perlbal Perlbal::Service/) {
    use_ok( $class, "can load module $class" );
}

my $class = 'Perlbal::Service';

subtest 'module checking' => sub {
    isa_ok( $class->new(), $class, "can create object from $class" );
};

my @words = generate_words(1000);

subtest 'check sub integrity' => sub {
    is_deeply( test_optimized(), test_original(), "sub optimized" );
    is_deeply( test_hash(),      test_original(), "sub hash" );
};

SKIP: {
    skip "need Benchmark module", 1 unless eval "require Benchmark";

    subtest 'benchmark bool sub' => sub {
        use_ok('Benchmark');
        timethese(
            shift || 100000,
            {
                'void' => sub {
                    map { 1 } @words;
                },
                'original'  => \&test_original,
                'optimized' => \&test_optimized,
                'hash'      => \&test_hash,
            }
        );
    };

}

done_testing();

# helpers

sub test_original {
    map { _bool_original($_) } @words;
}

sub test_optimized {
    map { _bool_optimized($_) } @words;
}

sub test_hash {
    map { Perlbal::Service::_bool($_) } @words;
}

sub _bool_original {
    my $val = shift;

    return unless defined $val;

    return 1 if $val =~ /^1|true|on|yes$/i;
    return 0 if $val =~ /^0|false|off|no$/i;
    return undef;
}

{

    # should use state
    my $qr_on;
    my $qr_off;

    sub _bool_optimized {
        my $val = shift;

        return unless defined $val;

        $qr_on  = qr/^1|true|on|yes$/i  unless defined $qr_on;
        $qr_off = qr/^0|false|off|no$/i unless defined $qr_off;

        return 1 if $val =~ $qr_on;
        return 0 if $val =~ $qr_off;
        return undef;
    }
}

sub generate_words {
    my $n = shift || 10;
    my @words = qw/1 true on yes 0 false off no/;

    my $reply = [];

    for ( 1 .. $n ) {
        my $w = $words[ int rand( scalar @words ) ];

        if ( rand(3) > 1 ) {
            if ( rand(2) > 1 ) {
                $w = uc($w);
            }
            else {
                my $l = length $w;
                for my $c ( 1 .. $l ) {
                    next if ( rand(2) > 1 );
                    substr( $w, $c - 1, 1 ) = uc( getn_substr( $w, $c ) );
                }
            }
        }
        push( @$reply, $w );
    }

    return $reply;
}

sub getn_substr {
    return substr $_[0], $_[1] - 1, 1;
}

