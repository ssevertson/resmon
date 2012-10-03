package Core::MetricsFile;

use strict;
use warnings;

use base 'Resmon::Module';

=pod

=head1 NAME

Core::MetricsFile - retrieve metrics from a flat file

=head1 SYNOPSIS

 Core::MetricsFile {
     local : file => /path/to/metrics/file
 }
 
 Core::MetricsFile {
     local : file => /path/to/metrics/file, metric_separator_pattern => / /, key_value_separator_pattern => /:/
 }
 
 Core::MetricsFile {
     * : file => /path/to/metrics/multi-line-file, check_name_key => id
 }

=head1 DESCRIPTION

Retrieve metrics from existing flat file.

=head1 CONFIGURATION

=over

=item check_name

Arbitrary name of the check, or * if file contains multiple checks. If * is
specified, check_name_key must also be specified, and any values in the file
for this key will be used as check names.

=item file

The full path to the file containing metrics data (required).

=item metric_separator_pattern

A regular expression that defines how multiple metrics are separated (defaults to / /)

=item key_value_separator_pattern

A regular expression that defines how metric keys are are separated from values (defaults to /:/)

=item check_name_key

If the file contains multiple checks, the key that's value will be used as the check name (valid and required only if * specified as check_name)

=back

=head1 METRICS

=over

=item *

Metrics depend on contents of file.

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
    my $file = $config->{'file'} || die "File is required.\n";
    
    local $/=undef;
    open(my $FH, "<", $file) or die "Couldn't open file $file: $!\n";
    my $output = <$FH>;
    close $FH;
    
    return $self->content_to_hash($output);
}

sub wildcard_handler {
    my $self = shift;
    my $config = $self->{'config'};
    my $file = $config->{'file'} || die "File is required.\n";
    my $check_name_key= $config->{'check_name_key'} || die "Check name key is required.\n";
    
    open(my $FH, "<", $file) or die "Couldn't open file $file: $!\n";
    my @output = <$FH>; 
    close $FH;
    
    my $result = {};
    my $line_counter = 0;
    foreach my $line (@output) {
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