package Resmon::Status;

use strict;
use warnings;
use POSIX qw/:sys_wait_h strftime/;
use IO::Handle;
use IO::File;
use IO::Socket;
use Socket;
use Fcntl qw/:flock/;
use Data::Dumper;
use File::Basename;

my $KEEPALIVE_TIMEOUT = 5;
my $REQUEST_TIMEOUT = 60;
sub new {
    my $class = shift;
    my $file = shift;
    # State file used for communication between monitor and webserver
    # processes
    my $statefile = dirname($file)."/.".basename($file).".state";
    my $fh = IO::File->new("$statefile", "+>");
    die "$0: Unable to open $statefile: $!\n" unless (defined $fh);
    # Delete the just opened file - it stays open, but doesn't show on disk
    unlink ".$file.state";
    return bless {
        file => $file,
        shared_state => $fh
    }, $class;
}

sub get_shared_state {
    my $self = shift;
    my $fh = $self->{shared_state};
    if (defined $fh) {
        flock($fh, LOCK_EX); # Obtain a lock on the file
        my $VAR1;
        $fh->seek(0, 0);
        my $blob;
        {
            local $/ = undef;
            $blob = <$fh>;
        }
        flock($fh, LOCK_UN); # Release the lock
        eval $blob;
        die $@ if ($@);
        $self->{store} = $VAR1;
    } else {
        die "Unable to read shared state";
    };
    return $self->{store};
}

sub store_shared_state {
    my $self = shift;
    my $fh = $self->{shared_state};
    if (defined($fh)) {
        flock($fh, LOCK_EX); # Obtain a lock on the file
        $fh->truncate(0);
        $fh->seek(0,0);
        print $fh Dumper($self->{store});
        $fh->flush();
        flock($fh, LOCK_UN); # Release the lock
    } else {
        die "Unable to store shared state";
    };
}

sub xml_kv_dump {
    my $info = shift;
    my $indent = shift || 0;
    my $rv = '';
    foreach my $key (sort keys %$info) {
        my $value = $info->{$key}; 
        if(ref $value eq 'HASH') {
            foreach my $k (sort keys %$value) {
                my $v = $value->{$k}; 
                $rv .= " " x $indent;
                $rv .= "<$key name=\"$k\"";
                if (ref($v) eq 'ARRAY') {
                    # A value/type pair
                    my $type = $v->[1];
                    if ($type !~ /^[0iIlLns]$/) {
                        $type = "0";
                    }
                    $rv .= " type=\"$type\"";
                    $v = $v->[0];
                }
                $v = xml_escape($v);
                $rv .= ">$v</$key>\n";
            }
        } else {
            $rv .= " " x $indent;
            $value = xml_escape($value);
            $rv .= "<$key>$value</$key>\n";
        }
    }
    return $rv;
}

sub plain_kv_dump {
    my $info = shift;
    my $indent = shift || 0;
    my $rv = '';
    foreach my $key (sort keys %$info) {
        my $value = $info->{$key};
        if(ref $value eq 'HASH') {
            foreach my $k (sort keys %$value) {
                my $v = $value->{$k};
                #$rv .= " " x $indent;
                $rv .= "$k";
                if (ref($v) eq 'ARRAY') {
                    # A value/type pair
                    my $type = $v->[1];
                    if ($type !~ /^[0iIlLns]$/) {
                        $type = "0";
                    }
                    #$rv .= " type=\"$type\"";
                    $v = $v->[0];
                }
                $rv .= "=$v\n";
            }
        } else {
            #$rv .= " " x $indent;
            $rv .= "resmon_$key=$value\n";
        }
    }
    $rv .= "\n";
    return $rv;
}

sub xml_info {
    my ($module, $service, $info) = @_;
    my $rv = '';
    $rv .= "  <ResmonResult module=\"$module\" service=\"$service\">\n";
    $rv .= xml_kv_dump($info, 4);
    $rv .= "  </ResmonResult>\n";
    return $rv;
}

sub plain_info {
    my ($module, $service, $info) = @_;
    my $rv = '';
    $rv .= "[$module`$service]\n";
    $rv .= plain_kv_dump($info, 4);
    return $rv;
}

sub xml_escape {
    my $v = shift;
    $v =~ s/&/&amp;/g;
    $v =~ s/</&lt;/g;
    $v =~ s/>/&gt;/g;
    $v =~ s/'/&apos;/g;
    return $v;
}

sub dump_generic {
    my $self = shift;
    my $dumper = shift;
    my $rv = '';
    foreach my $module (sort keys %{$self->{store}}) {
        my $services = $self->{store}->{$module};
        foreach my $service (sort keys %$services) {
            my $info = $services->{$service};
            $rv .= $dumper->($module,$service,$info);
        }
    }
    return $rv;
}

sub dump_generic_module {
    # Dumps a single module rather than all checks
    my $self = shift;
    my $dumper = shift;
    my $module = shift;
    my $rv = '';
    my $services = $self->{store}->{$module};
    foreach my $service (sort keys %$services) {
        my $info = $services->{$service};
        $rv .= $dumper->($module,$service,$info);
    }
    return $rv;
}

sub dump_xml {
    my $self = shift;
    my $response = <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="/resmon.xsl"?>
<ResmonResults>
EOF
    ; 
    $response .= $self->dump_generic(\&xml_info);
    $response .= "</ResmonResults>\n";
    return $response;
}

sub dump_json {
    my $self = shift;

    my $json_root = {};
    foreach my $module (sort keys %{$self->{store}}) {
        my $services = $self->{store}->{$module};
        foreach my $service (sort keys %$services) {

            my $json_service = {};
            $json_root->{$module . "::" . $service} = $json_service;

            my $info = $services->{$service};

            foreach my $key (sort keys %$info) {
                my $value = $info->{$key};
                if(ref $value eq 'HASH') {
                    foreach my $k (keys %$value) {
                        my $v = $value->{$k};

                        my $type = "0";
                        if (ref($v) eq 'ARRAY') {
                            $type = $v->[1];
                            if ($type !~ /^[0iIlLns]$/) {
                                $type = "0";
                            }
                            $v = $v->[0];
                        }
                        if ($type !~ /^[0s]$/) {
                            $v = 1 * $v; # Force numeric
                        }
                	$json_service->{$k} = $v;
                    }
                }
            }
        }
    }

    eval 'use JSON;';
    my $json = JSON->new();
    return $json->pretty->encode($json_root);
}

sub dump_plain {
    my $self = shift;
    my $response = $self->dump_generic(\&plain_info);
    return $response;
}

sub get_xsl() {
    my $response = <<EOF
<?xml version="1.0" encoding="ISO-8859-1"?>
<xsl:stylesheet version="1.0"
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
<xsl:template match="ResmonResults">
<html>
<head>
    <title>Resmon Results</title>
    <link rel="stylesheet" type="text/css" href="/resmon.css" />
</head>
<body>
    <p>
    Total checks:
    <xsl:value-of select="count(ResmonResult)" />
    </p>
    <xsl:for-each select="ResmonResult">
        <xsl:sort select="\@module" />
        <xsl:sort select="\@service" />
        <div class="item">
            <div class="info">
                Last check: <xsl:value-of select="last_runtime_seconds" />
                /
                Last updated: <xsl:value-of select="last_update" />
            </div>
            <h1>
                <a>
                    <xsl:attribute name="href">
                        /<xsl:value-of select="\@module" />
                    </xsl:attribute>
                    <xsl:value-of select="\@module" />
                </a>`<a>
                    <xsl:attribute name="href">
                        /<xsl:value-of select="\@module"
                            />/<xsl:value-of select="\@service" />
                    </xsl:attribute>
                    <xsl:value-of select="\@service" />
                </a>
            </h1>
            <ul>
                <xsl:for-each select="metric">
                    <xsl:sort select="\@name" />
                    <li><xsl:value-of select="\@name" /> = 
                    <xsl:value-of select="." /></li>
                </xsl:for-each>
            </ul>
        </div>
    </xsl:for-each>
</body>
</html>
</xsl:template>
</xsl:stylesheet>
EOF
    ;
    return $response;
}
sub get_css() {
    my $response=<<EOF
body {
    font-family: Verdana, Arial, helvetica, sans-serif;
}

h1 {
    margin: 0;
    font-size: 120%;
}

h2 {
    margin: 0;
    font-size: 110%;
}

.item {
    border: 1px solid black;
    border-left: 10px solid #999;
    padding: 1em;
    margin: 2em;
    background-color: #eeeeee;
}

.info {
    float: right;
    font-size: 80%;
    padding: 0;
    margin: 0;
}

table {
    border: 1px solid black;
    background-color: #eeeeee;
    border-collapse: collapse;
    margin: 1em;
    font-size: 80%;
}

th {
    font-size: 100%;
    font-weight: bold;
    background-color: black;
    color: white;
}

td {
    padding-left: 1em;
    padding-right: 1em;
}

a {
    text-decoration: none;
}

a.metrics, a.metrics:visited {
    color: black;
}

a.metrics table {
    display: none;
}

a.metrics:hover table {
    display: block;
    position: relative;
    top: 1em;
    right: 1em;
    max-width: 95%;
    overflow: hidden;
}
EOF
    ;
    return $response;
}

sub service {
    my $self = shift;
    my ($client, $req, $proto, $snip, $authuser, $authpass) = @_;
    my $state = $self->get_shared_state();
    if (defined($self->{authuser}) && $self->{authuser} ne "" &&
        ($authuser ne $self->{authuser} || $authpass ne $self->{authpass})) {
        my $response = "<html><head><title>Password required</title></head>" .
        "<body><h1>Password required</h1></body></html>";
        $client->print(http_header(401, length($response), 'text/html', $snip,
                "WWW-Authenticate: Basic realm=\"Resmon\"\n"));
        $client->print($response . "\r\n");
        return;
    } elsif($req eq '/') {
        my $response .= $self->dump_xml();
        $client->print(http_header(200, length($response), 'text/xml', $snip));
        $client->print($response . "\r\n");
        return;
    } elsif($req eq '/?plain') {
        my $response .= $self->dump_plain();
        $client->print(http_header(200, length($response), 'text/plain', $snip));
        $client->print($response . "\r\n");
        return;
    } elsif($req eq '/resmon.xsl') {
        my $response = $self->get_xsl();
        $client->print(http_header(200, length($response), 'text/xml', $snip));
        $client->print($response . "\r\n");
        return;
    } elsif($req eq '/resmon.css') {
        my $response = $self->get_css();
        $client->print(http_header(200, length($response), 'text/css', $snip));
        $client->print($response . "\r\n");
        return;
    } elsif($req =~ /^\/([^\/]+)\/(.+)\?plain$/) {
        if(exists($self->{store}->{$1}) &&
            exists($self->{store}->{$1}->{$2})) {
            my $info = $self->{store}->{$1}->{$2};
            my $response = plain_info($1,$2,$info);
            $client->print(http_header(200, length($response), 'text/plain', $snip));
            $client->print( $response . "\r\n");
            return;
        }
    } elsif($req =~ /^\/([^\/]+)\/(.+)$/) {
        if(exists($self->{store}->{$1}) &&
            exists($self->{store}->{$1}->{$2})) {
            my $info = $self->{store}->{$1}->{$2};
            my $response = qq^<?xml version="1.0" encoding="UTF-8"?>\n^;
            $response .= qq^<?xml-stylesheet type="text/xsl" href="/resmon.xsl"?>^;
            $response .= "<ResmonResults>\n".
            xml_info($1,$2,$info).
            "</ResmonResults>\n";
            $client->print(http_header(200, length($response), 'text/xml', $snip));
            $client->print( $response . "\r\n");
            return;
        }
    } elsif($req =~ /^\/([^\/]+)\?plain$/) {
        if(exists($self->{store}->{$1})) {
            my $response = $self->dump_generic_module(\&plain_info,$1);
            $client->print(http_header(200, length($response), 'text/plain', $snip));
            $client->print( $response . "\r\n");
            return;
        }
    } elsif($req =~ /^\/([^\/]+)$/) {
        if(exists($self->{store}->{$1})) {
            my $response = qq^<?xml version="1.0" encoding="UTF-8"?>\n^;
            $response .= qq^<?xml-stylesheet type="text/xsl" href="/resmon.xsl"?>^;
            $response .= "<ResmonResults>\n".
            $self->dump_generic_module(\&xml_info,$1) .
            "</ResmonResults>\n";
            $client->print(http_header(200, length($response), 'text/xml', $snip));
            $client->print( $response . "\r\n");
            return;
        }
    }
    die "Request not understood\n";
}

sub http_header {
    my $code = shift;
    my $len = shift;
    my $type = shift || 'text/xml';
    my $close_connection = shift || 1;
    my $extra_headers = shift || "";
    return "HTTP/1.0 $code OK\nServer: resmon\n" .
        (defined($len) ? "Content-length: $len\n" : "") .
    (($close_connection || !$len) ? "Connection: close\n" : "") .
    "Content-Type: $type; charset=utf-8\n" . $extra_headers . "\n";
}

sub base64_decode($) {
    # Base64 decoding for basic auth
    # We cheat when doing the decoding - perl can do uudecoding using unpack -
    # so we just convert to uuencoded text and decode that.
    my $enc = shift;
    if (length($enc) % 4 != 0) { return "" } # Length should be multiple of 4
    $enc =~ tr#A-Za-z0-9+/=##cd; # Ignore any invalid characters
    $enc =~ tr#A-Za-z0-9+/=# -_#d; # Convert base64 to uuencode alphabet and
    # strip padding
    if (length($enc) > 63) { return "" }; # Only support up to 63 chars
    # (one uuencoded line)
    my $len = chr(32 + length($enc)*3/4); # uuencode has a length byte at the
    # beginning
    return unpack("u", $len.$enc);
}

sub serve_http_on {
    my $self = shift;
    my $ip = shift;
    my $port = shift;
    $self->{authuser} = shift;
    $self->{authpass} = shift;
    my $hostsallow = shift;

    if(!defined($ip) || $ip eq '' || $ip eq '*') {
        $ip = INADDR_ANY;
    } else {
        $ip = inet_aton($ip);
    }
    $port ||= 81;

    my $handle = IO::Socket->new();
    socket($handle, PF_INET, SOCK_STREAM, getprotobyname('tcp'))
        || die "socket: $!";
    setsockopt($handle, SOL_SOCKET, SO_REUSEADDR, pack("l", 1))
        || die "setsockopt: $!";
    bind($handle, sockaddr_in($port, $ip))
        || die "bind: $!";
    listen($handle,SOMAXCONN);

    $self->{http_port} = $port;
    $self->{http_ip} = $ip;

    $self->{parent_pid} = $$;
    $self->{child} = fork();
    if($self->{child} == 0) {
        eval {
            $SIG{'HUP'} = 'IGNORE';
            $SIG{'PIPE'} = 'IGNORE';
            while(1) {
                my $client = $handle->accept;
                next unless $client;
                my $hersockaddr    = getpeername($client);
                my ($port, $iaddr) = sockaddr_in($hersockaddr);
                my $denied;
                 for my $el (@{$hostsallow}) {
                  my $tmp = unpack("N",$iaddr);
                  $tmp = $tmp >> $el->{bits} if $el->{bits};
                  if ($tmp == $el->{mask}) {
                    $denied = !$el->{allow};
                    last;
                  }
                }
                if ($denied) {
                  my $response = "<html><head><title>IP denied</title></head>" .
                  "<body><h1>IP denied</h1></body></html>";
                  $client->print(http_header(401, length($response), 'text/html', $denied));
                  $client->print($response . "\r\n");
                  $client->close();
                  next
                };
                my $req;
                my $proto;
                my $close_connection;
                my $authuser;
                my $authpass;
                local $SIG{ALRM} = sub { die "timeout\n" };
                eval {
                    alarm($KEEPALIVE_TIMEOUT);
                    while(<$client>) {
                        alarm($REQUEST_TIMEOUT);
                        eval {
                            s/\r\n/\n/g;
                            chomp;
                            if(!$req) {
                                if(/^GET \s*(\S+)\s*?(?: HTTP\/(0\.9|1\.0|1\.1)\s*)?$/) {
                                    $req = $1;
                                    $proto = $2;
                                    # Protocol 1.1 and high are keep-alive by
                                    # default
                                    $close_connection = ($proto <= 1.0)?1:0;
                                }
                                elsif(/./) {
                                    die "protocol deviations.\n";
                                }
                            }
                            else {
                                if(/^$/) {
                                    $self->service($client, $req, $proto, $close_connection,
                                        $authuser, $authpass);
                                    last if ($close_connection);
                                    alarm($KEEPALIVE_TIMEOUT);
                                    $req = undef;
                                    $proto = undef;
                                }
                                elsif(/^\S+\s*:\s*.{1,4096}$/) {
                                    # Valid request header... noop
                                    if(/^Connection: (\S+)/) {
                                        if(($proto <= 1.0 && lc($2) eq 'keep-alive') ||
                                            ($proto == 1.1 && lc($2) ne 'close')) {
                                            $close_connection = 0;
                                        }
                                    }
                                    if(/^Authorization: Basic (\S+)/) {
                                        my $dec = base64_decode($1);
                                        ($authuser, $authpass) = split /:/, $dec, 2
                                    }
                                }
                                else {
                                    die "protocol deviations.\n";
                                }
                            }
                        };
                        if($@) {
                            print $client http_header(500, 0, 'text/plain', 1);
                            print $client "$@\r\n";
                            last;
                        }
                    }
                    alarm(0);
                };
                alarm(0) if($@);
                $client->close();
            }
        };
        if($@) {
            print STDERR "Error in listener: $@\n";
        }
        exit(0);
    }
    close($handle);
    return;
}

sub init_http_trap {
    my $self = shift;
    $self->{httptrap} = shift;
    
    eval 'use LWP::UserAgent;';
    my $user_agent = LWP::UserAgent->new;
    $user_agent->agent('Resmon');
    
    $self->{user_agent} = $user_agent;
}

sub http_trap {
    my ($self, $debug) = @_;
    my $payload = $self->dump_json();

    my $request = HTTP::Request->new(PUT => $self->{httptrap});
    $request->content_type('application/json');
    $request->content($payload);

    my $now = time();
    my $response = $self->{user_agent}->request($request);

    my $timestamp = strftime("%Y-%m-%dT%H:%M:%S %z", localtime($now));

    # Check the outcome of the response
    if (!$response->is_success) {
        print STDERR "$timestamp: Failed on PUT to HTTP trap: $self->{httptrap}\n";
        print STDERR "Request: $payload\n";
        print STDERR "Response: " . $response->status_line . "\n";
        print STDERR $response->content . "\n";
    }
    else {
        print "$timestamp: Success on PUT to HTTP trap: $self->{httptrap}\n" if $debug;
    }
}

sub open {
    my $self = shift;
    return 0 unless(ref $self);
    return 1 if($self->{handle});  # Already open
    if($self->{file} eq '-' || !defined($self->{file})) {
        # We'll use stdout instead - no file handle needed
        return 1;
    }
    $self->{handle} = IO::File->new("> $self->{file}.swap");
    die "open $self->{file}.swap failed: $!\n" unless($self->{handle});
    $self->{swap_on_close} = 1; # move this to a non .swap version on close
    chmod 0644, "$self->{file}.swap";

    return 1;
}

sub store {
    my ($self, $type, $name, $info) = @_;
    %{$self->{store}->{$type}->{$name}} = %$info;
    $self->{store}->{$type}->{$name}->{last_update} = time;
    $self->store_shared_state();
}

sub clear {
    # Clear all state after a reload
    my $self = shift;
    $self->{store} = {};
    $self->store_shared_state;
}

sub write {
    # Writes the metrics output for a single check to stdout and/or a file
    my ($self, $module_name, $check_name, $metrics, $debug) = @_;
    my $metrics_output = "$module_name`$check_name\n";
    foreach my $k (sort keys %$metrics) {
        my $v = $metrics->{$k};
        if (ref($v) eq "ARRAY") {
            $v = $v->[0];
        }
        $metrics_output .= "    $k = $v\n";
    }
    if($self->{handle}) {
        $self->{handle}->print($metrics_output);
    }
    if (!$self->{handle} || $debug) {
        print $metrics_output;
    }
}

sub close {
    my $self = shift;
    $self->{handle}->close() if($self->{handle});
    $self->{handle} = undef;
    if($self->{swap_on_close}) {
        unlink("$self->{file}");
        link("$self->{file}.swap", $self->{file});
        unlink("$self->{file}.swap");
        delete($self->{swap_on_close});
    }
}

sub DESTROY {
    my $self = shift;
    # Make sure we're really the parent process
    return if (defined $self->{parent_pid} && $self->{parent_pid} != $$);
    my $child = $self->{child};
    if ($child) {
        kill 15, $child;
        sleep 1;
        kill 9, $child if(kill 0, $child);
        waitpid(-1,WNOHANG);
    }
}
1;
