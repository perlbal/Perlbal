package Perlbal::Plugin::Throttle;

use strict;
use warnings;

our $VERSION = '1.20';

use List::Util 'min';
use Danga::Socket 1.59;
use Perlbal 1.70;
use Perlbal::ClientProxy ();
use Perlbal::HTTPHeaders ();
use Time::HiRes ();

# Debugging flag
use constant VERBOSE => $ENV{THROTTLE_VERBOSE} || 0;

sub load {
    # behavior
    Perlbal::Service::add_tunable(
        whitelist_file => {
            check_role => '*',
            des => "File containing CIDRs which are never throttled. (Net::CIDR::Lite must be installed.)",
            check_type => 'file_or_none',
        }
    );
    Perlbal::Service::add_tunable(
        blacklist_file => {
            check_role => '*',
            des => "File containing CIDRs which are always denied outright. (Net::CIDR::Lite must be installed.)",
            check_type => 'file_or_none',
        }
    );
    Perlbal::Service::add_tunable(
        default_action => {
            check_role => '*',
            des => "Whether to throttle or allow new connections from clients on neither the whitelist nor blacklist.",
            check_type => [enum => [qw( allow throttle )]],
            default => 'throttle',
        }
    );
    Perlbal::Service::add_tunable(
        blacklist_action => {
            check_role => '*',
            des => "Whether to deny or throttle connections from blacklisted IPs.",
            check_type => [enum => [qw( deny throttle )]],
            default => 'deny',
        }
    );

    # filters
    Perlbal::Service::add_tunable(
        path_regex => {
            check_role => '*',
            des => "Regex which path portion of URI must match for throttling to be in effect.",
        }
    );
    Perlbal::Service::add_tunable(
        method_regex => {
            check_role => '*',
            des => "Regex which HTTP method must match for throttling to be in effect.",
        }
    );

    # logging
    Perlbal::Service::add_tunable(
        log_events => {
            check_role => '*',
            des => q{Comma-separated list of events to log (ban, unban, whitelisted, blacklisted, concurrent, throttled, banned; all; none). If this is changed after the plugin is registered, the "throttle reload config" command must be issued.},
            check_type => [regexp => qr/^(ban|unban|whitelisted|blacklisted|concurrent|throttled|banned|all|none| |,)+$/, "log_events is a comma-separated list of loggable events"],
            default => 'all',
        }
    );
    Perlbal::Service::add_tunable(
        log_only => {
            check_role => '*',
            des => "Perform the full throttling calculation, but don't actually throttle or deny connections.",
            check_type => 'bool',
            default => 0,
        }
    );

    # throttler parameters
    Perlbal::Service::add_tunable(
        throttle_threshold_seconds => {
            check_role => '*',
            des => "Minimum allowable time between requests. If a non-white/-blacklisted client makes another connection within this interval, it will be throttled for initial_delay seconds. Further connections will double the delay time.",
            check_type => 'int',
            default => 60,
        }
    );
    Perlbal::Service::add_tunable(
        initial_delay => {
            check_role => '*',
            des => "Minimum time for a connection to be throttled if occurring within throttle_threshold_seconds of last attempt.",
            check_type => 'int',
            default => 3,
        }
    );
    Perlbal::Service::add_tunable(
        max_delay => {
            check_role => '*',
            des => "Maximum time for a connection to be throttled after exponential increase from initial_delay.",
            check_type => 'int',
            default => 300,
        }
    );
    Perlbal::Service::add_tunable(
        max_concurrent => {
            check_role => '*',
            des => "Maximum number of connections accepted at a time from a single IP, per perlbal instance.",
            check_type => 'int',
            default => 2,
        }
    );
    Perlbal::Service::add_tunable(
        ban_threshold => {
            check_role => '*',
            des => "Number of accumulated violations required to temporarily ban the source IP.",
            check_type => 'int',
            default => 0,
        }
    );
    Perlbal::Service::add_tunable(
        ban_expiration => {
            check_role => '*',
            des => "Number of seconds after which banned IP is unbanned.",
            check_type => 'int',
            default => 60,
        }
    );

    # memcached
    Perlbal::Service::add_tunable(
        memcached_servers => {
            check_role => '*',
            des => "List of memcached servers to share state in, if desired. (Cache::Memcached::Async must be installed.)",
        }
    );
    Perlbal::Service::add_tunable(
        memcached_async_clients => {
            check_role => '*',
            des => "Number of parallel Cache::Memcached::Async objects to use.",
            check_type => 'int',
            default => 10,
        }
    );
    Perlbal::Service::add_tunable(
        instance_name => {
            check_role => '*',
            des => "Name of throttler instance; instances with the same name will share knowledge of IPs.",
            default => 'Throttle',
        }
    );

    Perlbal::register_global_hook('manage_command.throttle', sub {
        my $mc = shift->parse(qr/^
                              throttle\s+
                              (reload)\s+ # command
                              (whitelist|blacklist|config)
                              $/xi,
                              "usage: throttle reload <config|whitelist|blacklist>");
        my ($cmd, $what) = $mc->args;

        my $svcname = $mc->{ctx}{last_created};
        unless ($svcname) {
            return $mc->err("No service name set. This command must be used after CREATE SERVICE <name> or USE <service_name>");
        }

        my $ss = Perlbal->service($svcname);
        return $mc->err("Non-existent service '$svcname'") unless $ss;

        my $cfg = $ss->{extra_config} ||= {};
        my $stash = $cfg->{_throttle_stash} ||= {};

        if ($cmd eq 'reload') {
            if ($what eq 'whitelist') {
                if (my $whitelist = $cfg->{whitelist_file}) {
                    eval { $stash->{whitelist} = load_cidr_list($whitelist); };
                    return $mc->err("Couldn't load $whitelist: $@")
                        if $@ || !$stash->{whitelist};
                }
                else {
                    return $mc->err("no whitelist file configured");
                }
            }
            elsif ($what eq 'blacklist') {
                if (my $blacklist = $cfg->{blacklist_file}) {
                    eval { $stash->{blacklist} = load_cidr_list($blacklist); };
                    return $mc->err("Couldn't load $blacklist: $@")
                        if $@ || !$stash->{blacklist};
                }
                else {
                    return $mc->err("no blacklist file configured");
                }
            }
            elsif ($what eq 'config') {
                $stash->{config_reloader}->();
            }
            else {
                return $mc->err("unknown object to reload: $what");
            }
        }
        else {
            return $mc->err("unknown command $cmd");
        }

        return $mc->ok;
    });
}

# magical Perlbal hook return value constants
use constant HANDLE_REQUEST             => 0;
use constant IGNORE_REQUEST             => 1;

# indexes into logging flag list
use constant LOG_BAN_ADDED              => 0;
use constant LOG_BAN_REMOVED            => 1;
use constant LOG_ALLOW_WHITELISTED      => 2;
use constant LOG_ALLOW_DEFAULT          => 3;
use constant LOG_DENY_BANNED            => 4;
use constant LOG_DENY_BLACKLISTED       => 5;
use constant LOG_DENY_CONCURRENT        => 6;
use constant LOG_THROTTLE_BLACKLISTED   => 7;
use constant LOG_THROTTLE_DEFAULT       => 8;
use constant NUM_LOG_FLAGS              => 9;

use constant RESULT_ALLOW               => 0;
use constant RESULT_THROTTLE            => 1;
use constant RESULT_DENY                => 2;

# localized variable to track if a connection has already been throttled
our $DELAYED = undef;

sub register {
    my ($class, $svc) = @_;

    VERBOSE and Perlbal::log(info => "Registering Throttle plugin on service $svc->{name}");

    my $cfg   = $svc->{extra_config}    ||= {};
    my $stash = $cfg->{_throttle_stash} ||= {};

    # these are allowed to die at register time
    $stash->{whitelist} = load_cidr_list($cfg->{whitelist_file}) if $cfg->{whitelist_file};
    $stash->{blacklist} = load_cidr_list($cfg->{blacklist_file}) if $cfg->{blacklist_file};

    # several service tunables are cached in lexicals for efficiency. if these
    # are changed, the "throttle reload config" command must be issued to
    # update the cache. this implements the reloading (and initial loading).
    my ($log, $path_regex, $method_regex);
    my $loader = $stash->{config_reloader} = sub {
        my @log_on_cfg = grep {length} split /[, ]+/, lc $cfg->{log_events};
        my @log_events = (0) x NUM_LOG_FLAGS;
        for (@log_on_cfg) {
            $log_events[LOG_BAN_ADDED]              = 1 if $_ eq 'ban';
            $log_events[LOG_BAN_REMOVED]            = 1 if $_ eq 'unban';
            $log_events[LOG_ALLOW_WHITELISTED]      = 1 if $_ eq 'whitelisted';
            $log_events[LOG_DENY_BANNED]            = 1 if $_ eq 'banned';
            $log_events[LOG_DENY_BLACKLISTED]       =
            $log_events[LOG_THROTTLE_BLACKLISTED]   = 1 if $_ eq 'blacklisted';
            $log_events[LOG_DENY_CONCURRENT]        = 1 if $_ eq 'concurrent';
            $log_events[LOG_THROTTLE_DEFAULT]       = 1 if $_ eq 'throttled';
            @log_events = (1) x NUM_LOG_FLAGS           if $_ eq 'all';
            @log_events = (0) x NUM_LOG_FLAGS           if $_ eq 'none';
        }

        $log = sub {};
        if (grep {$_} @log_events) {
            my $has_syslogger = eval { require Perlbal::Plugin::Syslogger; 1 };
            if ($has_syslogger && $cfg->{syslog_host}) {
                VERBOSE and Perlbal::log(info => "Using Perlbal::Plugin::Syslogger");
                $log = sub {
                    my $action = shift;
                    return unless $log_events[$action];
                    Perlbal::Plugin::Syslogger::send_syslog_msg($svc, @_);
                };
            }
            else {
                VERBOSE and Perlbal::log(warn => "Syslogger plugin unavailable, using Perlbal::log");
                $log = sub {
                    my $action = shift;
                    return unless $log_events[$action];
                    Perlbal::log(info => @_);
                };
            }
        }

        $path_regex   = $cfg->{path_regex}   ? qr/$cfg->{path_regex}/   : undef;
        $method_regex = $cfg->{method_regex} ? qr/$cfg->{method_regex}/ : undef;
    };
    $loader->();

    # structures for tracking IP states
    my %throttled;
    my %banned;
    my $store = Perlbal::Plugin::Throttle::Store->new($cfg);

    my $start_handler = sub {
        my $retval = eval {
            my $request_start = Time::HiRes::time;

            VERBOSE and Perlbal::log(info => "In Throttle (%s)",
                defined $DELAYED ? sprintf 'back after %.2fs', $DELAYED : 'initial'
            );

            my Perlbal::ClientProxy $cp = shift;
            unless ($cp) {
                VERBOSE and Perlbal::log(error => "Missing ClientProxy");
                return HANDLE_REQUEST;
            }

            my $headers = $cp->{req_headers};
            unless ($headers) {
                VERBOSE and Perlbal::log(info => "Missing headers");
                return HANDLE_REQUEST;
            }
            my $uri    = $headers->request_uri;
            my $method = $headers->request_method;

            my $ip = $cp->observed_ip_string() || $cp->peer_ip_string;
            unless (defined $ip) {
                # happens if client goes away
                VERBOSE and Perlbal::log(warn => "Client went away");
                $cp->send_response(500, "Internal server error.\n");
                return IGNORE_REQUEST;
            }

            # back from throttling, all later checks were already passed
            return HANDLE_REQUEST if defined $DELAYED;

            # increment the count of throttled conns
            $throttled{$ip}++;

            my $result = sub {
                # immediately passthrough whitelistees
                if ($stash->{whitelist} && $stash->{whitelist}->find($ip)) {
                    $log->(LOG_ALLOW_WHITELISTED, "Letting whitelisted ip $ip through");
                    return RESULT_ALLOW;
                }

                # drop conns from banned IPs
                if ($banned{$ip}) {
                    $log->(LOG_DENY_BANNED, "Denying banned IP $ip");
                    return RESULT_DENY;
                }

                # drop conns from banned/blacklisted IPs
                if ($stash->{blacklist} && $stash->{blacklist}->find($ip)) {
                    if ($cfg->{blacklist_action} eq 'deny') {
                        $log->(LOG_DENY_BLACKLISTED, "Denying blacklisted IP $ip");
                        return RESULT_DENY;
                    }
                    else {
                        $log->(LOG_THROTTLE_BLACKLISTED, "Throttling blacklisted IP $ip");
                        return RESULT_THROTTLE;
                    }
                }

                if (exists $throttled{$ip} && $throttled{$ip} > $cfg->{max_concurrent}) {
                    $log->(LOG_DENY_CONCURRENT, "Too many concurrent connections from $ip");
                    return RESULT_DENY;
                }

                # only throttle matching requests
                if (defined $path_regex && $uri !~ $path_regex) {
                    VERBOSE && Perlbal::log(info => "This isn't a throttled URL: %s", $uri);
                    return RESULT_ALLOW;
                }
                if (defined $method_regex && $method !~ $method_regex) {
                    VERBOSE && Perlbal::log(info => "This isn't a throttled method: %s", $method);
                    return RESULT_ALLOW;
                }

                return $cfg->{default_action} eq 'allow' ? RESULT_ALLOW : RESULT_THROTTLE;
            }->();

            if ($result == RESULT_DENY) {
                unless ($cfg->{log_only}) {
                    $cp->send_response(403, "Forbidden.\n");
                    return IGNORE_REQUEST;
                }
            }
            elsif ($result == RESULT_ALLOW) {
                return HANDLE_REQUEST;
            }

            # now entering throttle path...

            # check if we've seen this IP lately.
            my $key = $cfg->{instance_name} . $ip;
            $store->get(key => $key, timeout => $cfg->{initial_delay}, callback => sub {
                my ($last_request_time, $violations) = @_;
                $violations ||= 0;

                # do an early set to update the last_request_time and
                # expiration in case of early exit
                $store->set(
                    key     => $key,
                    start   => $request_start,
                    count   => $violations,
                    exptime => $cfg->{throttle_threshold_seconds},
                    timeout => $cfg->{initial_delay},
                );

                my $time_since_last_request;
                if (defined $last_request_time) {
                    $time_since_last_request = $request_start - $last_request_time;
                }

                VERBOSE and Perlbal::log(
                    info => "%s; this request at %.3f; last at %s; interval is %s",
                    $ip, $request_start,
                    $last_request_time || 'n/a', $time_since_last_request || 'n/a'
                );

                my $handle_after = sub {
                    my $delay = shift;
                    $delay = 0 if $cfg->{log_only};

                    # put request on the backburner
                    $cp->watch_read(0);
                    Danga::Socket->AddTimer($delay, sub {
                        # we're now executing in a timer callback after
                        # perlbal has been told to ignore the request. so if we
                        # now want it handled it needs to be re-adopted.
                        local $DELAYED = $delay; # to short-circuit throttling logic on the next pass through
                        $cp->watch_read(1);
                        $svc->adopt_base_client($cp);
                    });

                    return IGNORE_REQUEST;
                };

                # can we let it through immediately?
                unless (defined $time_since_last_request) {
                    # forgotten or haven't seen ip before
                    $log->(LOG_ALLOW_DEFAULT, "Allowed unseen $ip");
                    return $handle_after->(0);
                }
                if ($time_since_last_request >= $cfg->{throttle_threshold_seconds}) {
                    # waited long enough
                    $log->(LOG_ALLOW_DEFAULT, "Allowed reformed $ip");
                    return $handle_after->(0);
                }

                # need to throttle, now figure out by how much. at least
                # initial_delay, at most max_delay, exponentially increasing in
                # between
                my $delay = min($cfg->{initial_delay} * 2**$violations, $cfg->{max_delay});

                $violations++;

                # banhammer for great justice
                if ($cfg->{ban_threshold} && $violations >= $cfg->{ban_threshold}) {
                    $log->(LOG_BAN_ADDED, "Banning $ip for $cfg->{ban_expiration}s: %s", $uri);
                    $banned{$ip}++ unless $cfg->{log_only};
                    Danga::Socket->AddTimer($cfg->{ban_expiration}, sub {
                        $log->(LOG_BAN_REMOVED, "Unbanning $ip");
                        delete $banned{$ip};
                    });
                    $cp->close;
                    return IGNORE_REQUEST;
                }

                $store->set(
                    key     => $key,
                    start   => $request_start,
                    count   => $violations,
                    exptime => $delay,
                    timeout => $cfg->{initial_delay},
                );

                $log->(LOG_THROTTLE_DEFAULT, "Throttling $ip for $delay: %s", $uri);

                # schedule request to be re-handled
                return $handle_after->($delay);
            });

            # make sure we don't take up reading until readoption
            $cp->watch_read(0);
            return IGNORE_REQUEST;
        };
        if ($@) {
            # if something horrible should happen internally, don't take out perlbal
            Perlbal::log(err => "Throttle failed: '%s'", $@);
            return HANDLE_REQUEST;
        }
        else {
            return $retval;
        }
    };

    my $end_handler = sub {
        my Perlbal::ClientProxy $cp = shift;

        my $ip = $cp->observed_ip_string() || $cp->peer_ip_string;
        return unless $ip;

        delete $throttled{$ip} unless --$throttled{$ip} > 0;
    };

    $svc->register_hook(Throttle => start_proxy_request => $start_handler);
    $svc->register_hook(Throttle => end_proxy_request   => $end_handler);
}

sub load_cidr_list {
    my $file = shift;

    require Net::CIDR::Lite;

    my $empty = 1;
    my $list = Net::CIDR::Lite->new;

    open my $fh, '<', $file or die "Unable to open file $file: $!";
    while (my $line = <$fh>) {
        $line =~ s/#.*//; # comments
        if ($line =~ /([0-9\/\.]+)/) {
            my $cidr = $1;
            if (index($cidr, "/") < 0) {
                # slash-less specifications are assumed to be singular IPs
                $list->add_ip($cidr);
            }
            else {
                $list->add($cidr);
            }
            $empty = 0;
        }
    }

    die "$file contains no recognizable CIDRs\n" if $empty;

    return $list;
}

package Perlbal::Plugin::Throttle::Store;

sub new {
    my $class = shift;
    my $cfg = shift;

    my $want_memcached = $cfg->{memcached_servers};
    my $has_memcached = eval { require Cache::Memcached::Async; 1 };

    if ($want_memcached && !$has_memcached) {
        die "memcached support requested but Cache::Memcached::Async failed to load: $@\n";
    }
    return $want_memcached
        ? Perlbal::Plugin::Throttle::Store::Memcached->new($cfg)
        : Perlbal::Plugin::Throttle::Store::Memory->new($cfg);
}

package Perlbal::Plugin::Throttle::Store::Memcached;

sub new {
    my $class = shift;
    my $cfg = shift;

    my @servers = split /[,\s]+/, $cfg->{memcached_servers};
    my @cxns = map {
        Cache::Memcached::Async->new({ servers => \@servers })
    } 1 .. $cfg->{memcached_async_clients};

    return bless \@cxns, $class;
}

sub get {
    my $self = shift;
    my %p = @_;
    $self->[rand @$self]->get(
        $p{key},
        timeout => $p{timeout},
        callback => sub {
            my $value = shift;
            return $p{callback}->() unless $value;
            return $p{callback}->(unpack('FS', $value));
        },
    );
    return;
}

sub set {
    my $self = shift;
    my %p = @_;

    $self->[rand @$self]->set(
        $p{key} => pack('FS', $p{start}, $p{count}),
        exptime => $p{exptime},
        timeout => $p{timeout},
    );
}

package Perlbal::Plugin::Throttle::Store::Memory;

use Time::HiRes 'time';

sub new {
    my $class = shift;
    my $cfg = shift;
    return bless {}, $class;
}

sub get {
    my $self = shift;
    my %p = @_;
    my $entry = $self->{$p{key}};

    return $p{callback}->($entry->[1], $entry->[2]) if $entry && time < $entry->[0];
    return $p{callback}->();
}

sub set {
    my $self = shift;
    my %p = @_;
    $self->{$p{key}} = [time + $p{exptime}, $p{start}, $p{count}];
    return;
}

1;

__END__

=head1 NAME

Perlbal::Plugin::Throttle - Perlbal plugin that throttles connections from
hosts that connect too frequently.

=head1 SYNOPSIS

    # in perlbal.conf

    LOAD Throttle

    CREATE POOL web
        POOL web ADD 10.0.0.1:80

    CREATE SERVICE throttler
        SET role                        = reverse_proxy
        SET listen                      = 0.0.0.0:80
        SET pool                        = web

        # adjust throttler aggressiveness
        SET initial_delay               = 10
        SET max_delay                   = 60
        SET throttle_threshold_seconds  = 3
        SET max_concurrent              = 2
        SET ban_threshold               = 4
        SET ban_expiration              = 180

        # limit which requests are throttled
        SET path_regex                  = ^/webapp/
        SET method_regex                = ^GET$

        # allow or ban specific addresses or range (requires Net::CIDR::Lite)
        SET whitelist_file              = conf/whitelist.txt
        SET blacklist_file              = conf/blacklist.txt

        # granular logging (requires Perlbal::Plugin::Syslogger)
        SET log_events                  = ban,unban,throttled,banned
        SET log_only                    = false

        # share state between perlbals (requires Cache::Memcached::Async)
        SET memcached_servers           = 10.0.2.1:11211,10.0.2.2:11211
        SET memcached_async_clients     = 4
        SET instance_name               = mywebapp

        SET plugins                     = Throttle
    ENABLE throttler

=head1 DESCRIPTION

This plugin intercepts HTTP requests to a Perlbal service and slows or drops
connections from IP addresses which are determined to be connecting too fast.

=head1 BEHAVIOR

An IP address address may be in one of four states depending on its recent
activity; that state determines how new requests from the IP are handled:

=over 4

=item * B<allowed>

An IP begins in the B<allowed> state. When a request is received from an IP in
this state, the request is handled immediately and the IP enters the
B<probation> state.

=item * B<probation>

If no requests are received from an IP in the B<probation> state for
I<throttle_threshold_seconds>, it returns to the B<allowed> state.

When a new request is received from an IP in the B<probation> state, the IP
enters the B<throttled> state and is assigned a I<delay> property initially
equal to I<initial_delay>. Connection to a backend is postponed for I<delay>
seconds while perlbal continues to work. If the connection is still open after
the delay, the request is then handled normally. A dropped connection does not
change the IP's I<delay> value.

=item * B<throttled>

If no requests are received from an IP in the B<throttled> state for
I<delay> seconds, it returns to the B<probation> state.

When a new request is received from an IP in the B<throttled> state, its
I<violations> property is incremented, and its I<delay> property is
doubled (up to a maximum of I<max_delay>). The request is postponed for the new
value of I<delay>.

Only after the most recently created connection from a given IP exits the
B<throttled> state do I<violations> and I<delay> reset to 0.

Furthermore, if the I<violations> exceeds I<ban_threshold>, the connection
is closed and the IP moves to the B<banned> state.

IPs in the B<throttled> state may have no more than I<max_concurrent>
connections being delayed at once. Any additional requests received in that
circumstance are sent a "503 Too many connections" response. Long-running
requests which have already been connected to a backend do not count towards
this limit.

=item * B<banned>

New connections from IPs in the banned state are immediately closed with a 403
error response.

An IP leaves the B<banned> state after I<ban_expiration> seconds have
elapsed.

=back

=head1 FEATURES

=over 4

=item * IP whitelist

Connections from IPs/CIDRs listed in the file specified by I<whitelist_file>
are always allowed.

=item * IP blacklist

Connections from IPs/CIDRs listed in the file specified by I<blacklist_file>
immediately sent a "403 Forbidden" response.

=item * Flexible attack response

For services where throttling should not normally be enabled, use the
I<default_action> tunable. When I<default_action> is set to "allow", new
connections from non-white/blacklisted IPs will not be throttled.

Furthermore, if throttling should only apply to specific clients, set
I<blacklist_action> to "throttle". Blacklisted connections will then be
throttled instead of denied.

=item * Dynamic configuration

Most service tunables may be updated from the management port, after which the
new values will be respected (although see L</CAVEATS>). To reload the
whitelist and blacklist files, issue the I<throttle reload whitelist> or
I<throttle reload blacklist> command to the service.

=item * Path specificity

Throttling may be restricted to URI paths matching the I<path_regex> regex.

=item * External shared state

The plugin stores state which IPs have been seen in a memcached(1) instance.
This allows many throttlers to share their state and also minimizes memory use
within the perlbal. If state exceeds the capacity of the memcacheds, the
least-recently seen IPs will be forgotten, effectively resetting them to the
B<allowed> state.

Orthogonally, multiple throttlers which need to share memcacheds but not state
may specify distinct I<instance_name> values.

=item * Logging

If Perlbal::Plugin::Syslogger is installed and registered with the service,
Throttle can use it to send syslog messages regarding actions that are taken.
Granular control for which events are logged is available via the I<log_events>
parameter. I<log_events> is composed of one or more of the following events,
separated by commas:

=over 4

=item * ban

Log when a temporary local ban is added for an IP address.

=item * unban

Log when a temporary local ban is removed for an IP address.

=item * whitelisted

Log when a request is allowed because the source IP is on the whitelist.

=item * blacklisted

Log when a request is denied or throttled because the source IP is on the
blacklist.

=item * banned

Log when a request is denied because the source IP is on the temporary ban list
for connecting excessively.

=item * concurrent

Log when a request is denied because the source IP has too many open connections
waiting to be unthrottled.

=item * throttled

Log when a request is throttled because the source IP was not on the whitelist
or blacklist.

=item * all

Enables all the above logging options.

=item * none

Disables all the above logging options.

=back

=back

=head1 CAVEATS

=over 4

=item * Dynamic configuration changes

Changes to certain service tunables will not be noticed until the B<throttle
reload config> management command is issued. These include I<log_events>,
I<path_regex>, and I<method_regex>).

Changes to certain other tunables will not be respected after the plugin has
been registered. These include I<memcached_servers> and
I<memcached_async_clients>.

=item * List loading is blocking

The I<throttle reload whitelist> and I<throttle reload blacklist> management
commands load the whitelist and blacklist files synchronously, which will cause
the perlbal to hang until it completes.

=item * Redirects

If a handled request returns a 30x response code and the redirect URI is also
throttled, then the client's attempt to follow the redirect will necessarily be
delayed by I<initial_delay>. Fixing this would require that the plugin inspect
the HTTP response headers, which would incur a lot of overhead. To workaround,
try to have your backend not return 30x's if both the original and redirect URI
are proxied by the same throttler instance (yes, this is difficult for the case
where a backend 302s to add a trailing / to a directory).

=back

=head1 OPTIONAL DEPENDENCIES

=over 4

=item * Cache::Memcached::Async

Required for memcached support. This is the supported way to share state
between different perlbal instances.

=item * Net::CIDR::Lite

Required for blacklist/whitelist support.

=item * Perlbal::Plugin::Syslogger

Required for event logging support.

=back

=head1 SEE ALSO

=over 4

=item * List of tunables in Throttle.pm.

=back

=head1 TODO

=over 4

=item * Fix white/blacklist loading

Load CIDR lists asynchronously (perhaps in the manner of
Perlbal::Pool::_load_nodefile_async).

=back

=head1 AUTHOR

Adam Thomason, E<lt>athomason@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2007-2011 by Say Media Inc, E<lt>cpan@sixapart.comE<gt>

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself, either Perl version 5.8.6 or, at your option,
any later version of Perl 5 you may have available.

=cut
