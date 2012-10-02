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

=head1 DESCRIPTION

Retrieve metrics from existing flat file.

=head1 CONFIGURATION

=over

=item check_name

Arbitrary name of the check.

=item file

The full path to the file containing metrics data (required).

=item metric_separator_pattern

A regular expression that defines how multiple metrics are separated (defaults to / /)

=item key_value_separator_pattern

A regular expression that defines how metric keys are are separated from values (defaults to /:/)

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

sub handler {
    my $self = shift;
    my $config = $self->{'config'};
    my $file = $config->{'file'} || die "File is required.\n";
    my $metric_separator_pattern = $self->{'metric_separator_pattern'};
    my $key_value_separator_pattern = $self->{'key_value_separator_pattern'};
    
    local $/=undef;
    open FH, $file or die "Couldn't open file $file: $!";
    my $content = <FH>;
    close FH;
    
    my @metrics_array = split(/$metric_separator_pattern/, $content);
    
    my $result = {};
    foreach my $metric (@metrics_array) {
        my ($key, $val) = split(/$key_value_separator_pattern/, $metric);
        
        $result->{$key} = [$val, 'n'];
    }
    
    return $result;
}

1;