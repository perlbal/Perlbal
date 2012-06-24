use strict;
use warnings;
use Carp;

use Test::More 0.94 tests => 6;    # last test to print
use Hash::Util;

my $warn_mocked =
  "mocked by perlbal, this error should not be raised using Perlbal::Fields";
{
    no warnings 'redefine';
    *Hash::Util::lock_ref_keys = sub { croak $warn_mocked; };
}

SKIP: {
    skip "perl need to be greater than 5.009", 1 if ( $] < 5.009 );

    subtest 'before using Perlbal::Fields' => sub {
        use_ok('Perlbal::CommandContext');
        eval { Perlbal::CommandContext->new(); };
        like( $@, qr{$warn_mocked}, "use old library" );
        done_testing();
    };
}

my $class = 'Perlbal::Fields';
use_ok( $class, "can load module $class" );
ok( $class->run(), "run method" );

isa_ok( Perlbal::Test::Fields->new(),
    'Perlbal::Test::Fields', "can create object" );
use_ok('Perlbal::CommandContext');
isa_ok( Perlbal::CommandContext->new(),
    'Perlbal::CommandContext', "can create object" );

done_testing();
1;

package Perlbal::Test::Fields;
use fields ( 'headers', 'origcase' );

sub new {
    my Perlbal::Test::Fields $self = shift;
    $self = fields::new($self) unless ref $self;

    return $self;
}

1;
