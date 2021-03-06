#! perl
# Copyright (C) 2009 The Perl Foundation

use 5.008;
use strict;
use warnings;
use Text::ParseWords;
use Getopt::Long;
use Cwd qw/abs_path cwd/;
use lib "tools/lib";
use NQP::Configure qw(cmp_rev read_parrot_config
                      fill_template_file fill_template_text
                      slurp system_or_die verify_install sorry gen_parrot);

MAIN: {
    if (-r "config.default") {
        unshift @ARGV, shellwords(slurp('config.default'));
    }

    my $slash  = $^O eq 'MSWin32' ? '\\' : '/';
    my %config = (perl => $^X);
    $config{'nqp_config_status'} = join(' ', map { "\"$_\""} @ARGV);

    my $exe = $NQP::Configure::exe;

    my %options;
    GetOptions(\%options, 'help!', 'prefix=s',
               'with-parrot=s', 'gen-parrot:s',
               'make-install!', 'makefile-timing!',
               'backends=s',
               'parrot-config=s', 'parrot-option=s@');

    # Print help if it's requested
    if ($options{'help'}) {
        print_help();
        exit(0);
    }

    # Deprecated --parrot-config option
    if ($options{'parrot-config'}) {
        sorry "The --parrot-config option has been removed.",
              "Use --prefix to specify a directory in which parrot is installed.";
    }

    my $default_backend;
    my %backends;
    my %known_backends = (parrot => 1, jvm => 1, moar => 1);
    if ($options{backends}) {
        for my $be (split /,/, $options{backends}) {
            $be = lc $be;
            unless ($known_backends{$be}) {
                die "Unknown backend: '$be'; Known backends: " .
                    join(', ', sort keys %known_backends) . "\n";
            }
            $default_backend ||= $be;
            $backends{$be} = 1;
        }
    }
    else {
        # TODO: come up with more sensible defaults
        $backends{parrot} = 1;
        $default_backend = 'parrot';
    }

    mkdir($options{'prefix'}) if $options{'prefix'} && $^O =~ /Win32/ && !-d $options{'prefix'};
    my $prefix      = ($options{'prefix'} && abs_path($options{'prefix'})) || cwd().'/install';
    $config{prefix} = $prefix;

    # Save options in config.status
    unlink('config.status');
    if (open(my $CONFIG_STATUS, '>', 'config.status')) {
        print $CONFIG_STATUS
            "$^X Configure.pl $config{'nqp_config_status'} \$*\n";
        close($CONFIG_STATUS);
    }
    $config{'makefile-timing'} = $options{'makefile-timing'};
    $config{'stagestats'} = '--stagestats' if $options{'makefile-timing'};
    $config{'shell'} = $^O eq 'MSWin32' ? 'cmd' : 'sh';
    $config{'bat'}   = $^O eq 'MSWin32' ? '.bat' : '';
    $config{'cpsep'} = $^O eq 'MSWin32' ? ';' : ':';
    $config{'slash'} = $slash;

    open my $MAKEFILE, '>', 'Makefile'
        or die "Cannot open 'Makefile' for writing: $!";

    my @prefixes = sort map substr($_, 0, 1), keys %backends;
    print $MAKEFILE "\n# Makefile code generated by Configure.pl:\n";

    my $launcher = substr($default_backend, 0, 1) . '-runner-default';
    print $MAKEFILE "all: ", join(' ', map("$_-all", @prefixes), $launcher), "\n";
    for my $t (qw/clean test qregex-test install/) {
        print $MAKEFILE "$t: ", join(' ', map "$_-$t", @prefixes), "\n";
    }


    fill_template_file(
        'tools/build/Makefile-common.in',
        $MAKEFILE,
        %config,
    );

    if ($backends{parrot}) {
        my $with_parrot = $options{'with-parrot'};
        my $gen_parrot  = $options{'gen-parrot'};
        my ($par_want) = split(' ', slurp('tools/build/PARROT_REVISION'));

        if (defined $gen_parrot) {
            $with_parrot = gen_parrot($par_want, %options, prefix => $prefix);
        }

        my @errors;

        my %par_config;
        if ($with_parrot) {
            %par_config = read_parrot_config($with_parrot)
            or push @errors, "Unable to read configuration from $with_parrot.";
        }
        else {
            %par_config = read_parrot_config("$prefix/bin/parrot$exe", "parrot$exe")
            or push @errors, "Unable to find parrot.";
            $with_parrot = fill_template_text('@bindir@/parrot@exe@', %par_config);
        }

        %config = (%config, %par_config);
        my $par_have = $config{'parrot::git_describe'} || '';
        if ($par_have && cmp_rev($par_have, $par_want) < 0) {
            push @errors, "Parrot revision $par_want required (currently $par_have).";
        }

        if (!@errors) {
            push @errors, verify_install([@NQP::Configure::required_parrot_files],
                                        %config);
            push @errors,
            "(Perhaps you need to 'make install', 'make install-dev',",
            "or install the 'devel' package for Parrot?)"
            if @errors;
        }

        if (@errors && !defined $gen_parrot) {
            push @errors,
            "\nTo automatically clone (git) and build a copy of Parrot $par_want,",
            "try re-running Configure.pl with the '--gen-parrot' option.",
            "Or, use '--with-parrot=' to explicitly specify the Parrot",
            "executable to use to build NQP.";
        }

        sorry(@errors) if @errors;

        print "Using $with_parrot (version $config{'parrot::git_describe'}).\n";

        if ($^O eq 'MSWin32' or $^O eq 'cygwin') {
            $config{'dll'} = '$(PARROT_BIN_DIR)/$(PARROT_LIB_SHARED)';
            $config{'dllcopy'} = '$(PARROT_LIB_SHARED)';
            $config{'make_dllcopy'} =
                '$(PARROT_DLL_COPY) : $(PARROT_DLL)'."\n\t".'$(CP) $(PARROT_DLL) .';
        }

        my $make = fill_template_text('@make@', %config);

        if ($make eq 'nmake') {
            system_or_die('cd 3rdparty\dyncall && Configure.bat' .
                ($config{'parrot::archname'} =~ /x64/ ? ' /target-x64' : ''));
            $config{'dyncall_build'} = 'cd 3rdparty\dyncall && nmake Nmakefile';
        }
        else {
            if ($^O eq 'MSWin32') {
                my $configure_args =
                    $config{'parrot::archname'} =~ /x86/ ? ' /target-x86' : ' /target-x64';

                $configure_args   .= $config{'parrot::cc'} eq 'gcc' ? ' /tool-gcc' : '';

                system_or_die('cd 3rdparty\dyncall && Configure.bat' . $configure_args);
                $config{'dyncall_build'} = "cd 3rdparty/dyncall && $make BUILD_DIR=. -f Makefile.embedded mingw32";
            } else {
                my $target_args = '';
                # heuristic according to
                # https://github.com/perl6/nqp/issues/100#issuecomment-18523608
                if ($^O eq 'darwin' && qx/ld 2>&1/ =~ /inferred architecture x86_64/) {
                    $target_args = " --target-x64";
                }
                system_or_die('cd 3rdparty/dyncall && sh configure' . $target_args);

                if ($^O eq 'netbsd') {
                    $config{'dyncall_build'} = "cd 3rdparty/dyncall && BUILD_DIR=. $make -f BSDmakefile";
                } else {
                    $config{'dyncall_build'} = "cd 3rdparty/dyncall && BUILD_DIR=. $make";
                }
            }
        }

        fill_template_file(
            'tools/build/Makefile-Parrot.in', $MAKEFILE,
            %config,
        );
        fill_template_file('src/vm/parrot/nqp.sh', 'gen/parrot/nqp_launcher', %config);
        chmod 0755, 'gen/parrot/nqp_launcher';
    }
    if ($backends{moar}) {
        my @errors;
        my $moar_path = "$prefix${slash}bin${slash}moar" . ($^O =~ /MSWin32/ ? '.exe' : '');
        my @moar_info = `$moar_path --help`;
        my $moar_found = 0;
        for (@moar_info) {
            if (/USAGE: moar/) {
                $moar_found = 1;
                last;
            }
        }
        if (!$moar_found) {
            push @errors,
                "No MoarVM (moar executable) found using the --prefix";
        }
        sorry(@errors) if @errors;
        $config{'make'}   = $^O eq 'MSWin32' ? 'nmake' : 'make';
        $config{'runner'} = $^O eq 'MSWin32' ? 'nqp.bat' : 'nqp';
        fill_template_file(
            'tools/build/Makefile-Moar.in',
            $MAKEFILE,
            %config,
        );
    }

    if ($backends{jvm}) {
        my @errors;

        my $got;
        if (!@errors) {
            my @jvm_info = `java -showversion 2>&1`;
            my $jvm_found = 0;
            my $jvm_ok = 0;
            for (@jvm_info) {
                if (/(?:java|jdk) version "(\d+)\.(\d+)/) {
                    $jvm_found = 1;
                    if ($1 > 1 || $1 == 1 && $2 >= 7) {
                        $jvm_ok = 1;
                    }
                    $got = $_;
                    last;
                }
            }
            
            if (!$jvm_found) {
                push @errors,
                    "No JVM (java executable) in path; cannot continue";
            }
            elsif (!$jvm_ok) {
                push @errors,
                    "Need at least JVM 1.7 (got $got)";
            }
        }

        sorry(@errors) if @errors;

        print "Using $got\n";

        $config{'make'} = $^O eq 'MSWin32' ? 'nmake' : 'make';
        $config{'runner'} = $^O eq 'MSWin32' ? 'nqp.bat' : 'nqp';

        fill_template_file(
            'tools/build/Makefile-JVM.in',
            $MAKEFILE,
            %config,
        );
    }

    my $ext = '';
    if ($^O eq 'MSWin32') {
        $ext = $default_backend eq 'parrot' ? '.exe' : '.bat';
    }

    print $MAKEFILE qq[t/*/*.t: all\n\tprove -r -v --exec ./nqp$ext \$\@\n];

    close $MAKEFILE
        or die "Error while writing to 'Makefile': $!";

    my $make = fill_template_text('@make@', %config);
    unless ($options{'no-clean'}) {
        no warnings;
        print "Cleaning up ...\n";
        if (open my $CLEAN, '-|', "$make clean") {
            my @slurp = <$CLEAN>;
            close($CLEAN);
        }
    }

    if ($options{'make-install'}) {
        system_or_die($make);
        system_or_die($make, 'install');
        print "\nNQP has been built and installed.\n";
    }
    else {
        print "You can now use '$make' to build NQP.\n";
        print "After that, '$make test' will run some tests and\n";
        print "'$make install' will install NQP.\n";
    }

    exit 0;
}


#  Print some help text.
sub print_help {
    print <<'END';
Configure.pl - NQP Configure

General Options:
    --help             Show this text
    --prefix=dir       Install files in dir
    --backends=list    Backends to use: parrot,jvm,moar
    --with-parrot=path/to/bin/parrot
                       Parrot executable to use to build NQP
    --gen-parrot[=branch]
                       Download and build a copy of Parrot to use
    --parrot-option='--option=value'
                       Options to pass to parrot configuration for --gen-parrot

Configure.pl also reads options from 'config.default' in the current directory.
END

    return;
}

# Local Variables:
#   mode: cperl
#   cperl-indent-level: 4
#   fill-column: 100
# End:
# vim: expandtab shiftwidth=4:
