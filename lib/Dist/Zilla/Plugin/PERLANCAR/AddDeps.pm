package Dist::Zilla::Plugin::PERLANCAR::AddDeps;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;

use Moose;
with (
    'Dist::Zilla::Role::FileGatherer',
    'Dist::Zilla::Role::MetaProvider',
);

use App::lcpan::Call qw(call_lcpan_script);
use Dist::Zilla::Util::ParsePrereqsFromDistIni qw(parse_prereqs_from_dist_ini);
use File::Slurper qw(read_binary);
use Module::Path::More qw(module_path);

has include_author => (is=>'rw');

sub mvp_multivalue_args { qw(include_author) }

use namespace::autoclean;

sub gather_files {
    use experimental 'smartmatch';

    my $self = shift;

    # we cannot use this method because at this early stage, prereqs has not
    # been filled. we need to parse prereqs directly from dist.ini
    #my $prereqs_hash = $self->zilla->prereqs->as_string_hash;
    my $prereqs_hash = parse_prereqs_from_dist_ini(path=>"dist.ini");

    my $runtime_requires = $prereqs_hash->{runtime}{requires} or return;

    my $res = call_lcpan_script(
        argv => ['deps', '-R',
                 grep {$_ ne 'perl'} keys %$runtime_requires],
    );

    my %add_mods; # to be added in our dist
    my %dep_mods; # to stay as deps
    for my $rec (@$res) {
        my $add = 0;
        my $mod = $rec->{module};
        $mod =~ s/\A\s+//;

        # decide whether we should add this module or not
      DECIDE:
        {
            if ($self->include_author && @{ $self->include_author }) {
                last DECIDE unless $rec->{author} ~~ @{ $self->include_author };
            }
            $add = 1;
        }

        if ($add) {
            $add_mods{$mod} = $rec->{version};
        } else {
            $dep_mods{$mod} = $rec->{version};
        }
    }

    $self->log_debug(["modules to add into dist: %s", \%add_mods]);
    $self->log_debug(["modules to add as deps: %s", \%dep_mods]);

    my $meta_no_index = {};

    $res = call_lcpan_script(argv=>["mods-from-same-dist", keys %add_mods]);
    for my $mod (@{ $res }) {
        my $path = module_path(module => $mod);
        $self->log_fatal(["Can't find path for module %s, make sure the module is installed", $mod])
            unless $path;

        my $mod_pm = $mod;
        $mod_pm =~ s!::!/!g;
        $mod_pm .= ".pm";

        my $ct = read_binary($path);

      MUNGE:
        {
            # adjust dist name
            $ct =~ s/^(=head1 VERSION\s+[^\n]+from Perl distribution )([\w-]+)/
                $1 . $self->zilla->name . " version " . $self->zilla->version/ems;
        }

        my $file_path = "lib/$mod_pm";
        my $file = Dist::Zilla::File::InMemory->new(
            name    => $file_path,
            content => $ct,
        );
        push @{ $meta_no_index->{file} }, $file_path;

        $self->add_file($file);
    }
    $self->{_meta_no_index} = $meta_no_index;

    for my $mod (keys %dep_mods) {
        $self->zilla->register_prereqs($mod => $dep_mods{$mod});
    }
}

sub metadata {
    my $self = shift;
    { no_index => $self->{_meta_no_index} };
}

__PACKAGE__->meta->make_immutable;
1;
# ABSTRACT: Include dependencies into dist

=for Pod::Coverage .+

=head1 SYNOPSIS

In C<dist.ini>:

 name=Perinci-CmdLine-Any-Bundled
 version=0.01

 [Prereqs]
 Perinci::CmdLine::Any=0

 [PERLANCAR::AddDeps]
 include_author = PERLANCAR


=head1 DESCRIPTION

B<WARNING: EXPERIMENTAL>

This plugin will add module files from dependencies into your dist during
building. When done carefully, can reduce the number of dists that users need to
install because they are already included in your dists.

=head2 How it works

1. Perform "lcpan deps -R" against the "runtime requires" dependencies of your
dist. This basically queries your local CPAN index and ask for the recursive
dependencies of the modules. You can filter this using C<include_author> to
include only dependencies written by a certain author (for example, yourself).
The result is a list of modules.

2. Perform "lcpan mods-from-same-dist" for all modules found in #1. The result
is all modules from all dependency distributions.

3. Search all the modules found in #2 in your local installation and include
them to Dist::Zilla for building. Some minor modifications will be done first:

=over

=item *

If the POD indicates which dist the module is in, will replace it with our dist.
For example if there is a VERSION section with this content:

 This document describes version 0.10 of Perinci::CmdLine::Any (from Perl
 distribution Perinci-CmdLine-Any), released on 2015-04-12.

then the text will be replaced with:

 This document describes version 0.10 of Perinci::CmdLine::Any (from Perl
 distribution Perinci-CmdLine-Any-Bundled version 0.01), released on 2015-04-12.

=back

=head2 Caveats

=over

=item *

"lcpan" is used to list dependencies and contents of dists. You should have
"lcpan" installed and your local CPAN fairly recent (keep it up-to-date with
"lcpan update").

=item *

Only modules from each dependency distribution are included. This means other
stuffs are not included: scripts/binaries, shared files, PODs. This is because
PAUSE currently only index packages (~ modules). We have C<.packlist> though,
and can use it in the future when needed.

=item *

Your bundle dist (the one you're building which include the deps) should be
built with a minimal set of Dist::Zilla plugins. It should not do POD weaving,
or change/fill version numbers (e.g. OurVersion which looks for C<# VERSION> and
change it), etc. We want the included dependency module files to be as pristine
as possible.

=item *

Currently all the dependency dists must be installed on your local Perl
installation. (This is purely out of my coding laziness though. It could/should
be extracted from the release file in local CPAN index though.)

=back


=head1 SEE ALSO

L<lcpan>
