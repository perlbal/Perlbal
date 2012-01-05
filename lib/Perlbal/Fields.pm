package Perlbal::Fields;
use strict;
use warnings;
use fields;

# allow package to be called in command line
__PACKAGE__->run(@ARGV) unless caller();

# should be the main method called, extra sub could be triggered from this point
sub run {
    my ( $package, @options ) = @_;

    # unactivate fields if launch in command line
    $package->remove();

    1;
}

# hash with keys and undef val for each class
my $cache_for_class = {};

# replace fields::new method which uses Hash::Util::lock_ref_keys
# - it's a good idea to keep using the original fields::new during development stage
# - but during production we can avoid locking hash and wasting time doing this ( ~ 30 % )
sub remove {
    my ($class) = @_;

    no warnings "redefine";
    no strict 'refs';
    *fields::new = sub {
        my $class = shift;
        $class = ref $class if ref $class;

        if ( !defined( $cache_for_class->{$class} ) ) {
            my $h    = {};
            my @keys = keys %{ $class . "::FIELDS" };
            map { $h->{$_} = undef; } @keys;
            $cache_for_class->{$class} = $h;
        }
        my %h = %{ $cache_for_class->{$class} };

        return bless \%h, $class;
    };
}

1;

