package Salvation::Method::Signatures;

=head1 NAME

Salvation::Method::Signatures - Реализация сигнатур для методов

=head1 SYNOPSIS

    package Some::Package;

    use Salvation::Method::Signatures;
    # use Test::More tests => 3;

    method process( ArrayRef[ArrayRef[Str]] :flags!, ArrayRef[HashRef(Int :id!)] :data! ) {

        # isa_ok( $self, 'Some::Package' );
        # is_deeply( $flags, [ [ 'something' ] ] );
        # is_deeply( $data, [ { id => 1 } ] );

        ...
    }

    package main;

    Some::Package -> process(
        flags => [ [ 'something' ] ],
        data => [ { id => 1 } ],
    );

=head1 DESCRIPTION

Делает то же, что делают другие реализации сигнатур: проверяет тип аргументов
метода, само разбирает C<@_> и инжектит переменные в блок.

=head1 SEE ALSO

http://perlcabal.org/syn/S06.html#Signatures
L<MooseX::Method::Signatures>
L<Method::Signatures>

=cut

use strict;
use warnings;
use boolean;

use Module::Load 'load';

use base 'Devel::Declare::MethodInstaller::Simple';

our $VERSION = 0.01;

=head1 METHODS

=cut

=head2 type_system_class()

=cut

sub type_system_class {

    return 'Salvation::TC';
}

=head2 token_str()

=cut

sub token_str {

    return 'method';
}

=head2 self_var_name()

=cut

sub self_var_name {

    return '$self';
}

=head2 import()

Экспортирует магическое ключевое слово.

Подробнее: L<Devel::Declare>.

=cut

sub import {

    my ( $self ) = @_;
    my $caller = caller();

    $self -> install_methodhandler(
        name => $self -> token_str(),
        into => $caller,
    );

    return;
}

=head2 parse_proto( Str $str )

Разбирает прототип метода, генерирует код и инжектит этот код в метод.

Подробнее: L<Devel::Declare>.

=cut

sub parse_proto {

    my ( $self, $str ) = @_;
    load my $type_system_class = $self -> type_system_class();
    my $sig = ( ( $str =~ m/^\s*$/ ) ? [] : $type_system_class -> tokenize_signature_str( "(${str})" ) );

    my @positional_vars = ( $self -> self_var_name() );
    my $code = '';
    my $pos  = 0;
    my $prev_was_optional = false;

    my $wrap_check = sub {

        my ( $code, $param_name ) = @_;

        return sprintf(
            '( eval{ local $Carp::CarpLevel = 2; %s } || die( "Validation for parameter \"%s\" failed because:\n$@" ) )',
            $code,
            $param_name,
        );
    };

    while( defined( my $item = shift( @$sig ) ) ) {

        if( $item -> { 'param' } -> { 'named' } ) {

            if( $prev_was_optional ) {

                die( "Error at signature (${str}): named parameter can't follow optional positional parameter" );
            }

            unshift( @$sig, $item );
            last;
        }

        my $type = $type_system_class -> materialize_type( $item -> { 'type' } );
        my $arg  = $item -> { 'param' };

        my $var = sprintf( '$%s', $arg -> { 'name' } );

        push( @positional_vars, $var );

        my $check = sprintf( '%s -> assert( %s, \'%s\' )', $type_system_class, $var, $type -> name() );

        $check = $wrap_check -> ( $check, $arg -> { 'name' } );

        if( $arg -> { 'optional' } ) {

            $prev_was_optional = true;

            $check = sprintf( '( ( scalar( @_ ) > %d ) ? %s : 1 )', 1 + $pos, $check );

        } elsif( $prev_was_optional ) {

            die( "Error at signature (${str}): required positional parameter can't follow optional one" );
        }

        $code .= $check;
        $code .= ';';

        $type_system_class -> get( $type -> name() ); # прогрев кэша

        ++$pos;
    }

    my @named_vars   = ();
    my @named_params = ();
    my $named_checks = '';

    while( defined( my $item = shift( @$sig ) ) ) {

        if( $item -> { 'param' } -> { 'positional' } ) {

            die( "Error at signature (${str}): positional parameter can't follow named parameter" );
        }

        my $type = $type_system_class -> materialize_type( $item -> { 'type' } );
        my $arg  = $item -> { 'param' };

        push( @named_vars, sprintf( '$%s', $arg -> { 'name' } ) );
        push( @named_params, sprintf( '\'%s\'', $arg -> { 'name' } ) );

        my $check = sprintf( '%s -> assert( $args{ \'%s\' }, \'%s\' )', $type_system_class, $arg -> { 'name' }, $type -> name() );

        $check = $wrap_check -> ( $check, $arg -> { 'name' } );

        if( $arg -> { 'optional' } ) {

            $prev_was_optional = true;

            $check = sprintf( '( exists( $args{ \'%s\' } ) ? %s : 1 )', $arg -> { 'name' }, $check );
        }

        $named_checks .= $check;
        $named_checks .= ';';
    }

    my $named_vars_code = ( $named_checks ? sprintf( '( my ( %s ) = do {

        no warnings \'syntax\';

        my %%args = @_[ %d .. $#_ ]; %s @args{ %s };

    } );', join( ', ', @named_vars ), scalar( @positional_vars ), $named_checks, join( ', ', @named_params ) ) : '' );

    $code = sprintf( 'my ( %s ) = @_; %s %s local @_ = ();', join( ', ', @positional_vars ), $code, $named_vars_code );

    $code =~ s/\n/ /g;
    $code =~ s/\s{2,}/ /g;

    return $code;
}

1;

__END__
