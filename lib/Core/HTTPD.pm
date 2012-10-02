package Core::HTTPD;

use strict;
use warnings;

use base 'Resmon::Module';

use LWP::UserAgent;

=pod

=head1 NAME

Core::HTTPD - monitor HTTPD stats via mod_status

=head1 SYNOPSIS

 Core::HTTPD {
     local : url => http://server.example.com/path/to/mod_status/
 }

 Core::HTTPD {
     local : url => http://server.example.com/path/to/mod_status/, username => username, password => password
 }

=head1 DESCRIPTION

This module monitors HTTPD statistics via HTTP/HTTPS requests to mod_status.

=head1 CONFIGURATION

=over

=item check_name

Arbitrary name of the check.

=item url

The mod_status URL to connect to.

=item username

The basic authentication username to send when requesting statistics (required if password is specified).

=item password

The basic authentication password to send when requesting statistics (required if username is specified).

=back

=head1 METRICS

=over

=item total_hits

Total number of requests

=item total_bytes

Total number of bytes transfered

=item cpu_load

Current CPU load from the HTTPD processes.

=item busy_workers

Current count of busy workers/servers.

=item idle_workers

Current count of idle workers/servers.

=item threads_waiting

Current count of threads waiting for a connection.

=item threads_starting

Current count of threads starting up..

=item threads_reading

Current count of threads reading a request.

=item threads_writing

Current count of threads writing a response.

=item threads_keep_alive

Current count of threads idle in keep alive.

=item threads_dns_lookup

Current count of threads performing a DNS lookup.

=item threads_closing

Current count of threads closing a connection.

=item threads_logging

Current count of threads logging.

=item threads_stopping

Current count of threads gracefully finishing.

=item threads_idle

Current count of threads idle.

=item threads_available

Current count of thread slots with no current process.

=back

=cut


sub new {
    my ($class, $check_name, $config) = @_;
    my $self = $class->SUPER::new($check_name, $config);
    
    $self->{'user_agent'} = LWP::UserAgent->new();
    $self->{'user_agent'}->agent('Resmon');
    $self->{'user_agent'}->timeout($config->{'check_timeout'} || 10);
    
    $self->{'scoreboard_keys'} = {
        '_' => 'threads_waiting',
        'S' => 'threads_starting',
        'R' => 'threads_reading',
        'W' => 'threads_writing',
        'K' => 'threads_keep_alive',
        'D' => 'threads_dns_lookup',
        'C' => 'threads_closing',
        'L' => 'threads_logging',
        'G' => 'threads_stopping',
        'I' => 'threads_idle',
        '.' => 'threads_available',
    };

    bless($self, $class);
    return $self;
}

sub handler {
    my $self = shift;
    my $config = $self->{'config'};
    my $url = $config->{'url'} || die "URL is required.\n";
    my $username = $config->{'username'};
    my $password = $config->{'password'};
    
    my $user_agent = $self->{'user_agent'};
    my $scoreboard_keys = $self->{'scoreboard_keys'};
    
    my $request = HTTP::Request->new(GET => "$url?auto");
    if($username && $password) {
        $request->authorization_basic($username, $password);
    }
    
    my $response = $user_agent->request($request);
    $response->is_success || die "HTTP GET failed to $url: " . $response->status_line . "\n";
    
    my $content = $response->decoded_content();
    
    my $result = { map { $_ => 0 } values %$scoreboard_keys };
    foreach my $line (split(/\n/, $content)) {
        my ($key, $val) = split(/: /, $line);

        if ($key eq 'Total Accesses') {
            $result->{'total_hits'}   = [$val, 'n'];
        } elsif ($key eq 'Total kBytes') {
            $result->{'total_bytes'}  = [$val * 1024, 'n'];
        } elsif ($key eq 'CPULoad') {
            $result->{'cpu_load'}     = [$val, 'n'];
        } elsif ($key =~ /^Busy/) {
            $result->{'busy_workers'} = [$val, 'n'];
        } elsif ($key =~ /^Idle/) {
            $result->{'idle_workers'} = [$val, 'n'];
        } elsif ($key eq 'Scoreboard') {
            my @chars = split(//, $val);
            foreach my $state (split(//, $val)) {
                $result->{$scoreboard_keys->{$state}}++;
            }
        }
    }
    
    return $result;
}

1;