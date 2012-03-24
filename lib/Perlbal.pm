#!/usr/bin/perl
#
# Copyright 2004, Danga Interactive, Inc.
# Copyright 2005-2007, Six Apart, Ltd.
#

=head1 NAME

Perlbal - Reverse-proxy load balancer and webserver

=head1 SEE ALSO

L<http://www.danga.com/perlbal/>

=head1 CONTRIBUTING

Got a patch?  Or a bug report?  Instructions on how to contribute
are located here:

L<http://contributing.appspot.com/perlbal>

Thanks!

=head1 COPYRIGHT AND LICENSE

Copyright 2004, Danga Interactive, Inc.
Copyright 2005-2010, Six Apart, Ltd.

You can use and redistribute Perlbal under the same terms as Perl itself.

=cut

package Perlbal;

BEGIN {
    # keep track of anonymous subs' origins:
    $^P |= 0x200;
}

my $has_gladiator  = eval "use Devel::Gladiator; 1;";
my $has_cycle      = eval "use Devel::Cycle; 1;";
my $has_devel_peek = eval "use Devel::Peek; 1;";

use vars qw($VERSION);
$VERSION = '1.80';

use constant DEBUG => $ENV{PERLBAL_DEBUG} || 0;
use constant DEBUG_OBJ => $ENV{PERLBAL_DEBUG_OBJ} || 0;
use constant TRACK_STATES => $ENV{PERLBAL_TRACK_STATES} || 0; # if on, track states for "state changes" command

use strict;
use warnings;
no  warnings qw(deprecated);

use IO::Socket;
use IO::Handle;
use IO::File;

$Perlbal::SYSLOG_AVAILABLE = eval { require Sys::Syslog; 1; };
$Perlbal::BSD_RESOURCE_AVAILABLE = eval { require BSD::Resource; 1; };

# incremented every second by a timer:
$Perlbal::tick_time = time();

# Set to 1 when we open syslog, and 0 when we close it
$Perlbal::syslog_open = 0;

use Getopt::Long;
use Carp qw(cluck croak);
use Errno qw(EBADF);
use POSIX qw(SIG_BLOCK SIG_UNBLOCK SIGINT sigprocmask);

our(%TrackVar);
sub track_var {
    my ($name, $ref) = @_;
    $TrackVar{$name} = $ref;
}

use Perlbal::AIO;
use Perlbal::HTTPHeaders;
use Perlbal::Service;
use Perlbal::Socket;
use Perlbal::TCPListener;
use Perlbal::UploadListener;
use Perlbal::ClientManage;
use Perlbal::ClientHTTPBase;
use Perlbal::ClientProxy;
use Perlbal::ClientHTTP;
use Perlbal::BackendHTTP;
use Perlbal::ReproxyManager;
use Perlbal::Pool;
use Perlbal::ManageCommand;
use Perlbal::CommandContext;
use Perlbal::Util;

$SIG{'PIPE'} = "IGNORE";  # handled manually

our(%hooks);     # hookname => subref
our(%service);   # servicename -> Perlbal::Service
our(%pool);      # poolname => Perlbal::Pool
our(%plugins);   # plugin => 1 (shows loaded plugins)
our($last_error);
our $service_autonumber = 1; # used to generate names for anonymous services created with Perlbal->create_service()
our $vivify_pools = 1; # if on, allow automatic creation of pools
our $foreground = 1; # default to foreground
our $track_obj = 0;  # default to not track creation locations
our $reqs = 0; # total number of requests we've done
our $starttime = time(); # time we started
our $pidfile = '';  # full path, default to not writing pidfile
# used by pidfile (only makes sense before run started)
# don't rely on this variable, it might change.
our $run_started = 0;  
our ($lastutime, $laststime, $lastreqs) = (0, 0, 0); # for deltas

our %PluginCase = ();   # lowercase plugin name -> as file is named

# setup XS status data structures
our %XSModules; # ( 'headers' => 'Perlbal::XS::HTTPHeaders' )

# now include XS files
eval "use Perlbal::XS::HTTPHeaders;"; # if we have it, load it

# activate modules as necessary
if ($ENV{PERLBAL_XS_HEADERS} && $XSModules{headers}) {
    Perlbal::XS::HTTPHeaders::enable();
}

# unactivate field::new 
if ($ENV{PERLBAL_REMOVE_FIELDS}) {
	use Perlbal::Fields;
	Perlbal::Fields->remove();
}


# setup a USR1 signal handler that tells us to dump some basic statistics
# of how we're doing to the syslog
$SIG{'USR1'} = sub {
    my $dumper = sub { Perlbal::log('info', $_[0]); };
    foreach my $svc (values %service) {
        run_manage_command("show service $svc->{name}", $dumper);
    }
    run_manage_command('states', $dumper);
    run_manage_command('queues', $dumper);
};

sub error {
    $last_error = shift;
    return 0;
}

# Object instance counts, for debugging and leak detection
our(%ObjCount);  # classname -> instances
our(%ObjTotal);  # classname -> instances
our(%ObjTrack);  # "$objref" -> creation location
sub objctor {
    if (DEBUG_OBJ) {
        my $ref = ref $_[0];
        $ref .= "-$_[1]" if $_[1];
        $ObjCount{$ref}++;
        $ObjTotal{$ref}++;

        # now, if we're tracing leaks, note this object's creation location
        if ($track_obj) {
            my $i = 1;
            my @list;
            while (my $sub = (caller($i++))[3]) {
                push @list, $sub;
            }
            $ObjTrack{"$_[0]"} = [ time, join(', ', @list) ];
        }
    }
}
sub objdtor {
    if (DEBUG_OBJ) {
        my $ref = ref $_[0];
        $ref .= "-$_[1]" if $_[1];
        $ObjCount{$ref}--;

        # remove tracking for this object
        if ($track_obj) {
            delete $ObjTrack{"$_[0]"};
        }
    }
}

sub register_global_hook {
    $hooks{$_[0]} = $_[1];
    return 1;
}

sub unregister_global_hook {
    delete $hooks{$_[0]};
    return 1;
}

sub run_global_hook {
    my $hookname = shift;
    my $ref = $hooks{$hookname};
    return $ref->(@_) if defined $ref;   # @_ is $mc (a Perlbal::ManageCommand)
    return undef;
}

sub service_names {
    return sort keys %service;
}

# class method:  given a service name, returns a service object
sub service {
    my $class = shift;
    return $service{$_[0]};
}

sub create_service {
    my $class = shift;
    my $name = shift;

    unless (defined($name)) {
        $name = "____auto_".($service_autonumber++);
    }

    croak("service '$name' already exists") if $service{$name};
    croak("pool '$name' already exists") if $pool{$name};

    # Create the new service and return it
    return $service{$name} = Perlbal::Service->new($name);
}

sub pool {
    my $class = shift;
    return $pool{$_[0]};
}

# given some plugin name, return its correct case
sub plugin_case {
    my $pname = lc shift;
    return $PluginCase{$pname} || $pname;
}

# run a block of commands.  returns true if they all passed
sub run_manage_commands {
    my ($cmd_block, $out, $ctx) = @_;

    $ctx ||= Perlbal::CommandContext->new;
    foreach my $cmd (split(/\n/, $cmd_block)) {
        return 0 unless Perlbal::run_manage_command($cmd, $out, $ctx);
    }
    return 1;
}

# allows ${ip:eth0} in config.  currently the only supported expansion
sub _expand_config_var {
    my $cmd = shift;
    $cmd =~ /^(\w+):(.+)/
        or die "Unknown config variable: $cmd\n";
    my ($type, $val) = ($1, $2);
    if ($type eq "ip") {
        die "Bogus-looking iface name" unless $val =~ /^\w+$/;
        my $conf = `/sbin/ifconfig $val`;
        $conf =~ /inet addr:(\S+)/
            or die "Can't find IP of interface '$val'";
        return $1;
    }
    die "Unknown config variable type: $type\n";
}

# returns 1 if command succeeded, 0 otherwise
sub run_manage_command {
    my ($cmd, $out, $ctx) = @_;  # $out is output stream closure

    $cmd =~ s/\#.*//;
    $cmd =~ s/^\s+//;
    $cmd =~ s/\s+$//;
    $cmd =~ s/\s+/ /g;

    # expand variables
    my $orig = $cmd; # save original case for some commands

    $cmd =~ s/\$\{(.+?)\}/_expand_config_var($1)/eg;
    $cmd =~ s/\$(\w+)/$ENV{$1}/g;

    $cmd =~ s/^([^=]+)/lc $1/e; # lowercase everything up to an =
    return 1 unless $cmd =~ /^\S/;

    $out ||= sub {};
    $ctx ||= Perlbal::CommandContext->new;

    my $err = sub {
        $out->("ERROR: $_[0]");
        return 0;
    };
    my $ok = sub {
        $out->("OK") if $ctx->verbose;
        return 1;
    };

    return $err->("invalid command") unless $cmd =~ /^(\w+)/;
    my $basecmd = $1;

    my $mc = Perlbal::ManageCommand->new($basecmd, $cmd, $out, $ok, $err, $orig, $ctx);

    # for testing auto crashing and recovery:
    if ($basecmd eq "crash") { die "Intentional crash." };

    no strict 'refs';
    my $handler;
    if ($Perlbal::{"MANAGE_$basecmd"} && ($handler = *{"MANAGE_$basecmd"}{CODE})) {
        my $rv = eval { $handler->($mc); };
        return $mc->err($@) if $@;
        return $rv;
    }

    # if no handler found, look for plugins

    # call any hooks if they've been defined
    my $rval = eval { run_global_hook("manage_command.$basecmd", $mc); };
    return $mc->err($@) if $@;
    if (defined $rval) {
        # commands may return boolean, or arrayref to mass-print
        if (ref $rval eq "ARRAY") {
            $mc->out($_) foreach @$rval;
            return 1;
        }
        return $rval;
    }

    return $mc->err("unknown command: $basecmd");
}

sub arena_ref_counts {
    my $all = Devel::Gladiator::walk_arena();
    my %ct;

    my %run_cycle;
    foreach my $it (@$all) {
        $ct{ref $it}++;
        if (ref $it eq "CODE") {
            my $name = Devel::Peek::CvGV($it);
            $ct{$name}++ if $name =~ /ANON/;
        }
    }
    $all = undef;
    return \%ct;
}

my %last_gladiator;
sub MANAGE_gladiator {
    my $mc = shift->no_opts;
    unless ($has_gladiator && $has_devel_peek) {
        $mc->end;
        return;
    }

    my $ct = arena_ref_counts();
    my $ret;
    $ret .= "ARENA COUNTS:\n";
    foreach my $k (sort {$ct->{$b} <=> $ct->{$a}} keys %$ct) {
        my $delta = $ct->{$k} - ($last_gladiator{$k} || 0);
        $last_gladiator{$k} = $ct->{$k};
        next unless $ct->{$k} > 1;
        $ret .= sprintf(" %4d %-4d $k\n", $ct->{$k}, $delta);
    }

    $mc->out($ret);
    $mc->end;
}

sub MANAGE_varsize {
    my $mc = shift->no_opts;

    my $emit;
    $emit = sub {
        my ($v, $depth, $name) = @_;
        $name ||= "";

        my $show;
        if (ref $v eq "ARRAY") {
            return unless @$v;
            $show = "[] " . scalar @$v;
        }
        elsif (ref $v eq "HASH") {
            return unless %$v;
            $show = "{} " . scalar keys %$v;
        }
        else {
            $show = " = $v";
        }
        my $pre = "  " x $depth;
        $mc->out("$pre$name $show");

        if (ref $v eq "HASH") {
            foreach my $k (sort keys %$v) {
                $emit->($v->{$k}, $depth+1, "{$k}");
            }
        }
    };

    foreach my $k (sort keys %TrackVar) {
        my $v = $TrackVar{$k} or next;
        $emit->($v, 0, $k);
    }

    $mc->end;
}

sub MANAGE_obj {
    my $mc = shift->no_opts;

    foreach (sort keys %ObjCount) {
        $mc->out("$_ = $ObjCount{$_} (tot=$ObjTotal{$_})");
    }
    $mc->end;
}

sub MANAGE_verbose {
    my $mc = shift->parse(qr/^verbose (on|off)$/,
                          "usage: VERBOSE {on|off}");
    my $onoff = $mc->arg(1);
    $mc->{ctx}->verbose(lc $onoff eq 'on' ? 1 : 0);
    return $mc->ok;
}

sub MANAGE_shutdown {
    my $mc = shift->parse(qr/^shutdown(\s?graceful)?\s?(\d+)?$/);

    # immediate shutdown
    exit(0) unless $mc->arg(1);

    # set connect ahead to 0 for all services so they don't spawn extra backends
    foreach my $svc (values %service) {
        $svc->{connect_ahead} = 0;
    }

    # tell all sockets we're doing a graceful stop
    my $sf = Perlbal::Socket->get_sock_ref;
    foreach my $k (keys %$sf) {
        my Perlbal::Socket $v = $sf->{$k};
        $v->die_gracefully if $v->can("die_gracefully");
    }

    # register a post loop callback that will end the event loop when we only have
    # a single socket left, the AIO socket
    Perlbal::Socket->SetPostLoopCallback(sub {
        my ($descmap, $otherfds) = @_;

        # Ghetto: duplicate the code we already had for our postloopcallback
        Perlbal::Socket::run_callbacks();

        # see what we have here; make sure we have no Clients and no unbored Backends
        foreach my $sock (values %$descmap) {
            my $ref = ref $sock;
            return 1 if $ref =~ /^Perlbal::Client/ && $ref ne 'Perlbal::ClientManage';
            return 1 if $sock->isa('Perlbal::BackendHTTP') && $sock->{state} ne 'bored';
        }
        return 0; # end the event loop and thus we exit perlbal
    });

    # If requested, register a callback to kill the perlbal process after a specified number of seconds
    if (my $timeout = $mc->arg(2)) {
        Perlbal::Socket::register_callback($timeout, sub { exit(0); });
    }

    # so they know something happened
    return $mc->ok;
}

sub MANAGE_mime {
    my $mc = shift->parse(qr/^mime(?:\s+(\w+)(?:\s+(\w+))?(?:\s+(\S+))?)?$/);
    my ($cmd, $arg1, $arg2) = ($mc->arg(1), $mc->arg(2), $mc->arg(3));

    if (!$cmd || $cmd eq 'list') {
        foreach my $key (sort keys %$Perlbal::ClientHTTPBase::MimeType) {
            $mc->out("$key $Perlbal::ClientHTTPBase::MimeType->{$key}");
        }
        $mc->end;
    } elsif ($cmd eq 'set') {
        if (!$arg1 || !$arg2) {
            return $mc->err("Usage: set <ext> <mime>");
        }

        $Perlbal::ClientHTTPBase::MimeType->{$arg1} = $arg2;
        return $mc->out("$arg1 set to $arg2.");
    } elsif ($cmd eq 'remove') {
        if (delete $Perlbal::ClientHTTPBase::MimeType->{$arg1}) {
            return $mc->out("$arg1 removed.");
        } else {
            return $mc->err("$arg1 not a defined extension.");
        }
    } else {
        return $mc->err("Usage: list, remove <ext>, set <ext> <mime>");
    }
}

sub MANAGE_xs {
    my $mc = shift->parse(qr/^xs(?:\s+(\w+)\s+(\w+))?$/);
    my ($cmd, $module) = ($mc->arg(1), $mc->arg(2));

    if ($cmd) {
        # command? verify
        return $mc->err('Known XS modules: ' . join(', ', sort keys %XSModules) . '.')
            unless $XSModules{$module};

        # okay, so now enable or disable this module
        if ($cmd eq 'enable') {
            my $res = eval "return $XSModules{$module}::enable();";
            return $mc->err("Unable to enable module.")
                unless $res;
            return $mc->ok;
        } elsif ($cmd eq 'disable') {
            my $res = eval "return $XSModules{$module}::disable();";
            return $mc->err("Unable to disable module.")
                unless $res;
            return $mc->out("Module disabled.");
        } else {
            return $mc->err('Usage: xs [ <enable|disable> <module> ]');
        }
    } else {
        # no commands, so just check status
        $mc->out('XS module status:', '');
        foreach my $module (sort keys %XSModules) {
            my $class = $XSModules{$module};
            my $enabled = eval "return \$${class}::Enabled;";
            my $status = defined $enabled ? ($enabled ? "installed, enabled" :
                                             "installed, disabled") : "not installed";
            $mc->out("   $module: $status");
        }
        $mc->out('   No modules available.') unless %XSModules;
        $mc->out('');
        $mc->out("To enable a module: xs enable <module>");
        $mc->out("To disable a module: xs disable <module>");
    }
    $mc->end;
}

sub MANAGE_fd {
    my $mc = shift->no_opts;
    return $mc->err('This command is not available unless BSD::Resource is installed') unless $Perlbal::BSD_RESOURCE_AVAILABLE;

    # called in list context on purpose, but we want the hard limit
    my (undef, $max) = BSD::Resource::getrlimit(BSD::Resource::RLIMIT_NOFILE());
    my $ct = 0;

    # first try procfs if one exists, as that's faster than iterating
    if (opendir(DIR, "/proc/self/fd")) {
        my @dirs = readdir(DIR);
        $ct = scalar(@dirs) - 2; # don't count . and ..
        closedir(DIR);
    } else {
        # isatty() is cheap enough to do on everything
        foreach (0..$max) {
            my $res = POSIX::isatty($_);
            $ct++ if $res || ($! != EBADF);
        }
    }
    $mc->out("max $max");
    $mc->out("cur $ct");
    $mc->end;
}

sub MANAGE_proc {
    my $mc = shift->no_opts;

    $mc->out('time: ' . time());
    $mc->out('pid: ' . $$);


    if ($Perlbal::BSD_RESOURCE_AVAILABLE) {
        my $ru = BSD::Resource::getrusage();
        my ($ut, $st) = ($ru->utime, $ru->stime);
        my ($udelta, $sdelta) = ($ut - $lastutime, $st - $laststime);
        $mc->out("utime: $ut (+$udelta)");
        $mc->out("stime: $st (+$sdelta)");
        ($lastutime, $laststime, $lastreqs) = ($ut, $st, $reqs);
    }

    my $rdelta = $reqs - $lastreqs;
    $mc->out("reqs: $reqs (+$rdelta)");
    $lastreqs = $reqs;

    $mc->end;
}

sub MANAGE_nodes {
    my $mc = shift->parse(qr/^nodes?(?:\s+(\d+.\d+.\d+.\d+)(?::(\d+))?)?$/);

    my ($ip, $port) = ($mc->arg(1), $mc->arg(2) || 80);
    my $spec_ipport = $ip ? "$ip:$port" : undef;
    my $ref = \%Perlbal::BackendHTTP::NodeStats;

    my $dump = sub {
        my $ipport = shift;
        foreach my $key (keys %{$ref->{$ipport}}) {
            if (ref $ref->{$ipport}->{$key} eq 'ARRAY') {
                my %temp;
                $temp{$_}++ foreach @{$ref->{$ipport}->{$key}};
                foreach my $tkey (keys %temp) {
                    $mc->out("$ipport $key $tkey $temp{$tkey}");
                }
            } else {
                $mc->out("$ipport $key $ref->{$ipport}->{$key}");
            }
        }
    };

    # dump a node, or all nodes
    if ($spec_ipport) {
        $dump->($spec_ipport);
    } else {
        foreach my $ipport (keys %$ref) {
            $dump->($ipport);
        }
    }

    $mc->end;
}

# singular also works for the nodes command
*MANAGE_node = \&MANAGE_nodes;

sub MANAGE_prof {
    my $mc = shift->parse(qr/^prof\w*\s+(on|off|data)$/);
    my $which = $mc->arg(1);

    if ($which eq 'on') {
        if (Danga::Socket->EnableProfiling) {
            return $mc->ok;
        } else {
            return $mc->err('Unable to enable profiling.  Please ensure you have the BSD::Resource module installed.');
        }
    }

    if ($which eq 'off') {
        Danga::Socket->DisableProfiling;
        return $mc->ok;
    }

    if ($which eq 'data') {
        my $href = Danga::Socket->ProfilingData;
        foreach my $key (sort keys %$href) {
            my ($utime, $stime, $calls) = @{$href->{$key}};
            $mc->out(sprintf("%s %0.5f %0.5f %d %0.7f %0.7f",
                             $key, $utime, $stime, $calls, $utime / $calls, $stime / $calls));
        }
        $mc->end;
    }
}

sub MANAGE_uptime {
    my $mc = shift->no_opts;

    $mc->out("starttime $starttime");
    $mc->out("uptime " . (time() - $starttime));
    $mc->out("version $Perlbal::VERSION");
    $mc->end;
}

*MANAGE_version = \&MANAGE_uptime;

sub MANAGE_track {
    my $mc = shift->no_opts;

    my $now = time();
    my @list;
    foreach (keys %ObjTrack) {
        my $age = $now - $ObjTrack{$_}->[0];
        push @list, [ $age, "${age}s $_: $ObjTrack{$_}->[1]" ];
    }

    # now output based on sorted age
    foreach (sort { $a->[0] <=> $b->[0] } @list) {
        $mc->out($_->[1]);
    }
    $mc->end;
}

sub MANAGE_socks {
    my $mc = shift->parse(qr/^socks(?: (\w+))?$/);
    my $mode = $mc->arg(1) || "all";

    my $sf = Perlbal::Socket->get_sock_ref;

    if ($mode eq "summary") {
        my %count;
        my $write_buf = 0;
        my $open_files = 0;
        while (my $k = each %$sf) {
            my Perlbal::Socket $v = $sf->{$k};
            $count{ref $v}++;
            $write_buf += $v->{write_buf_size};
            if ($v->isa("Perlbal::ClientHTTPBase")) {
                my Perlbal::ClientHTTPBase $cv = $v;
                $open_files++ if $cv->{'reproxy_fh'};
            }
        }

        foreach (sort keys %count) {
            $mc->out(sprintf("%5d $_", $count{$_}));
        }
        $mc->out();
        $mc->out(sprintf("Aggregate write buffer: %.1fk", $write_buf / 1024));
        $mc->out(sprintf("            Open files: %d", $open_files));
    } elsif ($mode eq "all") {
        my $now = time;
        $mc->out(sprintf("%5s %6s", "fd", "age"));
        foreach (sort { $a <=> $b } keys %$sf) {
            my $sock = $sf->{$_};
            my $age;
            eval {
                $age = $now - $sock->{create_time};
            };
            $age ||= 0;
            $mc->out(sprintf("%5d %5ds %s", $_, $age, $sock->as_string));
        }
    }
    $mc->end;
}

sub MANAGE_backends {
    my $mc = shift->no_opts;

    my $sf = Perlbal::Socket->get_sock_ref;
    my %nodes; # { "Backend" => int count }
    foreach my $sock (values %$sf) {
        if ($sock->isa("Perlbal::BackendHTTP")) {
            my Perlbal::BackendHTTP $cv = $sock;
            $nodes{"$cv->{ipport}"}++;
        }
    }

    # now print out text
    foreach my $node (sort keys %nodes) {
        $mc->out("$node " . $nodes{$node});
    }

    $mc->end;
}

sub MANAGE_noverify {
    my $mc = shift->no_opts;

    # shows the amount of time left for each node marked as noverify
    my $now = time;
    foreach my $ipport (keys %Perlbal::BackendHTTP::NoVerify) {
        my $until = $Perlbal::BackendHTTP::NoVerify{$ipport} - $now;
        $mc->out("$ipport $until");
    }
    $mc->end;
}

sub MANAGE_pending {
    my $mc = shift->no_opts;

    # shows pending backend connections by service, node, and age
    my %pend; # { "service" => { "ip:port" => age } }
    my $now = time;

    foreach my $svc (values %service) {
        foreach my $ipport (keys %{$svc->{pending_connects}}) {
            my Perlbal::BackendHTTP $be = $svc->{pending_connects}->{$ipport};
            next unless defined $be;
            $pend{$svc->{name}}->{$ipport} = $now - $be->{create_time};
        }
    }

    foreach my $name (sort keys %pend) {
        foreach my $ipport (sort keys %{$pend{$name}}) {
            $mc->out("$name $ipport $pend{$name}{$ipport}");
        }
    }
    $mc->end;
}

sub MANAGE_states {
    my $mc = shift->parse(qr/^states(?:\s+(.+))?$/);

    my $svc;
    if (defined $mc->arg(1)) {
        $svc = $service{$mc->arg(1)};
        return $mc->err("Service not found.")
            unless defined $svc;
    }

    my $sf = Perlbal::Socket->get_sock_ref;

    my %states; # { "Class" => { "State" => int count; } }
    foreach my $sock (values %$sf) {
        next unless $sock->can('state');
        my $state = $sock->state;
        next unless defined $state;
        if (defined $svc) {
            next unless $sock->isa('Perlbal::ClientProxy') ||
                $sock->isa('Perlbal::BackendHTTP') ||
                $sock->isa('Perlbal::ClientHTTP');
            next unless $sock->{service} == $svc;
        }
        $states{ref $sock}->{$state}++;
    }

    # now print out text
    foreach my $class (sort keys %states) {
        foreach my $state (sort keys %{$states{$class}}) {
            $mc->out("$class $state " . $states{$class}->{$state});
        }
    }
    $mc->end;
}

sub MANAGE_queues {
    my $mc = shift->no_opts;
    my $now = time;

    foreach my $svc (values %service) {
        next unless $svc->{role} eq 'reverse_proxy';

        my %queues = (
            normal  => 'waiting_clients',
            highpri => 'waiting_clients_highpri',
            lowpri  => 'waiting_clients_lowpri',
        );

        while (my ($queue_name, $clients_key) = each %queues) {
            my $age = 0;
            my $count = @{$svc->{$clients_key}};
            my Perlbal::ClientProxy $oldest = $svc->{$clients_key}->[0];
            $age = $now - $oldest->{last_request_time} if defined $oldest;
            $mc->out("$svc->{name}-$queue_name.age $age");
            $mc->out("$svc->{name}-$queue_name.count $count");
        }
    }
    $mc->end;
}

sub MANAGE_state {
    my $mc = shift->parse(qr/^state changes$/);
    my $hr = Perlbal::Socket->get_statechange_ref;
    my %final; # { "state" => count }
    while (my ($obj, $arref) = each %$hr) {
        $mc->out("$obj: " . join(', ', @$arref));
        $final{$arref->[-1]}++;
    }
    foreach my $k (sort keys %final) {
        $mc->out("$k $final{$k}");
    }
    $mc->end;
}

sub MANAGE_leaks {
    my $mc = shift->parse(qr/^leaks(?:\s+(.+))?$/);
    return $mc->err("command disabled without \$ENV{PERLBAL_DEBUG} set")
        unless $ENV{PERLBAL_DEBUG};

    my $what = $mc->arg(1);

    # iterates over active objects.  if you specify an argument, it is treated as code
    # with $_ being the reference to the object.
    # shows objects that we think might have been leaked
    my $ref = Perlbal::Socket::get_created_objects_ref;
    foreach (@$ref) {
        next unless $_; # might be undef!
        if ($what) {
            my $rv = eval "$what";
            return $mc->err("$@") if $@;
            next unless defined $rv;
            $mc->out($rv);
        } else {
            $mc->out($_->as_string);
        }
    }
    $mc->end;
}

sub MANAGE_show {
    my $mc = shift;

    if ($mc->cmd =~ /^show service (\w+)$/) {
        my $sname = $1;
        my Perlbal::Service $svc = $service{$sname};
        return $mc->err("Unknown service") unless $svc;
        $svc->stats_info($mc->out);
        return $mc->end;
    }

    if ($mc->cmd =~ /^show pool(?:\s+(\w+))?$/) {
        my $pool = $1;
        if ($pool) {
            my $pl = $pool{$pool};
            return $mc->err("pool '$pool' does not exist") unless $pl;

            foreach my $node (@{ $pl->nodes }) {
                my $ipport = "$node->[0]:$node->[1]";
                $mc->out($ipport . " " . $pl->node_used($ipport));
            }
        } else {
            foreach my $name (sort keys %pool) {
                my Perlbal::Pool $pl = $pool{$name};
                $mc->out("$name nodes $pl->{node_count}");
                $mc->out("$name services $pl->{use_count}");
            }
        }
        return $mc->end;
    }

    if ($mc->cmd =~ /^show service$/) {
        foreach my $name (sort keys %service) {
            my $svc = $service{$name};
            my $listen = $svc->{listen} || "not_listening";
            $mc->out("$name $listen " . ($svc->{enabled} ? "ENABLED" : "DISABLED"));
        }
        return $mc->end;
    }

    return $mc->parse_error;
}

sub MANAGE_server {
    my $mc = shift->parse(qr/^server (\S+) ?= ?(.+)$/);
    my ($key, $val) = ($mc->arg(1), $mc->arg(2));

    if ($key =~ /^max_reproxy_connections(?:\((.+)\))?/) {
        return $mc->err("Expected numeric parameter") unless $val =~ /^-?\d+$/;
        my $hostip = $1;
        if (defined $hostip) {
            $Perlbal::ReproxyManager::ReproxyMax{$hostip} = $val+0;
        } else {
            $Perlbal::ReproxyManager::ReproxyGlobalMax = $val+0;
        }
        return $mc->ok;
    }

    if ($key eq "max_connections") {
        return $mc->err('This command is not available unless BSD::Resource is installed') unless $Perlbal::BSD_RESOURCE_AVAILABLE;
        return $mc->err("Expected numeric parameter") unless $val =~ /^-?\d+$/;
        my $rv = BSD::Resource::setrlimit(BSD::Resource::RLIMIT_NOFILE(), $val, $val);
        unless (defined $rv && $rv) {
            if ($> == 0) {
                $mc->err("Unable to set limit.");
            } else {
                $mc->err("Need to be root to increase max connections.");
            }
        }
        return $mc->ok;
    }

    if ($key eq "nice_level") {
        return $mc->err("Expected numeric parameter") unless $val =~ /^-?\d+$/;
        my $rv = POSIX::nice($val);
        $mc->err("Unable to renice: $!")
            unless defined $rv;
        return $mc->ok;
    }

    if ($key eq "aio_mode") {
        return $mc->err("Unknown AIO mode") unless $val =~ /^none|linux|ioaio$/;
        return $mc->err("Linux::AIO no longer supported") if $val eq "linux";
        return $mc->err("IO::AIO not available")    if $val eq "ioaio" && ! $Perlbal::OPTMOD_IO_AIO;
        $Perlbal::AIO_MODE = $val;
        return $mc->ok;
    }

    if ($key eq "aio_threads") {
        return $mc->err("Expected numeric parameter") unless $val =~ /^-?\d+$/;
        IO::AIO::min_parallel($val)
            if $Perlbal::OPTMOD_IO_AIO;
        return $mc->ok;
    }

    if ($key eq "track_obj") {
        return $mc->err("Expected 1 or 0") unless $val eq '1' || $val eq '0';
        $track_obj = $val + 0;
        %ObjTrack = () if $val; # if we're turning it on, clear it out
        return $mc->ok;
    }

    if ($key eq "pidfile") {
        return $mc->err("pidfile must be configured at startup, before Perlbal::run is called") if  $run_started;
        return $mc->err("Expected full pathname to pidfile") unless $val;
        $pidfile = $val;
        return $mc->ok;
    }

    if ($key eq "crash_backtrace") {
        return $mc->err("Expected 1 or 0") unless $val eq '1' || $val eq '0';
        if ($val) {
            $SIG{__DIE__} = sub { Carp::confess(@_) };
        } else {
            $SIG{__DIE__} = undef;
        }
        return $mc->ok;
    }

    return $mc->err("unknown server option '$val'");
}

sub MANAGE_dumpconfig {
    my $mc = shift;

    while (my ($name, $pool) = each %pool) {
        $mc->out("CREATE POOL $name");

        if ($pool->can("dumpconfig")) {
            foreach my $line ($pool->dumpconfig) {
                $mc->out("  $line");
            }
        } else {
            my $class = ref($pool);
            $mc->out("  # Pool class '$class' is unable to dump config.");
        }
    } continue {
        $mc->out("");
    }

    while (my ($name, $service) = each %service) {
        $mc->out("CREATE SERVICE $name");

        if ($service->can("dumpconfig")) {
            foreach my $line ($service->dumpconfig) {
                $mc->out("  $line");
            }
        } else {
            my $class = ref($service);
            $mc->out("  # Service class '$class' is unable to dump config.");
        }

        my $state = $service->{enabled} ? "ENABLE" : "DISABLE";
        $mc->out("$state $name");
    } continue {
        $mc->out("");
    }

    return $mc->ok
}

sub MANAGE_reproxy_state {
    my $mc = shift;
    Perlbal::ReproxyManager::dump_state($mc->out);
    return 1;
}

sub MANAGE_create {
    my $mc = shift->parse(qr/^create (service|pool) (\w+)$/,
                          "usage: CREATE {service|pool} <name>");
    my ($what, $name) = $mc->args;

    if ($what eq "service") {
        return $mc->err("service '$name' already exists") if $service{$name};
        return $mc->err("pool '$name' already exists") if $pool{$name};
        Perlbal->create_service($name);
        $mc->{ctx}{last_created} = $name;
        return $mc->ok;
    }

    if ($what eq "pool") {
        return $mc->err("pool '$name' already exists") if $pool{$name};
        return $mc->err("service '$name' already exists") if $service{$name};
        $vivify_pools = 0;
        $pool{$name} = Perlbal::Pool->new($name);
        $mc->{ctx}{last_created} = $name;
        return $mc->ok;
    }
}

sub MANAGE_use {
    my $mc = shift->parse(qr/^use (\w+)$/,
                          "usage: USE <service_or_pool_name>");
    my ($name) = $mc->args;
    return $mc->err("Non-existent pool or service '$name'") unless $pool{$name} || $service{$name};

    $mc->{ctx}{last_created} = $name;
    return $mc->ok;
}

sub MANAGE_pool {
    my $mc = shift->parse(qr/^pool (\w+) (\w+) (\d+.\d+.\d+.\d+)(?::(\d+))?$/);
    my ($cmd, $name, $ip, $port) = $mc->args;
    $port ||= 80;

    my $good_cmd = qr/^(?:add|remove)$/;

    # "add" and "remove" can be in either order
    ($cmd, $name) = ($name, $cmd) if $name =~ /$good_cmd/;
    return $mc->err("Invalid command:  must be 'add' or 'remove'")
        unless $cmd =~ /$good_cmd/;

    my $pl = $pool{$name};
    return $mc->err("Pool '$name' not found") unless $pl;
    $pl->$cmd($ip, $port);
    return $mc->ok;
}

sub MANAGE_default {
    my $mc = shift->parse(qr/^default (\w+) ?= ?(.+)$/,
                          "usage: DEFAULT <param> = <value>");

    my ($key, $val) = $mc->args;
    return Perlbal::Service::set_defaults($mc, $key => $val);
}

sub MANAGE_set {
    my $mc = shift->parse(qr/^set (?:(\w+)[\. ])?([\w\.]+) ?= ?(.+)$/,
                          "usage: SET [<service>] <param> = <value>");
    my ($name, $key, $val) = $mc->args;
    unless ($name ||= $mc->{ctx}{last_created}) {
        return $mc->err("omitted service/pool name not implied from context");
    }

    if (my Perlbal::Service $svc = $service{$name}) {
        return $svc->set($key, $val, $mc);
    } elsif (my Perlbal::Pool $pl = $pool{$name}) {
        return $pl->set($key, $val, $mc);
    }
    return $mc->err("service/pool '$name' does not exist");
}


sub MANAGE_header {
    my $mc = shift->parse(qr/^header\s+(\w+)\s+(insert|remove)\s+(.+?)(?:\s*:\s*(.+))?$/i,
                          "Usage: HEADER <service> {INSERT|REMOVE} <header>[: <value>]");

    my ($svc_name, $action, $header, $val) = $mc->args;
    my $svc = $service{$svc_name};
    return $mc->err("service '$svc_name' does not exist") unless $svc;
    return $svc->header_management($action, $header, $val, $mc);
}

sub MANAGE_enable {
    my $mc = shift->parse(qr/^(disable|enable) (\w+)$/,
                          "Usage: {ENABLE|DISABLE} <service>");
    my ($verb, $name) = $mc->args;
    my $svc = $service{$name};
    return $mc->err("service '$name' does not exist") unless $svc;
    return $svc->$verb($mc);
}
*MANAGE_disable = \&MANAGE_enable;

sub MANAGE_unload {
    my $mc = shift->parse(qr/^unload (\w+)$/);
    my ($fn) = $mc->args;
    $fn = $PluginCase{lc $fn};
    my $rv = eval "Perlbal::Plugin::$fn->unload; 1;";
    $plugins{$fn} = 0;
    return $mc->ok;
}


sub MANAGE_load {
    my $mc = shift->parse(qr/^load \w+$/);

    my $fn;
    $fn = $1 if $mc->orig =~ /^load (\w+)$/i;

    my $last_case;
    my $last_class;

    my $good_error;

    # TODO case protection

    foreach my $name ($fn, lc $fn, ucfirst lc $fn) {
        $last_case = $name;
        my $class = $last_class = "Perlbal::Plugin::$name";
        my $file = $class . ".pm";
        $file =~ s!::!/!g;

        my $rv = eval "use $class; $class->can('load');";

        if ($rv) {
            $good_error = undef;
            last;
        }

        # If we don't have a good error yet, start with this one.
        $good_error = $@ unless defined $good_error;

        # If the file existed perl will place an entry in %INC (though it will be undef due to compilation error)
        if ($@ and exists $INC{$file}) {
            $good_error = $@;
            last;
        }
    }

    unless (defined $good_error) {
        my $rv = eval "$last_class->load; 1;";

        if ($rv) {
            $PluginCase{lc $fn} = $last_case;
            $plugins{$last_case} = $last_class;
            return $mc->ok;
        }

        $good_error = $@;
    }

    return $mc->err($good_error);
}

sub MANAGE_reload {
    my $mc = shift->parse(qr/^reload (\w+)$/);
    my ($fn) = $mc->args;

    my $class = $PluginCase{lc $fn} or
        return $mc->err("Unknown/unloaded plugin '$fn'");
    $class = "Perlbal::Plugin::$class";

    eval "$class->can_reload" or
        return $mc->err("Plugin $class doesn't support reloading");

    if ($class->can("pre_reload_unload")) {
        eval "$class->pre_reload_unload; 1" or
            return $mc->err("Error running $class->pre_reload_unload: $@");
    }

    eval "$class->unload; 1;" or
        return $mc->err("Failed to unload $class: $@");

    my $file = $class . ".pm";
    $file =~ s!::!/!g;

    delete $INC{$file} or
        die $mc->err("Didn't find $file in %INC");

    no warnings 'redefine';
    eval "use $class; $class->load; 1;" or
        return $mc->err("Failed to reload: $@");

    return $mc->ok;
}

sub MANAGE_plugins {
    my $mc = shift->no_opts;
    foreach my $svc (values %service) {
        next unless @{$svc->{plugin_order}};
        $mc->out(join(' ', $svc->{name}, @{$svc->{plugin_order}}));
    }
    $mc->end;
}

sub MANAGE_help {
    my $mc = shift->no_opts;
    my @commands = sort map { m/^MANAGE_(\S+)$/ ? $1 : () }
        keys %Perlbal::;
    foreach my $command (@commands) {
        $mc->out("$command");
    }
    $mc->end;
}

sub MANAGE_aio {
    my $mc = shift->no_opts;
    my $stats = Perlbal::AIO::get_aio_stats();
    foreach my $c (sort keys %$stats) {
        my $r = $stats->{$c};
        foreach my $k (keys %$r) {
            $mc->out("$c $k $r->{$k}");
        }
    }
    $mc->end;
}

sub load_config {
    my ($file, $writer) = @_;
    open (my $fh, $file) or die "Error opening config file ($file): $!\n";
    my $ctx = Perlbal::CommandContext->new;
    $ctx->verbose(0);
    while (my $line = <$fh>) {
        return 0 unless run_manage_command($line, $writer, $ctx);
    }
    close($fh);
    return 1;
}

sub daemonize {
    my($pid, $sess_id, $i);

    # note that we're not in the foreground (for logging purposes)
    $foreground = 0;

    # required before fork: (as of old Linux::AIO 1.1, still true?)
    IO::AIO::max_parallel(0)
        if $Perlbal::OPTMOD_IO_AIO;

    my $sigset = POSIX::SigSet->new(SIGINT);
    sigprocmask(SIG_BLOCK, $sigset)
        or die "Can't block sigint for fork: $!";

    ## Fork and exit parent
    if ($pid = fork) { exit 0; }

    sigprocmask(SIG_UNBLOCK, $sigset)
        or die "Can't unblock sigint after fork: $!";

    ## Detach ourselves from the terminal
    croak "Cannot detach from controlling terminal"
        unless $sess_id = POSIX::setsid();

    # Handler for INT needs to be restored.
    $SIG{INT} = 'DEFAULT';

    ## Change working directory
    chdir "/";

    ## Clear file creation mask
    umask 0;

    ## Close open file descriptors
    close(STDIN);
    close(STDOUT);
    close(STDERR);

    ## Reopen stderr, stdout, stdin to /dev/null
    open(STDIN,  "+>/dev/null");
    open(STDOUT, "+>&STDIN");
    open(STDERR, "+>&STDIN");
}

# For other apps using Danga::Socket that want to embed Perlbal, this can be called
# directly to start it up. You can call this as many times as you like; it'll
# only actually do what it does the first time it's called.
sub initialize {
    unless ($run_started) {
        $run_started = 1;

        # number of AIO threads.  the number of outstanding requests isn't
        # affected by this
        IO::AIO::min_parallel(3)    if $Perlbal::OPTMOD_IO_AIO;

        # register IO::AIO pipe which gets written to from threads
        # doing blocking IO
        if ($Perlbal::OPTMOD_IO_AIO) {
            Perlbal::Socket->AddOtherFds(IO::AIO::poll_fileno() =>
                                         \&IO::AIO::poll_cb);
        }

        # The fact that this only runs the first time someone calls initialize()
        # means that some things which depend on it might be unreliable when
        # used in an embedded perlbal if there is a race for multiple components
        # to call initialize().
        run_global_hook("pre_event_loop");
    }
}

# This is the function to call if you want Perlbal to be in charge of the event loop.
# It won't return until Perlbal is somehow told to exit.
sub run {

    # setup for logging
    Sys::Syslog::openlog('perlbal', 'pid', 'daemon') if $Perlbal::SYSLOG_AVAILABLE;
    $Perlbal::syslog_open = 1;
    Perlbal::log('info', 'beginning run');
    my $pidfile_written = 0;
    $pidfile_written = _write_pidfile( $pidfile ) if $pidfile;

    Perlbal::initialize();

    Danga::Socket->SetLoopTimeout(1000);
    Danga::Socket->SetPostLoopCallback(sub {
        $Perlbal::tick_time = time();
        Perlbal::Socket::run_callbacks();
        return 1;
    });

    # begin the overall loop to try to capture if Perlbal dies at some point
    # so we can have a log of it
    eval {
        # wait for activity
        Perlbal::Socket->EventLoop();
    };

    my $clean_exit = 1;

    # closing messages
    if ($@) {
        Perlbal::log('crit', "crash log: $_") foreach split(/\r?\n/, $@);
        $clean_exit = 0;
    }

    # Note: This will only actually remove the pidfile on 'shutdown graceful'
    # A more reliable approach might be to have a pidfile object which fires
    # removal on DESTROY.
    _remove_pidfile( $pidfile ) if $pidfile_written;

    Perlbal::log('info', 'ending run');
    $Perlbal::syslog_open = 0;
    Sys::Syslog::closelog() if $Perlbal::SYSLOG_AVAILABLE;

    return $clean_exit;
}

sub log {
    # simple logging functionality
    if ($foreground) {
        # syslog acts like printf so we have to use printf and append a \n
        shift; # ignore the first parameter (info, warn, crit, etc)
        my $message = shift;
        if (@_) {
            printf("$message\n", @_);
        } else {
            print("$message\n");
        }
    } else {
        # just pass the parameters to syslog
        Sys::Syslog::syslog(@_) if $Perlbal::syslog_open;
    }
}


sub _write_pidfile {
    my $file = shift;

    my $fh;
    unless (open($fh, ">$file")) {
        Perlbal::log('info', "couldn't create pidfile '$file': $!" );
        return 0;
    }
    unless ((print $fh "$$\n") && close($fh)) {
        Perlbal::log('info', "couldn't write into pidfile '$file': $!" );
        _remove_pidfile($file);
        return 0;
    }
    return 1;
}


sub _remove_pidfile {
    my $file = shift;
    
    unlink $file;
    return 1;
}


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:

1;
