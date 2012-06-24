#!/usr/bin/env perl
#

use strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Perlbal;

my $tunables = Perlbal::Service::autodoc_get_tunables();

my %by_role;
while (my ($k, $tun) = each %$tunables) {
    $by_role{$tun->{check_role}}{$k} = $tun;
}

my $docs = $FindBin::Bin . "/../doc";
open (H, ">$docs/service-parameters.html") or die "Can't open $docs/service-parameters.html for writing";

print H <<HTML;
<h1 align='left'>Perlbal Service parameters</h1>Set via commands of either forms:
<pre>SET &lt;service-name&gt; &lt;param&gt; = &lt;value&gt;
SET &lt;param&gt; = &lt;value&gt;
</pre>

<p>Note on types:  'bool' values can be set using one of 1, true, yes, on, 0, false, off, or no.
'size' values are in integer bytes, or an integer followed by 'b', 'k', or 'm' (case-insensitive)
for bytes, KiB, or MiB.</p>

<p>Note that you can set defaults for all services you create by using the DEFAULT command:</p>

<pre>DEFAULT &lt;param&gt; = &lt;value&gt;</pre>
HTML

foreach my $role ("*", "reverse_proxy", "web_server") {
    if ($role eq "*") {
        print H "<h2>For all services:</h2>";
    } else {
        print H "<h2>Only for '$role' services:</h2>";
    }
    print H "<table border='2' cellspacing='1' cellpadding='4'>\n";
    print H "<tr align='left'><th>Param</th><th>type</th><th>Default</th><th>Description</th></tr>\n";

    foreach my $param (sort keys %{$by_role{$role}}) {
        my $tun = $by_role{$role}{$param};
        my $def = $tun->{default};
        my $type = $tun->{check_type} || "";
        undef $type unless $type && $type =~ /^bool|int|size$/;
        if ($type eq "bool") {
            $def = $def ? "true" : "false";
        }
        print H "<tr><td>$param</td><td>$type</td><td>$def</td><td>$tun->{des}</td></tr>\n";
    }
    print H "</table>\n";
}

system("links -dump $docs/service-parameters.html > $docs/service-parameters.txt")
    and die "Error: links not installed";
unlink "$docs/service-parameters.html";
