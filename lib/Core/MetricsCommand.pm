package Core::MetricsCommand;

use strict;
use warnings;

use base 'Resmon::Module';

use Resmon::ExtComm qw(run_command);

=pod

=head1 NAME

Core::MetricsCommand - retrieve metrics from an executable

=head1 SYNOPSIS

 Core::MetricsCommand {
     local : cmd => /path/to/executable -arguments
 }
 
 Core::MetricsCommand {
     local : cmd => /path/to/executable -arguments, metric_separator_pattern => / /, key_value_separator_pattern => /:/
 }
 
 Core::MetricsCommand {
     * : cmd => /path/to/executable -arguments, check_name_key => id
 }

=head1 DESCRIPTION

Retrieve metrics by running an executable.

=head1 CONFIGURATION

=over

=item check_name

Arbitrary name of the check, or * if executable returns multiple checks. If * is
specified, check_name_key must also be specified, and any values in the output
for this key will be used as check names.

=item cmd

The command and any arguments to run (required).

=item metric_separator_pattern

A regular expression that defines how multiple metrics are separated (defaults to / /)

=item key_value_separator_pattern

A regular expression that defines how metric keys are are separated from values (defaults to /:/)

=item check_name_key

If the executable returns multiple checks, the key that's value will be used as the check name (valid and required only if * specified as check_name)

=back

=head1 METRICS

=over

=item *

Metrics depend on results of the executable.

=back

=cut

sub new {
    my ($class, $check_name, $config) = @_;
    my $self = $class->SUPER::new($check_name, $config);
    
    my $metric_separator_pattern = $config->{'metric_separator_pattern'} || '/ /';
    $self->{'metric_separator_pattern'} = trim_slashes($metric_separator_pattern);
    
    my $key_value_separator_pattern = $config->{'key_value_separator_pattern'} || '/:/';
    $self->{'key_value_separator_pattern'} = trim_slashes($key_value_separator_pattern);

    bless($self, $class);
    return $self;
}

sub trim_slashes {
    my $string = shift;
    $string =~ s/^\/?(.*?)\/?$/$1/;
    return $string;
}

sub content_to_hash {
    my ($self, $content) = @_;
    
    my $result = {};
    
    my @metrics_array = split(/$self->{'metric_separator_pattern'}/, $content);
    foreach my $metric (@metrics_array) {
        chomp($metric);
        my ($key, $val) = split(/$self->{'key_value_separator_pattern'}/, $metric);
        $result->{$key} = [$val, 'n'];
    }
    
    return $result;
}

sub handler {
    my $self = shift;
    my $config = $self->{'config'};
    my $cmd = $config->{'cmd'} || die "Command is required.\n";
    
    my $output = run_command($cmd);
    
    return $self->content_to_hash($output);
}

sub wildcard_handler {
    my $self = shift;
    my $config = $self->{'config'};
    my $cmd = $config->{'cmd'} || die "Command is required.\n";
    my $check_name_key= $config->{'check_name_key'} || die "Check name key is required.\n";
    
    my $output = run_command($cmd);

    my $result = {};
    my $line_counter = 0;
    foreach my $line (split(/\n/, $output)) {
        my $line_result = $self->content_to_hash($line);
        
        my $check_name = delete($line_result->{$check_name_key});
        if(defined($check_name)) {
            if (ref($check_name) eq 'ARRAY') {
                $check_name = ${$check_name}[0];
            }
        } else {
            $check_name = "unknown_$line_counter";
        }
        
        $result->{$check_name} = $line_result;
        $line_counter++;
    }
    
    return $result;
}

1;