######################################################################
# Service class
######################################################################
#
# Copyright 2004, Danga Interactive, Inc.
# Copyright 2005-2007, Six Apart, Ltd.
#

package Perlbal::Service;
use strict;
use warnings;
no  warnings qw(deprecated);

use Perlbal::BackendHTTP;
use Perlbal::Cache;
use Perlbal::Util;
use fields (
            'name',            # scalar: name of this service
            'role',            # scalar: role type 'web_server', 'reverse_proxy', etc...
            'enabled',         # scalar: bool, whether we're enabled or not (enabled = listening)

            'pool',            # Perlbal::Pool that we're using to allocate nodes if we're in proxy mode
            'listener',        # Perlbal::TCPListener object, when enabled
            'reproxy_cache',             # Perlbal::Cache object, when enabled

            # end-user tunables
            'listen',             # scalar IP:port of where we're listening for new connections
            'docroot',            # document root for webserver role
            'dirindexing',        # bool: directory indexing?  (for webserver role)  not async.
            'index_files',        # arrayref of filenames to try for index files
            'enable_concatenate_get',   # bool:  if user can request concatenated files
            'enable_put', # bool: whether PUT is supported
            'enable_md5', # bool: whether Content-MD5 is supported on PUT
            'max_put_size', # int: max size in bytes of a put file
            'max_chunked_request_size',  # int: max size in bytes of a chunked request (to be written to disk first)
            'min_put_directory', # int: number of directories required to exist at beginning of URIs in put
            'enable_delete', # bool: whether DELETE is supported
            'high_priority_cookie',          # cookie name to check if client can 'cut in line' and get backends faster
            'high_priority_cookie_contents', # aforementioned cookie value must contain this substring
            'backend_persist_cache',   # scalar: max number of persistent backends to hold onto while no clients
            'persist_client',  # bool: persistent connections for clients
            'persist_backend', # bool: persistent connections for backends
            'verify_backend',  # bool: get attention of backend before giving it clients (using OPTIONS)
            'verify_backend_path', # path to check with the OPTIONS request (default *)
            'max_backend_uses',  # max requests to send per kept-alive backend (default 0 = unlimited)
            'connect_ahead',           # scalar: number of spare backends to connect to in advance all the time
            'buffer_size', # int: specifies how much data a ClientProxy object should buffer from a backend
            'buffer_size_reproxy_url', # int: same as above but for backends that are reproxying for us
            'queue_relief_size', # int; number of outstanding standard priority
                                 # connections to activate pressure relief at
            'queue_relief_chance', # int:0-100; % chance to take a standard priority
                                   # request when we're in pressure relief mode
            'trusted_upstream_proxies', # Net::Netmask object containing netmasks for trusted upstreams
            'always_trusted', # bool; if true, always trust upstreams
            'blind_proxy', # bool: if true, do not modify X-Forwarded-For, X-Host, or X-Forwarded-Host headers
            'enable_reproxy', # bool; if true, advertise that server will reproxy files and/or URLs
            'reproxy_cache_maxsize', # int; maximum number of reproxy results to be cached. (0 is disabled and default)
            'client_sndbuf_size',    # int: bytes for SO_SNDBUF
            'server_process' ,       # scalar: path to server process (executable)
            'persist_client_idle_timeout',  # int: keep-alive timeout in seconds for clients (default is 30)
            'idle_timeout',                 # int: idle timeout outside of keep-alive time (default is 30)

            # Internal state:
            'waiting_clients',         # arrayref of clients waiting for backendhttp conns
            'waiting_clients_highpri', # arrayref of high-priority clients waiting for backendhttp conns
            'waiting_clients_lowpri',  # arrayref of low-priority clients waiting for backendhttp conns
            'waiting_client_count',    # number of clients waiting for backends
            'waiting_client_map'  ,    # map of clientproxy fd -> 1 (if they're waiting for a conn)
            'pending_connects',        # hashref of "ip:port" -> $time (only one pending connect to backend at a time)
            'pending_connect_count',   # number of outstanding backend connects
            'bored_backends',          # arrayref of backends we've already connected to, but haven't got clients
            'hooks',    # hashref: hookname => [ [ plugin, ref ], [ plugin, ref ], ... ]
            'plugins',  # hashref: name => 1
            'plugin_order', # arrayref: name, name, name...
            'plugin_setters', # hashref: { plugin_name => { key_name => coderef } }
            'extra_config', # hashref: extra config options; name => values
            'spawn_lock', # bool: if true, we're currently in spawn_backends
            'extra_headers', # { insert => [ [ header, value ], ... ], remove => [ header, header, ... ],
                             #   set => [ [ header, value ], ... ] }; used in header management interface
            'generation', # int; generation count so we can slough off backends from old pools
            'backend_no_spawn', # { "ip:port" => 1 }; if on, spawn_backends will ignore this ip:port combo
            'buffer_backend_connect', # 0 for of, else, number of bytes to buffer before we ask for a backend
            'selector',    # CODE ref, or undef, for role 'selector' services
            'default_service', # Perlbal::Service; name of a service a selector should default to
            'buffer_uploads', # bool; enable/disable the buffered uploads to disk system
            'buffer_uploads_path', # string; path to store buffered upload files
            'buffer_upload_threshold_time', # int; buffer uploads estimated to take longer than this
            'buffer_upload_threshold_size', # int; buffer uploads greater than this size (in bytes)
            'buffer_upload_threshold_rate', # int; buffer uploads uploading at less than this rate (in bytes/sec)

            'upload_status_listeners',  # string: comma separated list of ip:port of UDP upload status receivers
            'upload_status_listeners_sockaddr',  # arrayref of sockaddrs (packed ip/port)

            'enable_ssl',         # bool: whether this service speaks SSL to the client
            'ssl_key_file',       # file:  path to key pem file
            'ssl_cert_file',      # file:  path to key pem file
            'ssl_cipher_list',    # OpenSSL cipher list string
            'ssl_ca_path',        # directory:  path to certificates
            'ssl_verify_mode',    # int:  verification mode, see IO::Socket::SSL documentation 

            'enable_error_retries',  # bool: whether we should retry requests after errors
            'error_retry_schedule',  # string of comma-separated seconds (full or partial) to delay between retries
            'latency',               # int: milliseconds of latency to add to request
            'server_tokens',         # bool: whether to provide a "Server" header

            # stats:
            '_stat_requests',       # total requests to this service
            '_stat_cache_hits',     # total requests to this service that were served via the reproxy-url cache
            );

# hash; 'role' => coderef to instantiate a client for this role
our %PluginRoles;

# used by set_defaults
our $defaults = {};

our $tunables = {

    'role' => {
        des => "What type of service.  One of 'reverse_proxy' for a service that load balances to a pool of backend webserver nodes, 'web_server' for a typical webserver', 'management' for a Perlbal management interface (speaks both command-line or HTTP, auto-detected), or 'selector', for a virtual service that maps onto other services.",
        required => 1,

        check_type => sub {
            my ($self, $val, $errref) = @_;
            return 0 unless $val;
            return 1 if $val =~ /^(?:reverse_proxy|web_server|management|selector|upload_tracker)$/;
            return 1 if $PluginRoles{$val};
            $$errref = "Role not valid for service $self->{name}";
            return 0;
        },
        check_role => '*',
        setter => sub {
            my ($self, $val, $set, $mc) = @_;
            my $rv = $set->();
            $self->init;  # now that service role is set
            return $rv;
        },
    },

    'listen' => {
        check_role => "*",
        des => "The ip:port to listen on.  For a service to work, you must either make it listen, or make another selector service map to a non-listening service.",
        check_type => ["regexp", qr/^(\d+\.\d+\.\d+\.\d+:)?\d+$/,
                       "Listen argument must be ip:port or port. " .
                       "e.g. 192.168.0.1:80 or 81"],
        setter => sub {
            my ($self, $val, $set, $mc) = @_;

            # close/reopen listening socket
            if ($val ne ($self->{listen} || "") && $self->{enabled}) {
                $self->disable(undef, "force");
                $self->{listen} = $val;
                $self->enable(undef);
            }

            return $set->();
        },
    },

    'backend_persist_cache' => {
        des => "The number of backend connections to keep alive on reserve while there are no clients.",
        check_type => "int",
        default => 2,
        check_role => "reverse_proxy",
    },

    'persist_client' => {
        des => "Whether to enable HTTP keep-alives to the end user.",
        default => 0,
        check_type => "bool",
        check_role => "*",
    },

    'persist_backend' => {
        des => "Whether to enable HTTP keep-alives to the backend webnodes.  (Off by default, but highly recommended if Perlbal will be the only client to your backends.  If not, beware that Perlbal will hog the connections, starving other clients.)",
        default => 0,
        check_type => "bool",
        check_role => "reverse_proxy",
    },

    'verify_backend' => {
        des => "Whether Perlbal should send a quick OPTIONS request to the backends before sending an actual client request to them.  If your backend is Apache or some other process-based webserver, this is HIGHLY recommended.  All too often a loaded backend box will reply to new TCP connections, but it's the kernel's TCP stack Perlbal is talking to, not an actual Apache process yet.  Using this option reduces end-user latency a ton on loaded sites.",
        default => 0,
        check_type => "bool",
        check_role => "reverse_proxy",
    },
    
    'verify_backend_path' => {
        des => "What path the OPTIONS request sent by verify_backend should use.  Default is '*'.",
        default => '*',
        check_role => "reverse_proxy",
    },

    'max_backend_uses' => {
        check_role => "reverse_proxy",
        des => "The max number of requests to be made on a single persistent backend connection before releasing the connection.  The default value of 0 means no limit, and the connection will only be discarded once the backend asks it to be, or when Perlbal is sufficiently idle.",
        default => 0,
    },

    'max_put_size' => {
        default => 0,  # no limit
        des => "The maximum content-length that will be accepted for a PUT request, if enable_put is on.  Default value of 0 means no limit.",
        check_type => "size",
        check_role => "web_server",
    },

    'max_chunked_request_size' => {
        default => 209715200,  # 200 MB.  (0: no limit)
        des => "The maximum size that will be accepted for a chunked request.  Default is 200MB (which is written to disk, buffered uploads must be on).  A value of 0 means no limit.",
        check_type => "size",
        check_role => "*",
    },

    'buffer_size' => {
        des => "How much we'll ahead of a client we'll get while copying from a backend to a client.  If a client gets behind this much, we stop reading from the backend for a bit.",
        default => "256k",
        check_type => "size",
        check_role => "reverse_proxy",
    },

    'buffer_size_reproxy_url' => {
        des => "How much we'll get ahead of a client we'll get while copying from a reproxied URL to a client.  If a client gets behind this much, we stop reading from the reproxied URL for a bit.  The default is lower than the regular buffer_size (50k instead of 256k) because it's assumed that you're only reproxying to large files on event-based webservers, which are less sensitive to many open connections, whereas the 256k buffer size is good for keeping heavy process-based free of slow clients.",
        default => "50k",
        check_type => "size",
        check_role => "reverse_proxy",
    },

    'queue_relief_size' => {
        default => 0,
        check_type => "int",
        check_role => "reverse_proxy",
    },

    'queue_relief_chance' => {
        default => 0,
        check_type => sub {
            my ($self, $val, $errref) = @_;
            return 1 if $val =~ /^\d+$/ && $val >= 0 && $val <= 100;
            $$errref = "Expecting integer value between 0 and 100, inclusive.";
            return 0;
        },
        check_role => "reverse_proxy",
    },

    'buffer_backend_connect' => {
        des => "How much content-body (POST/PUT/etc) data we read from a client before we start sending it to a backend web node.  If 'buffer_uploads' is enabled, this value is used to determine how many bytes are read before Perlbal makes a determination on whether or not to spool the upload to disk.",
        default => '100k',
        check_type => "size",
        check_role => "reverse_proxy",
    },

    'docroot' => {
        des => "Directory root for web server.",

        check_role => "web_server",
        val_modify => sub { my $valref = shift; $$valref =~ s!/$!!; },
        check_type => sub {
            my ($self, $val, $errref) = @_;
            #FIXME: require absolute paths?
            return 1 if $val && -d $val;
            $$errref = "Directory not found for service $self->{name}";
            return 0;
        },
    },

    'enable_put' => {
        des => "Enable HTTP PUT requests.",
        default => 0,
        check_role => "web_server",
        check_type => "bool",
    },

    'enable_md5' => {
        des => "Enable verification of the Content-MD5 header in HTTP PUT requests",
        default => 1,
        check_role => "web_server",
        check_type => "bool",
    },

    'enable_delete' => {
        des => "Enable HTTP DELETE requests.",
        default => 0,
        check_role => "web_server",
        check_type => "bool",
    },

    'enable_reproxy' => {
        des => "Enable 'reproxying' (end-user-transparent internal redirects) to either local files or other URLs.  When enabled, the backend servers in the pool that this service is configured for will have access to tell this Perlbal instance to serve any local readable file, or connect to any other URL that this Perlbal can connect to.  Only enable this if you trust the backend web nodes.",
        default => 0,
        check_role => "reverse_proxy",
        check_type => "bool",
    },

    'reproxy_cache_maxsize' => {
        des => "Set the maximum number of cached reproxy results (X-REPROXY-CACHE-FOR) that may be kept in the service cache. These cached requests take up about 1.25KB of ram each (on Linux x86), but will vary with usage. Perlbal still starts with 0 in the cache and will grow over time. Be careful when adjusting this and watch your ram usage like a hawk.",
        default => 0,
        check_role => "reverse_proxy",
        check_type => "int",
        setter => sub {
            my ($self, $val, $set, $mc) = @_;
            if ($val) {
                $self->{reproxy_cache} ||= Perlbal::Cache->new(maxsize => 1);
                $self->{reproxy_cache}->set_maxsize($val);
            } else {
                $self->{reproxy_cache} = undef;
            }
            return $mc->ok;
        },
    },

    'upload_status_listeners' => {
        des => "Comma separated list of hosts in form 'a.b.c.d:port' which will receive UDP upload status packets no faster than once a second per HTTP request (PUT/POST) from clients that have requested an upload status bar, which they request by appending the URL get argument ?client_up_sess=[xxxxxx] where xxxxx is 5-50 'word' characters (a-z, A-Z, 0-9, underscore).",
        default => "",
        check_role => "reverse_proxy",
        check_type => sub {
            my ($self, $val, $errref) = @_;
            my @packed;
            foreach my $ipa (grep { $_ } split(/\s*,\s*/, $val)) {
                unless ($ipa =~ /^(\d+\.\d+\.\d+\.\d+):(\d+)$/) {
                    $$errref = "Invalid UDP endpoint: \"$ipa\".  Must be of form a.b.c.d:port";
                    return 0;
                }
                push @packed, scalar Socket::sockaddr_in($2, Socket::inet_aton($1));
            }
            $self->{upload_status_listeners_sockaddr} = \@packed;
            return 1;
        },
    },

    'min_put_directory' => {
        des => "If PUT requests are enabled, require this many levels of directories to already exist.  If not, fail.",
        default => 0,   # no limit
        check_role => "web_server",
        check_type => "int",
    },

    'dirindexing' => {
        des => "Show directory indexes when an HTTP request is for a directory.  Warning:  this is not an async operation, so will slow down Perlbal on heavily loaded sites.",
        default => 0,
        check_role => "web_server",
        check_type => "bool",
    },

    'enable_concatenate_get' => {
        des => "Enable Perlbal's multiple-files-in-one-request mode, where a client have use a comma-separated list of files to return, always in text/plain.  Useful for web apps which have dozens/hundreds of tiny css/js files, and don't trust browsers/etc to do pipelining.  Decreases overall round-trip latency a bunch, but requires app to be modified to support it.  See t/17-concat.t test for details.",
        default => 0,
        check_role => "web_server",
        check_type => "bool",
    },

    'connect_ahead' => {
        des => "How many extra backend connections we keep alive in addition to the current ones, in anticipation of new client connections.",
        default => 0,
        check_type => "int",
        check_role => "reverse_proxy",
        setter => sub {
            my ($self, $val, $set, $mc) = @_;
            my $rv = $set->();
            $self->spawn_backends if $self->{enabled};
            return $rv;
        },
    },

    'always_trusted' => {
        des => "Whether to trust all incoming requests' X-Forwarded-For and related headers.  Set to true only if you know that all incoming requests from your own proxy servers that clean/set those headers.",
        default => 0,
        check_type => "bool",
        check_role => "*",
    },

    'blind_proxy' => {
        des => "Flag to disable any modification of X-Forwarded-For, X-Host, and X-Forwarded-Host headers.",
        default => 0,
        check_type => "bool",
        check_role => "reverse_proxy",
    },

    'high_priority_cookie' => {
        des => "The cookie name to inspect to determine if the client goes onto the high-priority queue.",
        check_role => "reverse_proxy",
    },

    'high_priority_cookie_contents' => {
        des => "A string that the high_priority_cookie must contain to go onto the high-priority queue.",
        check_role => "reverse_proxy",
    },

    'trusted_upstream_proxies' => {
        des => "A comma separated list of Net::Netmask filters (e.g. 10.0.0.0/24, see Net::Netmask) that determines whether upstream clients are trusted or not, where trusted means their X-Forwarded-For/etc headers are not munged.",
        check_role => "*",
        check_type => sub {
            my ($self, $val, $errref) = @_;
            unless (my $loaded = eval { require Net::Netmask; 1; }) {
                $$errref = "Net::Netmask not installed";
                return 0;
            }

            my @val = split /\s*,\s*/, $val;
            my @trusted_upstreams = ();

            for my $ip (@val) {
                my $net = Net::Netmask->new2($ip);
                unless ($net) {
                    $$errref = "Error defining trusted upstream proxies: " . Net::Netmask::errstr();
                    return 0;
                }
                push @trusted_upstreams, $net;
            }

            unless (@trusted_upstreams) {
                $$errref = "Error defining trusted upstream proxies: None found";
                return 0;
            }
            $self->{trusted_upstream_proxies} = \@trusted_upstreams;
        },
        setter => sub {
            my ($self, $val, $set, $mc) = @_;
	    # Do nothing here, we don't want the default setter because we've
	    # already set the value in the type_check step.
            return $mc->ok;
	},
    },

    'index_files' => {
        check_role => "web_server",
        default => "index.html",
        des => "Comma-separated list of filenames to load when a user visits a directory URL, listed in order of preference.",
        setter => sub {
            my ($self, $val, $set, $mc) = @_;
            $self->{index_files} = [ split(/[\s,]+/, $val) ];
            return $mc->ok;
        },
        dumper => sub {
            my ($self, $val) = @_;
            return unless defined $val;
            return join(', ', @$val);
        },
    },

    'default_service' => {
        des => "Name of previously-created service to default requests that aren't matched by a selector plugin to.",
        check_role => "selector",
        check_type => sub {
            my ($self, $val, $errref) = @_;

            my $svc = Perlbal->service($val);
            unless ($svc) {
                $$errref = "Service '$svc' not found";
                return 0;
            }

            $self->{default_service} = $svc;
            return 1;
        }, 
        setter => sub {
            # override default so we don't set it to the text
            return $_[3]->ok;
        },
    },

    'pool' => {
        des => "Name of previously-created pool object containing the backend nodes that this reverse proxy sends requests to.",
        check_role => "reverse_proxy",
        check_type => sub {
            my ($self, $val, $errref) = @_;
            my $pl = Perlbal->pool($val);
            unless ($pl) {
                $$errref = "Pool '$val' not found";
                return 0;
            }
            $self->{pool}->decrement_use_count if $self->{pool};
            $self->{pool} = $pl;
            $self->{pool}->increment_use_count;
            $self->{generation}++;
            return 1;
        },
        setter => sub {
            my ($self, $val, $set, $mc) = @_;
            # override the default, which is to set "pool" to the
            # stringified name of the pool, but we already set it in
            # the type-checking phase.  instead, we do nothing here.
            return $mc->ok;
        },
        dumper => sub {
            my ($self, $val) = @_;
            return $val->name;
        }
    },

    'server_process' => {
        des => "Executable which will be the HTTP server on stdin/stdout. (ALPHA, EXPERIMENTAL!)",
        check_role => "reverse_proxy",
        check_type => sub {
            my ($self, $val, $errref) = @_;
            #FIXME: require absolute paths?
            return 1 if $val && -x $val;
            $$errref = "Server process ($val) not executable.";
            return 0;
        },
    },

    'persist_client_timeout' => {
        des => "Set both the persist_client_idle_timeout and idle_timeout (deprecated)",
        check_type => "int",
        check_role => "*",
        setter => sub {
            my ($self, $val, $set, $mc) = @_;
            $self->{persist_client_idle_timeout} = $val;
            $self->{idle_timeout} = $val;
            return $mc->ok;
        },
        dump_ignore => 1,
    },

    'persist_client_idle_timeout' => {
        des => "Timeout in seconds for HTTP keep-alives to the end user (default is 30)",
        check_type => "int",
        default => 30,
        check_role => "*",
    },

    'idle_timeout' => {
        des => "Timeout in seconds for idle connections to the end user (default is 30)",
        check_type => "int",
        default => 30,
        check_role => "*",
    },

    'buffer_uploads_path' => {
        des => "Directory root for storing files used to buffer uploads.",

        check_role => "reverse_proxy",
        val_modify => sub { my $valref = shift; $$valref =~ s!/$!!; },
        check_type => sub {
            my ($self, $val, $errref) = @_;
            #FIXME: require absolute paths?
            return 1 if $val && -d $val;
            $$errref = "Directory ($val) not found for service $self->{name} (buffer_uploads_path)";
            return 0;
        },
    },

    'buffer_uploads' => {
        des => "Used to enable or disable the buffer uploads to disk system.  If enabled, 'buffer_backend_connect' bytes worth of the upload will be stored in memory.  At that point, the buffer upload thresholds will be checked to see if we should just send this upload to the backend, or if we should spool it to disk.",
        default => 0,
        check_role => "reverse_proxy",
        check_type => "bool",
    },

    'buffer_upload_threshold_time' => {
        des => "If an upload is estimated to take more than this number of seconds, it will be buffered to disk.  Set to 0 to not check estimated time.",
        default => 5,
        check_role => "reverse_proxy",
        check_type => "int",
    },

    'buffer_upload_threshold_size' => {
        des => "If an upload is larger than this size in bytes, it will be buffered to disk.  Set to 0 to not check size.",
        default => '250k',
        check_role => "reverse_proxy",
        check_type => "size",
    },

    'buffer_upload_threshold_rate' => {
        des => "If an upload is coming in at a rate less than this value in bytes per second, it will be buffered to disk.  Set to 0 to not check rate.",
        default => 0,
        check_role => "reverse_proxy",
        check_type => "int",
    },

    'latency' => {
        des => "Forced latency (in milliseconds) to add to request.",
        default => 0,
        check_role => "selector",
        check_type => "int",
    },

    'enable_ssl' => {
        des => "Enable SSL to the client.",
        default => 0,
        check_type => "bool",
        check_role => "*",
    },

    'ssl_key_file' => {
        des => "Path to private key PEM file for SSL.",
        default => "certs/server-key.pem",
        check_type => "file_or_none",
        check_role => "*",
    },

    'ssl_cert_file' => {
        des => "Path to certificate PEM file for SSL.",
        default => "certs/server-cert.pem",
        check_type => "file_or_none",
        check_role => "*",
    },

    'ssl_cipher_list' => {
        des => "OpenSSL-style cipher list.",
        default => "ALL:!LOW:!EXP",
        check_role => "*",
    },

    'ssl_ca_path' => {
        des => 'Path to directory containing certificates for SSL.',
        default => undef,
        check_type => "directory_or_none",
        check_role => "*",
    },

    'ssl_verify_mode' => {
        des => 'SSL verification mode',
        default => 0,
        check_type => "int",
        check_role => "*",
    },

    'enable_error_retries' => {
        des => 'Whether Perlbal should transparently retry requests to backends if a backend returns a 500 server error.',
        default => 0,
        check_type => "bool",
        check_role => "reverse_proxy",
    },

    'error_retry_schedule' => {
        des => 'String of comma-separated seconds (full or partial) to delay between retries.  For example "0,2" would mean do at most two retries, the first zero seconds after the first failure, and the second 2 seconds after the 2nd failure.  You probably don\'t need to modify the default value',
        default => '0,.25,.50,1,1,1,1,1',
        check_role => "reverse_proxy",
    },

    'client_sndbuf_size' => {
        des => "How large to set the client's socket SNDBUF.",
        default => 0,
        check_type => "size",
        check_role => '*',
    },

    'server_tokens' => {
        des        => 'Whether to provide a "Server" header.',
        check_role => '*',
        check_type => 'bool',
        default    => 1,
    },

};
sub autodoc_get_tunables { return $tunables; }

sub new {
    my Perlbal::Service $self = shift;
    $self = fields::new($self) unless ref $self;

    my ($name) = @_;

    $name ||= '';
    $self->{name} = $name;
    $self->{enabled} = 0;
    $self->{extra_config} = {};

    $self->{backend_no_spawn} = {};
    $self->{generation} = 0;

    $self->{hooks} = {};
    $self->{plugins} = {};
    $self->{plugin_order} = [];

    # track pending connects to backend
    $self->{pending_connects} = {};
    $self->{pending_connect_count} = 0;
    $self->{bored_backends} = [];

    # waiting clients
    $self->{waiting_clients} = [];
    $self->{waiting_clients_highpri} = [];
    $self->{waiting_clients_lowpri}  = [];
    $self->{waiting_client_count} = 0;
    $self->{waiting_client_map} = {};

    # buffered upload setup
    $self->{buffer_uploads_path} = undef;

    # don't have an object for this yet
    $self->{trusted_upstream_proxies} = undef;

    # bare data structure for extra header info
    $self->{extra_headers} = { remove => [], insert => [] };

    # things to watch...
    foreach my $v (qw(pending_connects bored_backends waiting_clients
                      waiting_clients_highpri backend_no_spawn
                      waiting_client_map
                      )) {
        die "Field '$v' not set" unless $self->{$v};
        Perlbal::track_var("svc-$name-$v", $self->{$v});
    }

    return $self;
}

# handy instance method to run some manage commands in the context of this service,
# without needing to worry about its name.
# This is intended as an internal API thing, so any output that would have been
# generated is just eaten.
sub run_manage_commands {
    my ($self, $cmd_block) = @_;

    my $ctx = Perlbal::CommandContext->new;
    $ctx->{last_created} = $self->name;
    return Perlbal::run_manage_commands($cmd_block, undef, $ctx);
}

# here's an alternative version of the above that runs a single command
sub run_manage_command {
    my ($self, $cmd) = @_;

    my $ctx = Perlbal::CommandContext->new;
    $ctx->{last_created} = $self->name;
    return Perlbal::run_manage_command($cmd, undef, $ctx);
}

sub dumpconfig {
    my $self = shift;

    my @return;

    my %my_tunables = %$tunables;

    my $dump = sub {
        my $setting = shift;
    };

    foreach my $skip (qw(role listen pool)) {
        delete $my_tunables{$skip};
    }

    my $role = $self->{role};

    foreach my $setting ("role", "listen", "pool", sort keys %my_tunables) {
        my $attrs = $tunables->{$setting};

        next if $attrs->{dump_ignore};

        my $value = $attrs->{_plugin_inserted} ? $self->{extra_config}->{$setting} : $self->{$setting};

        my $check_role = $attrs->{check_role};
        my $check_type = $attrs->{check_type};
        my $default    = $attrs->{default};
        my $required   = $attrs->{required};

        next if ($check_role && $check_role ne '*' && $check_role ne $role);

        if ($check_type && $check_type eq 'size') {
            $default = $1               if $default =~ /^(\d+)b$/i;
            $default = $1 * 1024        if $default =~ /^(\d+)k$/i;
            $default = $1 * 1024 * 1024 if $default =~ /^(\d+)m$/i;
        }

        if (!$required) {
            next unless defined $value;
            next if (defined $default && $value eq $default);
        }

        if (my $dumper = $attrs->{dumper}) {
            $value = $dumper->($self, $value);
        }

        if ($check_type && $check_type eq 'bool') {
            $value = 'on' if $value;
        }

        push @return, "SET $setting = $value";
    }

    my $plugins = $self->{plugins};

    foreach my $plugin (keys %$plugins) {
        local $@;

        my $class = "Perlbal::Plugin::$plugin";
        my $cv = $class->can('dumpconfig');

        if ($cv) {
            eval { push @return, $class->dumpconfig($self) };
            if ($@) {
                push @return, "# Plugin '$plugin' threw an exception while being dumped.";
            }
        } else {
            push @return, "# Plugin '$plugin' isn't capable of dumping config.";
        }
    }

    return @return;
}

# called once a role has been set
sub init {
    my Perlbal::Service $self = shift;
    die "init called when no role" unless $self->{role};

    # set all the defaults
    for my $param (keys %$tunables) {
        my $tun     = $tunables->{$param};
        next unless $tun->{check_role} eq "*" || $tun->{check_role} eq $self->{role};

        if (exists $defaults->{$param}) {
            $self->set($param, $defaults->{$param});
        } elsif (exists $tun->{default}) {
            $self->set($param, $tun->{default});
        }
    }
}

# Service default setter
sub set_defaults {
    my ($mc, %args) = @_;
    foreach my $key (keys %args) {
        $defaults->{$key} = $args{$key};
    }
    return $mc->ok;
}

# Service
sub set {
    my Perlbal::Service $self = shift;
    my ($key, $val, $mc) = @_;

    # if you don't provide an $mc, that better mean you're damn sure it
    # won't crash.  (end-users never go this route)
    $mc ||= Perlbal::ManageCommand->loud_crasher;

    my $set = sub { $self->{$key} = $val; return $mc->ok; };

    my $pool_set = sub {
        # if we don't have a pool, automatically create one named $NAME_pool
        unless ($self->{pool}) {
            # die if necessary
            die "ERROR: Attempt to vivify pool $self->{name}_pool but one or more pools\n" .
                "       have already been created manually.  Please set $key on a\n" .
                "       previously created pool.\n" unless $Perlbal::vivify_pools;

            # create the pool and ensure that vivify stays on
            Perlbal::run_manage_command("CREATE POOL $self->{name}_pool", $mc->out);
            Perlbal::run_manage_command("SET $self->{name}.pool = $self->{name}_pool");
            $Perlbal::vivify_pools = 1;
        }

        # now we actually do the set
        warn "WARNING: '$key' set on service $self->{name} on auto-vivified pool.\n" .
             "         This behavior is obsolete.  This value should be set on a\n" .
             "         pool object and not on a service.\n" if $Perlbal::vivify_pools;
        return $mc->err("No pool defined for service") unless $self->{pool};
        return $self->{pool}->set($key, $val, $mc);
    };

    # this is now handled by Perlbal::Pool, so we pass this set command on
    # through in case people try to use it on us like the old method.
    return $pool_set->()
        if $key eq 'nodefile' ||
           $key eq 'balance_method';

    if (my $tun = $tunables->{$key}) {
        if (my $req_role = $tun->{check_role}) {
            return $mc->err("The '$key' option can only be set on a '$req_role' service")
                unless ($self->{role}||"") eq $req_role || $req_role eq "*";
        }

        if (my $req_type = $tun->{check_type}) {
            if (ref $req_type eq "ARRAY" && $req_type->[0] eq "enum") {
                return $mc->err("Value of '$key' must be one of: " . join(", ", @{$req_type->[1]}))
                    unless grep { $val eq $_ } @{$req_type->[1]};
            } elsif (ref $req_type eq "ARRAY" && $req_type->[0] eq "regexp") {
                my $re    = $req_type->[1];
                my $emsg  = $req_type->[2];
                return $mc->err($emsg) unless $val =~ /$re/;
            } elsif (ref $req_type eq "CODE") {
                my $emsg  = "";
                return $mc->err($emsg) unless $req_type->($self, $val, \$emsg);
            } elsif ($req_type eq "bool") {
                $val = _bool($val);
                return $mc->err("Expecting boolean value for parameter '$key'")
                    unless defined $val;
            } elsif ($req_type eq "int") {
                return $mc->err("Expecting integer value for parameter '$key'")
                    unless $val =~ /^\d+$/;
            } elsif ($req_type eq "size") {
                $val = $1               if $val =~ /^(\d+)b$/i;
                $val = $1 * 1024        if $val =~ /^(\d+)k$/i;
                $val = $1 * 1024 * 1024 if $val =~ /^(\d+)m$/i;
                return $mc->err("Expecting size unit value for parameter '$key' in bytes, or suffixed with 'K' or 'M'")
                    unless $val =~ /^\d+$/;
            } elsif ($req_type eq "file") {
                return $mc->err("File '$val' not found for '$key'") unless -f $val;
            } elsif ($req_type eq "file_or_none") {
                return $mc->err("File '$val' not found for '$key'") unless -f $val || $val eq $tun->{default};
            } elsif ($req_type eq "directory_or_none") {
                return $mc->err("Directory '$val' not found for '$key'") unless !defined $val || -d $val;
            } else {
                die "Unknown check_type: $req_type\n";
            }
        }

        if ($tun->{_plugin_inserted}) {
            # plugins that add tunables need to be stored in the extra_config hash due to the main object
            # using fields.  this passthrough is done so the config files don't need to specify this.
            $set = sub {
                $self->{extra_config}->{$key} = $val;
                return $mc->ok;
            };
        }

        my $setter = $tun->{setter};

        if (ref $setter eq "CODE") {
            return $setter->($self, $val, $set, $mc);
        } else {
            return $set->();
        }
    }

    if ($key eq 'plugins') {
        # unload existing plugins
        foreach my $plugin (keys %{$self->{plugins}}) {
            eval "Perlbal::Plugin::$plugin->unregister(\$self);";
            return $mc->err($@) if $@;
        }

        # clear out loaded plugins and hooks
        $self->{hooks} = {};
        $self->{plugins} = {};
        $self->{plugin_order} = [];

        # load some plugins
        foreach my $plugin (split /[\s,]+/, $val) {
            next if $plugin eq 'none';

            my $fn = Perlbal::plugin_case($plugin);

            next if $self->{plugins}->{$fn};
            unless ($Perlbal::plugins{$fn}) {
                $mc->err("Plugin $fn not loaded; not registered for $self->{name}.");
                next;
            }

            # now register it
            eval "Perlbal::Plugin::$fn->register(\$self);";
            return $mc->err($@) if $@;
            $self->{plugins}->{$fn} = 1;
            push @{$self->{plugin_order}}, $fn;
        }
        return $mc->ok;
    }

    if ($key =~ /^extra\.(.+)$/) {
        # set some extra configuration data data
        $self->{extra_config}->{$1} = $val;
        return $mc->ok;
    }

    # see if it happens to be a plugin set command?
    if ($key =~ /^(.+)\.(.+)$/) {
        if (my $coderef = $self->{plugin_setters}->{$1}->{$2}) {
            return $coderef->($mc->out, $2, $val);
        }
    }

    return $mc->err("Unknown service parameter '$key'");
}

{
    # should use sate, but could be a problem for old perl version
    # benchmark test, says that this function is x5 times faster than the previous one
    my %h_on = map { $_, 1 } qw/1 true on yes/;
    my %h_off = map { $_, 1 } qw/0 false off no/;

    # create one static method to check boolean value, rather than generating each time a dynamic method 
    # use static list rather than regexp to speedup the reading process
    sub _bool {
        my $val = shift;

        return unless defined $val;

        $val = lc($val);
        return 1 if defined $h_on{$val};
        return 0 if defined $h_off{$val};

        return undef;
    }
}

# CLASS METHOD -
# used by plugins that want to add tunables so that the config file
# can have more options for service settings
sub add_tunable {
    my ($name, $hashref) = @_;
    return 0 unless $name && $hashref && ref $hashref eq 'HASH';
    return 0 if $tunables->{$name};
    $hashref->{_plugin_inserted} = 1; # mark that a plugin did this
    $tunables->{$name} = $hashref;
    return 1;
}

# CLASS METHOD -
# remove a defined tunable, but only if a plugin is what created it
sub remove_tunable {
    my $name = shift;
    my $tun = $tunables->{$name} or return 0;
    return 0 unless $tun->{_plugin_inserted};
    delete $tunables->{$name};
    return 1;
}

# CLASS METHOD -
# used by plugins to define a new role that services can take on
sub add_role {
    my ($role, $creator) = @_;
    return 0 unless $role && $creator && ref $creator eq 'CODE';
    return 0 if $PluginRoles{$role};
    $PluginRoles{$role} = $creator;
    return 1;
}

# CLASS METHOD -
# remove a defined plugin role
sub remove_role {
    return 0 unless delete $PluginRoles{$_[0]};
    return 1;
}

# CLASS METHOD -
# returns a defined role creator, if it exists.  (undef if it does not)
sub get_role_creator {
    return $PluginRoles{$_[0]};
}

# run the hooks in a list one by one until one hook returns a true
# value.  returns 1 or 0 depending on if any hooks handled the
# request.
sub run_hook {
    my Perlbal::Service $self = shift;
    my $hook = shift;
    if (defined (my $ref = $self->{hooks}->{$hook})) {
        # call all the hooks until one returns true
        foreach my $hookref (@$ref) {
            my $rval = $hookref->[1]->(@_);
            return 1 if $rval;
        }
    }
    return 0;
}

# run a bunch of hooks in this service, always returns undef.
sub run_hooks {
    my Perlbal::Service $self = shift;
    my $hook = shift;
    if (defined (my $ref = $self->{hooks}->{$hook})) {
        # call all the hooks
        $_->[1]->(@_) foreach @$ref;
    }
    return undef;
}

# define a hook for this service
sub register_hook {
    my Perlbal::Service $self = shift;
    my ($pclass, $hook, $ref) = @_;
    push @{$self->{hooks}->{$hook} ||= []}, [ $pclass, $ref ];
    return 1;
}

# remove hooks we have defined
sub unregister_hook {
    my Perlbal::Service $self = shift;
    my ($pclass, $hook) = @_;
    if (defined (my $refs = $self->{hooks}->{$hook})) {
        my @new;
        foreach my $ref (@$refs) {
            # fill @new with hooks that DON'T match
            push @new, $ref
                unless $ref->[0] eq $pclass;
        }
        $self->{hooks}->{$hook} = \@new;
        return 1;
    }
    return undef;
}

# remove all hooks of a certain class
sub unregister_hooks {
    my Perlbal::Service $self = shift;
    foreach my $hook (keys %{$self->{hooks}}) {
        # call unregister_hook with this hook name
        $self->unregister_hook($_[0], $hook);
    }
}

# register a value setter for plugin configuration
sub register_setter {
    my Perlbal::Service $self = shift;
    my ($pclass, $key, $coderef) = @_;
    return unless $pclass && $key && $coderef;
    $self->{plugin_setters}->{lc $pclass}->{lc $key} = $coderef;
}

# remove a setter
sub unregister_setter {
    my Perlbal::Service $self = shift;
    my ($pclass, $key) = @_;
    return unless $pclass && $key;
    delete $self->{plugin_setters}->{lc $pclass}->{lc $key};
}

# remove a bunch of setters
sub unregister_setters {
    my Perlbal::Service $self = shift;
    my $pclass = shift;
    return unless $pclass;
    delete $self->{plugin_setters}->{lc $pclass};
}

# take a backend we've created and mark it as pending if we do not
# have another pending backend connection in this slot
sub add_pending_connect {
    my Perlbal::Service $self = shift;
    my Perlbal::BackendHTTP $be = shift;

    # error if we already have a pending connection for this ipport
    if (defined $self->{pending_connects}{$be->{ipport}}) {
        Perlbal::log('warning', "Warning: attempting to spawn backend connection that already existed.");

        # now dump a backtrace so we know how we got here
        my $depth = 0;
        while (my ($package, $filename, $line, $subroutine) = caller($depth++)) {
            Perlbal::log('warning', "          -- [$filename:$line] $package::$subroutine");
        }

        # we're done now, just return
        return;
    }

    # set this connection up in the pending connection list
    $self->{pending_connects}{$be->{ipport}} = $be;
    $self->{pending_connect_count}++;
}

# remove a backend connection from the pending connect list if and only
# if it is the actual connection contained in the list; prevent double
# decrementing on accident
sub clear_pending_connect {
    my Perlbal::Service $self = shift;
    my Perlbal::BackendHTTP $be = shift;
    if (defined $self->{pending_connects}{$be->{ipport}} && defined $be &&
            $self->{pending_connects}{$be->{ipport}} == $be) {
        $self->{pending_connects}{$be->{ipport}} = undef;
        $self->{pending_connect_count}--;
    }
}

# called by BackendHTTP when it's closed by any means
sub note_backend_close {
    my Perlbal::Service $self = shift;
    my Perlbal::BackendHTTP $be = shift;
    $self->clear_pending_connect($be);
    $self->spawn_backends;
}

# called by ClientProxy when it dies.
sub note_client_close {
    my Perlbal::Service $self;
    my Perlbal::ClientProxy $cp;
    ($self, $cp) = @_;

    if (delete $self->{waiting_client_map}{$cp->{fd}}) {
        $self->{waiting_client_count}--;
    }
}

sub mark_node_used {
    my Perlbal::Service $self = $_[0];
    $self->{pool}->mark_node_used($_[1]) if $self->{pool};
}

sub get_client {
    my Perlbal::Service $self = shift;

    my $ret = sub {
        my Perlbal::ClientProxy $cp = shift;
        $self->{waiting_client_count}--;
        delete $self->{waiting_client_map}{$cp->{fd}};

        # before we return, start another round of connections
        $self->spawn_backends;

        return $cp;
    };

    # determine if we should jump straight to the high priority queue or
    # act as pressure relief on the standard queue
    my $hp_first = 1;
    if (($self->{queue_relief_size} > 0) &&
        (scalar(@{$self->{waiting_clients}}) >= $self->{queue_relief_size})) {
        # if we're below the chance level, take a standard queue item
        $hp_first = 0
            if rand(100) < $self->{queue_relief_chance};
    }

    # find a high-priority client, or a regular one
    my Perlbal::ClientProxy $cp;
    while ($hp_first && ($cp = shift @{$self->{waiting_clients_highpri}})) {
        next if $cp->{closed};
        if (Perlbal::DEBUG >= 2) {
            my $backlog = scalar @{$self->{waiting_clients}};
            print "Got from fast queue, in front of $backlog others\n";
        }
        return $ret->($cp);
    }

    # regular clients:
    while ($cp = shift @{$self->{waiting_clients}}) {
        next if $cp->{closed};
        print "Backend requesting client, got normal = $cp->{fd}.\n" if Perlbal::DEBUG >= 2;
        return $ret->($cp);
    }

    # low-priority (batch/idle) clients.
    while ($cp = shift @{$self->{waiting_clients_lowpri}}) {
        next if $cp->{closed};
        print "Backend requesting client, got low priority = $cp->{fd}.\n" if Perlbal::DEBUG >= 2;
        return $ret->($cp);
    }

    return undef;
}

# given a backend, verify it's generation
sub verify_generation {
    my Perlbal::Service $self = $_[0];
    my Perlbal::BackendHTTP $be = $_[1];

    # fast cases: generation count matches, so we just return an 'okay!' flag
    return 1 if $self->{generation} == $be->generation;

    # if our current pool knows about this ip:port, then we can still use it
    if (defined $self->{pool}->node_used($be->ipport)) {
        # so we know this is good, in the future we just want to hit the fast case
        # and continue, so let's update the generation
        $be->generation($self->{generation});
        return 1;
    }

    # if we get here, the backend should be closed
    $be->close('invalid_generation');
    return 0;
}

# called by backend connection after it becomes writable
sub register_boredom {
    my Perlbal::Service $self;
    my Perlbal::BackendHTTP $be;
    ($self, $be) = @_;

    # note that this backend is no longer pending a connect,
    # if we thought it was before.  but not if it's a persistent
    # connection asking to be re-used.
    unless ($be->{use_count}) {
        $self->clear_pending_connect($be);
    }

    # it is possible that this backend is part of a different pool that we're
    # no longer using... if that's the case, we want to close it
    return unless $self->verify_generation($be);

    # now try to fetch a client for it
    my Perlbal::ClientProxy $cp = $self->get_client;
    if ($cp) {
        return if $be->assign_client($cp);

        # don't want to lose client, so we (unfortunately)
        # stick it at the end of the waiting queue.
        # fortunately, assign_client shouldn't ever fail.
        $self->request_backend_connection($cp);
    }

    # don't hang onto more bored, persistent connections than
    # has been configured for connect-ahead
    if ($be->{use_count}) {
        my $current_bored = scalar @{$self->{bored_backends}};
        if ($current_bored >= $self->{backend_persist_cache}) {
            $be->close('too_many_bored');
            return;
        }
    }

    # put backends which are known to be bound to processes
    # and not to TCP stacks at the beginning where they'll
    # be used first
    if ($be->{has_attention}) {
        unshift @{$self->{bored_backends}}, $be;
    } else {
        push @{$self->{bored_backends}}, $be;
    }
}

sub note_bad_backend_connect {
    my Perlbal::Service $self = shift;
    my Perlbal::BackendHTTP $be = shift;
    my $retry_time = shift();

    # clear this pending connection
    $self->clear_pending_connect($be);

    # mark this host as dead for a while if we need to
    if (defined $retry_time && $retry_time > 0) {
        # we don't want other spawn_backends calls to retry
        $self->{backend_no_spawn}->{$be->{ipport}} = 1;

        # and now we set a callback to ensure we're kicked at the right time
        Perlbal::Socket::register_callback($retry_time, sub {
            delete $self->{backend_no_spawn}->{$be->{ipport}};
            $self->spawn_backends;
        });
    }

    # FIXME: do something interesting (tell load balancer about dead host,
    # and fire up a new connection, if warranted)

    # makes a new connection, if needed
    $self->spawn_backends;
}

sub request_backend_connection { # : void
    my Perlbal::Service $self;
    my Perlbal::ClientProxy $cp;
    ($self, $cp) = @_;

    return unless $cp && ! $cp->{closed};

    my $hi_pri = $cp->{high_priority};  # load values from the client proxy object
    my $low_pri = $cp->{low_priority};  # they are initialized as 0 during object creation, but hooks can override them

    # is there a defined high-priority cookie?
    if (my $cname = $self->{high_priority_cookie}) {
        # decide what priority class this request is in
        my $hd = $cp->{req_headers};
        my %cookie;
        foreach (split(/;\s+/, $hd->header("Cookie") || '')) {
            next unless ($_ =~ /(.*)=(.*)/);
            $cookie{Perlbal::Util::durl($1)} = Perlbal::Util::durl($2);
        }
        my $hicookie = $cookie{$cname} || "";
        $hi_pri = index($hicookie, $self->{high_priority_cookie_contents}) != -1;
    }

    # now, call hook to see if this should be high priority
    $hi_pri = $self->run_hook('make_high_priority', $cp)
        unless $hi_pri; # only if it's not already

    # and then, call hook to see about low priority
    $low_pri = $self->run_hook('make_low_priority', $cp)
        unless $hi_pri || $low_pri; # only if it's not high or low already

    $cp->{high_priority} = 1 if $hi_pri;
    $cp->{low_priority} = 1 if $low_pri;

    # before we even consider spawning backends, let's see if we have
    # some bored (pre-connected) backends that'd take this client
    my Perlbal::BackendHTTP $be;
    my $now = time;
    while ($be = shift @{$self->{bored_backends}}) {
        next if $be->{closed};

        # now make sure that it's still in our pool, and if not, close it
        next unless $self->verify_generation($be);

        # don't use connect-ahead connections when we haven't
        # verified we have their attention
        if (! $be->{has_attention} && $be->{create_time} < $now - 5) {
            $be->close("too_old_bored");
            next;
        }

        # don't use keep-alive connections if we know the server's
        # just about to kill the connection for being idle
        if ($be->{disconnect_at} && $now + 2 > $be->{disconnect_at}) {
            $be->close("too_close_disconnect");
            next;
        }

        # give the backend this client
        if ($be->assign_client($cp)) {
            # and make some extra bored backends, if configured as such
            $self->spawn_backends;
            return;
        }

        # assign client can end up closing the connection, so check for that
        return if $cp->{closed};
    }

    if ($hi_pri) {
        push @{$self->{waiting_clients_highpri}}, $cp;
    } elsif ($low_pri) {
        push @{$self->{waiting_clients_lowpri}}, $cp;
    } else {
        push @{$self->{waiting_clients}}, $cp;
    }

    $self->{waiting_client_count}++;
    $self->{waiting_client_map}{$cp->{fd}} = 1;

    $self->spawn_backends;
}

# sees if it should spawn one or more backend connections
sub spawn_backends {
    my Perlbal::Service $self = shift;

    # check our lock and set it if we can
    return if $self->{spawn_lock};
    $self->{spawn_lock} = 1;

    # sanity checks on our bookkeeping
    if ($self->{pending_connect_count} < 0) {
        Perlbal::log('crit', "Bogus: service $self->{name} has pending connect ".
                     "count of $self->{pending_connect_count}?!  Resetting.");
        $self->{pending_connect_count} = scalar
            map { $_ && ! $_->{closed} } values %{$self->{pending_connects}};
    }

    # keep track of the sum of existing_bored + bored_created
    my $backends_created = scalar(@{$self->{bored_backends}}) + $self->{pending_connect_count};
    my $backends_needed = $self->{waiting_client_count} + $self->{connect_ahead};
    my $to_create = $backends_needed - $backends_created;

    my $pool = $self->{pool};

    # can't create more than this, assuming one pending connect per node
    my $max_creatable = $pool ? ($self->{pool}->node_count - $self->{pending_connect_count}) : 1;
    $to_create = $max_creatable if $to_create > $max_creatable;

    # cap number of attempted connects at once
    $to_create = 10 if $to_create > 10;

    my $now = time;

    while ($to_create > 0) {
        $to_create--;

        # spawn processes if not a pool, else whine.
        unless ($pool) {
            if (my $sp = $self->{server_process}) {
                warn "To create = $to_create...\n";
                warn "  spawning $sp\n";
                my $be = Perlbal::BackendHTTP->new_process($self, $sp);
                return;
            }
            warn "No pool! Can't spawn backends.\n";
            return;
        }

        my ($ip, $port) = $self->{pool}->get_backend_endpoint;
        unless ($ip) {
            Perlbal::log('crit', "No backend IP for service $self->{name}");
            # FIXME: register desperate flag, so load-balancer module can callback when it has a node
            $self->{spawn_lock} = 0;
            return;
        }

        # handle retry timeouts so we don't spin
        next if $self->{backend_no_spawn}->{"$ip:$port"};

        # if it's pending, verify the pending one is still valid
        if (my Perlbal::BackendHTTP $be = $self->{pending_connects}{"$ip:$port"}) {
            my $age = $now - $be->{create_time};
            if ($age >= 5 && $be->{state} eq "connecting") {
                $be->close('connect_timeout');
            } elsif ($age >= 60 && $be->{state} eq "verifying_backend") {
                # after 60 seconds of attempting to verify, we're probably already dead
                $be->close('verify_timeout');
            } elsif (! $be->{closed}) {
                next;
            }
        }

        # now actually spawn a backend and add it to our pending list
        if (my $be = Perlbal::BackendHTTP->new($self, $ip, $port, { pool => $self->{pool} })) {
            $self->add_pending_connect($be);
        }
    }

    # clear our spawn lock
    $self->{spawn_lock} = 0;
}

# getter only
sub role {
    my Perlbal::Service $self = shift;
    return $self->{role};
}

# called by BackendHTTP to ask if a client's IP is in our trusted list
sub trusted_ip {
    my Perlbal::Service $self = shift;
    my $ip = shift;

    return 1 if $self->{'always_trusted'};

    my $tmap = $self->{trusted_upstream_proxies};
    return 0 unless $tmap;

    # try to use it as a Net::Netmask object
    for my $tmap (@{ $self->{trusted_upstream_proxies} }) {
        return 1 if eval { $tmap->match($ip); };
    }
    return 0;
}

# manage some header stuff
sub header_management {
    my Perlbal::Service $self = shift;
    my ($mode, $key, $val, $mc) = @_;
    return $mc->err("no header provided") unless $key;
    return $mc->err("no value provided")  unless 
        (defined $val && length $val || $mode eq 'remove');

    if ($mode eq 'insert') {
        push @{$self->{extra_headers}->{insert}}, [ $key, $val ];
    } elsif ($mode eq 'remove') {
        push @{$self->{extra_headers}->{remove}}, $key;
    }
    return $mc->ok;
}

sub munge_headers {
    my Perlbal::Service $self = $_[0];
    my Perlbal::HTTPHeaders $hdrs = $_[1];

    # handle removals first
    foreach my $hdr (@{$self->{extra_headers}->{remove}}) {
        $hdrs->header($hdr, undef);
    }

    # and now insertions
    foreach my $hdr (@{$self->{extra_headers}->{insert}}) {
        $hdrs->header($hdr->[0], $hdr->[1]);
    }
}

# getter/setter
sub selector {
    my Perlbal::Service $self = shift;
    if (@_) {
        my $ref = shift;
        $self->{selector} = sub {
            my $cb = shift;

            # try to give it to our defined selector
            my $res = $ref->($cb);

            # if that failed and we have a default, then give it to them
            if (!$res && $self->{default_service}) {
                $self->{default_service}->adopt_base_client($cb);
                return 1;
            }

            return $res;
        };
    }
    return $self->{selector};
}

# This is called anytime a client is leaving this service to be another service.
sub release_client {
    my Perlbal::Service $self = shift;
    my Perlbal::ClientHTTPBase $cb = shift;

    $self->munge_headers($cb->{req_headers});
    return;
}

# given a base client from a 'selector' role, down-cast it to its specific type
sub adopt_base_client {
    my Perlbal::Service $self = shift;
    my Perlbal::ClientHTTPBase $cb = shift;

    if (my $orig_service = $cb->{service}) {
        $orig_service->release_client($cb);
    }

    $cb->{service} = $self;

    if ($self->{'role'} eq "web_server") {
        Perlbal::ClientHTTP->new_from_base($cb);
        return;
    } elsif ($self->{'role'} eq "reverse_proxy") {
        Perlbal::ClientProxy->new_from_base($cb);
        return;
    } elsif ($self->{'role'} eq "selector") {
        Perlbal::ClientHTTPBase->new_from_base($cb);
        return;
    } else {
        $cb->_simple_response(500, "Can't map to service type $self->{'role'}");
    }
}

# turn a ClientProxy or ClientHTTP back into a generic base client
# (for a service-selector role)
sub return_to_base {
    my Perlbal::Service $self = shift;
    my Perlbal::ClientHTTPBase $cb = shift;  # actually a subclass of Perlbal::ClientHTTPBase

    $cb->{service} = $self;
    Perlbal::Util::rebless($cb, "Perlbal::ClientHTTPBase");

    # the read/watch events are reset by ClientHTTPBase's http_response_sent (our caller)
}

# Service
sub enable {
    my Perlbal::Service $self;
    my $mc;

    ($self, $mc) = @_;

    if ($self->{enabled}) {
        $mc && $mc->err("service $self->{name} is already enabled");
        return 0;
    }

    my $listener;

    # create UDP upload tracker listener
    if ($self->{role} eq "upload_tracker") {
        $listener = Perlbal::UploadListener->new($self->{listen}, $self);
    }

    # create TCP listening socket
    if (! $listener && $self->{listen}) {
        my $opts = {};
        if ($self->{enable_ssl}) {
            $opts->{ssl} = {
                SSL_key_file    => $self->{ssl_key_file},
                SSL_cert_file   => $self->{ssl_cert_file},
                SSL_cipher_list => $self->{ssl_cipher_list},
                (defined $self->{ssl_ca_path} ? (SSL_ca_path => $self->{ssl_ca_path}) : ()),
                (defined $self->{ssl_verify_mode} ? (SSL_verify_mode => $self->{ssl_verify_mode}) : ()),
            };
            return $mc->err("IO::Socket:SSL (0.98+) not available.  Can't do SSL.") unless eval "use IO::Socket::SSL 0.98 (); 1;";
            return $mc->err("SSL key file ($self->{ssl_key_file}) doesn't exist")   unless -f $self->{ssl_key_file};
            return $mc->err("SSL cert file ($self->{ssl_cert_file}) doesn't exist") unless -f $self->{ssl_cert_file};
        }

        my $tl = Perlbal::TCPListener->new($self->{listen}, $self, $opts);
        unless ($tl) {
            $mc && $mc->err("Can't start service '$self->{name}' on $self->{listen}: $Perlbal::last_error");
            return 0;
        }
        $listener = $tl;
    }

    $self->{listener} = $listener;
    $self->{enabled}  = 1;
    return $mc ? $mc->ok : 1;
}

# Service
sub disable {
    my Perlbal::Service $self;
    my ($mc, $force);

    ($self, $mc, $force) = @_;

    if (! $self->{enabled}) {
        $mc && $mc->err("service $self->{name} is already disabled");
        return 0;
    }
    if ($self->{role} eq "management" && ! $force) {
        $mc && $mc->err("can't disable management service");
        return 0;
    }

    # find listening socket
    my $tl = $self->{listener};
    $tl->close if $tl;
    $self->{listener} = undef;
    $self->{enabled} = 0;
    return $mc ? $mc->ok : 1;
}

sub stats_info
{
    my Perlbal::Service $self = shift;
    my $out = shift;
    my $now = time;

    $out->("SERVICE $self->{name}");
    $out->("     listening: " . ($self->{listen} || "--"));
    $out->("          role: $self->{role}");
    if ($self->{role} eq "reverse_proxy" ||
        $self->{role} eq "web_server") {
        $out->("  pend clients: $self->{waiting_client_count}");
        $out->("  pend backend: $self->{pending_connect_count}");
        foreach my $ipport (sort keys %{$self->{pending_connects}}) {
            my $be = $self->{pending_connects}{$ipport};
            next unless $be;
            my $age = $now - $be->{create_time};
            $out->("   $ipport - " . ($be->{closed} ? "(closed)" : $be->{state}) . " - ${age}s");
        }
    }
    if ($self->{role} eq "reverse_proxy") {
        if ($self->{reproxy_cache}) {
            my $hits     = $self->{_stat_cache_hits} || 0;
            my $hit_rate = sprintf("%0.02f%%", eval { $hits / ($self->{_stat_requests} || 0) * 100 } || 0);

            my $size     = eval { $self->{reproxy_cache}->size };
            $size = defined($size) ? $size : 'undef';

            my $maxsize  = eval { $self->{reproxy_cache}->maxsize };
            $maxsize = defined ($maxsize) ? $maxsize : 'undef';

            my $sizepercent = eval { sprintf("%0.02f%%", $size / $maxsize * 100) } || 'undef';

            $out->("    cache size: $size/$maxsize ($sizepercent)");
            $out->("    cache hits: $hits");
            $out->("cache hit rate: $hit_rate");
        }

        my $bored_count = scalar @{$self->{bored_backends}};
        $out->(" connect-ahead: $bored_count/$self->{connect_ahead}");
        if ($self->{pool}) {
            $out->("          pool: " . $self->{pool}->name);
            $out->("         nodes:");
            foreach my $n (@{ $self->{pool}->nodes }) {
                my $hostport = "$n->[0]:$n->[1]";
                $out->(sprintf("                %-21s %7d", $hostport, $self->{pool}->node_used($hostport) || 0));
            }
        }
    } elsif ($self->{role} eq "web_server") {
        $out->("        docroot: $self->{docroot}");
    }
}

# simple passthroughs to the run_hook mechanism.  part of the reportto interface.
sub backend_response_received {
    return $_[0]->run_hook('backend_response_received', $_[1]);
}

# just a getter for our name
sub name {
    my Perlbal::Service $self = $_[0];
    return $self->{name};
}

sub listenaddr {
    my Perlbal::Service $self = $_[0];
    return $self->{listen};
}

sub reproxy_cache {
    my Perlbal::Service $self = $_[0];
    return $self->{reproxy_cache};
}

sub add_to_reproxy_url_cache {
    my Perlbal::Service $self;
    my ($reqhd, $reshd);

    ($self, $reqhd, $reshd) = @_;

    # is caching enabled on this service?
    my $cache = $self->{reproxy_cache} or
        return 0;

    # these should always be set anyway, from BackendHTTP:
    my $reproxy_cache_for = $reshd->header('X-REPROXY-CACHE-FOR') or  return 0;
    my $urls              = $reshd->header('X-REPROXY-URL')       or  return 0;

    my ($timeout_delta, $cache_headers) = split ';', $reproxy_cache_for, 2;
    my $timeout = $timeout_delta ? time() + $timeout_delta : undef;

    my $hostname = $reqhd->header("Host") || '';
    my $requri   = $reqhd->request_uri    || '';
    my $key = "$hostname|$requri";

    my @headers;
    foreach my $header (split /\s+/, $cache_headers) {
        my $value;
        next unless $header && ($value = $reshd->header($header));
        $value  = _ref_to($value) if uc($header) eq 'CONTENT-TYPE';
        push @headers, _ref_to($header), $value;
    }

    $cache->set($key, [$timeout, \@headers, $urls]);
}

# given a string, return a shared reference to that string.  to save
# memory when lots of same string is stored.
my %refs;
sub _ref_to {
    my $key = shift;
    return $refs{$key} || ($refs{$key} = \$key);
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
