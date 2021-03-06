package Code::TidyAll::Plugin;

use Code::TidyAll::Util::Zglob qw(zglobs_to_regex);
use File::Slurp::Tiny qw(read_file write_file);
use File::Which qw( which );
use IPC::Run3 qw( run3 );
use Scalar::Util qw(weaken);
use Text::Diff 1.44 qw( diff );

use Moo;

our $VERSION = '0.50';

# External
has 'argv'               => ( is => 'ro', default => q{} );
has 'class'              => ( is => 'ro' );
has 'cmd'                => ( is => 'lazy' );
has 'diff_on_tidy_error' => ( is => 'ro', default => 0 );
has 'ignore'             => ( is => 'ro' );
has 'is_tidier'          => ( is => 'lazy' );
has 'is_validator'       => ( is => 'lazy' );
has 'name'               => ( is => 'ro', required => 1 );
has 'select'             => ( is => 'ro' );
has 'shebang'            => ( is => 'ro' );
has 'tidyall'            => ( is => 'ro', required => 1, weak_ref => 1 );
has 'weight'             => ( is => 'lazy' );

# Internal
has 'ignore_regex' => ( is => 'lazy' );
has 'ignores'      => ( is => 'lazy' );
has 'select_regex' => ( is => 'lazy' );
has 'selects'      => ( is => 'lazy' );

around BUILDARGS => sub {
    my $orig  = shift;
    my $class = shift;

    my $args = $class->$orig(@_);

    for my $key (qw( ignore select shebang )) {
        if ( defined $args->{$key} && !ref $args->{$key} ) {
            $args->{$key} = [ $args->{$key} ];
        }
    }

    return $args;
};

sub _build_cmd {
    die "no default cmd specified";
}

sub _build_selects {
    my ($self) = @_;
    die sprintf( "select is required for '%s'", $self->name ) unless defined( $self->select );
    return $self->_parse_zglob_list( $self->select );
}

sub _build_select_regex {
    my ($self) = @_;
    return zglobs_to_regex( @{ $self->selects } );
}

sub _build_ignores {
    my ($self) = @_;
    return $self->_parse_zglob_list( $self->ignore );
}

sub _build_ignore_regex {
    my ($self) = @_;
    return zglobs_to_regex( @{ $self->ignores } );
}

sub _build_is_tidier {
    my ($self) = @_;
    return ( $self->can('transform_source') || $self->can('transform_file') ) ? 1 : 0;
}

sub _build_is_validator {
    my ($self) = @_;
    return ( $self->can('validate_source') || $self->can('validate_file') ) ? 1 : 0;
}

# default weight
sub _build_weight {
    my ($self) = @_;
    return 60 if $self->is_validator;
    return 50;
}

sub BUILD {
    my ( $self, $params ) = @_;

    # Strict constructor
    #
    $self->validate_params($params);
}

sub validate_params {
    my ( $self, $params ) = @_;

    delete( $params->{only_modes} );
    delete( $params->{except_modes} );
    if ( my @bad_params = grep { !$self->can($_) } keys(%$params) ) {
        die sprintf(
            "unknown option%s %s for plugin '%s'",
            @bad_params > 1 ? "s" : "",
            join( ", ", sort map {"'$_'"} @bad_params ),
            $self->name
        );
    }
}

sub _parse_zglob_list {
    my ( $self, $zglobs ) = @_;
    if ( my ($bad_zglob) = ( grep {m{^/}} @{$zglobs} ) ) {
        die "zglob '$bad_zglob' should not begin with slash";
    }
    return $zglobs;
}

# No-ops by default; may be overridden in subclass
sub preprocess_source {
    return $_[1];
}

sub postprocess_source {
    return $_[1];
}

sub process_source_or_file {
    my ( $self, $orig_source, $basename, $check_only ) = @_;

    my $new_source = $orig_source;
    if ( $self->can('transform_source') ) {
        foreach my $iter ( 1 .. $self->tidyall->iterations ) {
            $new_source = $self->transform_source($new_source);
        }
    }
    if ( $self->can('transform_file') ) {
        my $tempfile = $self->_write_temp_file( $basename, $new_source );
        foreach my $iter ( 1 .. $self->tidyall->iterations ) {
            $self->transform_file($tempfile);
        }
        $new_source = read_file($tempfile);
    }
    if ( $self->can('validate_source') ) {
        $self->validate_source($new_source);
    }
    if ( $self->can('validate_file') ) {
        my $tempfile = $self->_write_temp_file( $basename, $new_source );
        $self->validate_file($tempfile);
    }

    my $diff;
    if ( $check_only && $new_source ne $orig_source ) {
        $diff = $self->_maybe_diff( $orig_source, $new_source, $basename );
    }

    return ( $new_source, $diff );
}

sub _maybe_diff {
    my $self = shift;

    return unless $self->diff_on_tidy_error;

    my $orig     = shift;
    my $new      = shift;
    my $basename = shift;

    my $orig_file = $self->_write_temp_file( $basename . '.orig', $orig );
    my $new_file  = $self->_write_temp_file( $basename . '.new',  $new );

    return diff( $orig_file, $new_file, { Style => 'Unified' } );
}

sub _write_temp_file {
    my ( $self, $basename, $source ) = @_;

    my $tempfile = join( "/", $self->tidyall->_tempdir(), $basename );
    write_file( $tempfile, $source );
    return $tempfile;
}

sub matches_path {
    my ( $self, $path ) = @_;
    return $path =~ $self->select_regex && $path !~ $self->ignore_regex;
}

1;

# ABSTRACT: Create plugins for tidying or validating code

__END__

=pod

=head1 SYNOPSIS

    package Code::TidyAll::Plugin::SomeTidier;
    use Moo;
    extends 'Code::TidyAll::Plugin';

    sub transform_source {
        my ( $self, $source ) = @_;
        ...
        return $source;
    }


    package Code::TidyAll::Plugin::SomeValidator;
    use Moo;
    extends 'Code::TidyAll::Plugin';

    sub validate_file {
        my ( $self, $file ) = @_;
        die "not valid" if ...;
    }

=head1 DESCRIPTION

To use a tidier or validator with C<tidyall> it must have a corresponding
plugin class that inherits from this class. This document describes how to
implement a new plugin.

The easiest way to start is to look at existing plugins, such as
L<Code::TidyAll::Plugin::PerlTidy> and L<Code::TidyAll::Plugin::PerlCritic>.

=head1 NAMING

If you are going to publicly release your plugin, call it
'Code::TidyAll::Plugin::I<something>' so that users can find it easily and
refer to it by its short name in configuration.

If it's an internal plugin, you can call it whatever you like and refer to it
with a plus sign prefix in the config file, e.g.

    [+My::Tidier::Class]
    select = **/*.{pl,pm,t}

=head1 CONSTRUCTOR AND ATTRIBUTES

Your plugin constructor will be called with the configuration key/value pairs
as parameters. e.g. given

    [PerlCritic]
    select = lib/**/*.pm
    ignore = lib/UtterHack.pm
    argv = -severity 3

then L<Code::TidyAll::Plugin::PerlCritic> would be constructed with parameters

    select => 'lib/**/*.pm',
    ignore = 'lib/UtterHack.pm',
    argv = '-severity 3'

The following attributes are part of this base class. Your subclass can declare
others, of course.

=over

=item argv

A standard attribute for passing command line arguments.

=item cmd

A standard attribute for specifying the name of the command to run, e.g.
"/usr/local/bin/perlcritic".

=item diff_on_tidy_error

This only applies to plugins which transform source. If this is true, then when
the plugin is run in check mode it will include a diff in the return value from
C<process_source_or_file> when the source is not tidy.

=item is_validator

An attribute that indicates if this is a validator or not; By default this
returns true if either C<validate_source> or C<validate_file> methods have been
implemented.

=item name

Name of the plugin to be used in error messages etc.

=item tidyall

A weak reference back to the L<Code::TidyAll> object.

=item select, ignore

Select and ignore patterns - you can ignore these.

=item weight

A number indicating the relative weight of the plugin, used to calculate the
order the plugins will execute in. The lower the number the sooner the plugin
will be executed.

By default the weight will be C<50> for non validators (anything where
C<is_validator> returns false) and C<60> for validators (anything where
C<is_validator> returns true.)

The order of plugin execution is determined first by the value of the C<weight>
attribute, and then (if multiple plugins have the same weight>) by sorting by
the name of module.

=back

=head1 METHODS

Your plugin may define one or more of these methods. They are all no-ops by
default.

=over

=item preprocess_source ($source)

Receives source code as a string; returns the processed string, or dies with
error. This runs on all plugins I<before> any of the other methods.

=item transform_source ($source)

Receives source code as a string; returns the transformed string, or dies with
error. This is repeated multiple times if --iterations was passed or specified
in the configuration file.

=item transform_file ($file)

Receives filename; transforms the file in place, or dies with error. Note that
the file will be a temporary copy of the user's file with the same basename;
your changes will only propagate back if there was no error reported from any
plugin. This is repeated multiple times if --iterations was passed or specified
in the configuration file.

=item validate_source ($source)

Receives source code as a string; dies with error if invalid. Return value will
be ignored.

=item validate_file ($file)

Receives filename; validates file and dies with error if invalid. Should not
modify file! Return value will be ignored.

=item postprocess_source ($source)

Receives source code as a string; returns the processed string, or dies with
error. This runs on all plugins I<after> any of the other methods.

=back
