package Core::KStat;

use strict;
use warnings;

use base 'Resmon::Module';
use List::Util qw(sum);
use Sun::Solaris::Kstat;

=pod

=head1 NAME

Core::KStat - Get Solaris kernel metrics

=head1 SYNOPSIS

 Core::KStat {
     run_queue_length : mode => ratio, numerator => unix::sysinfo:runque, denominator => unix::sysinfo:updates
 }
 
 Core::KStat {
     page_in  : mode => sum, kstats => cpu::vm:pgpgin
    page_out : mode => sum, kstats => cpu::vm:pgpgout
 }

=head1 DESCRIPTION

This module retrieves metrics from Solaris's KStat subsystem, and performs one of several mathematical operations on it.

=head1 CONFIGURATION

=over

=item check_name

Arbitrary name of the check.

=item mode

Mathematical operation to perform on the results, one of value, sum, average, ratio, percent (optional, defaults to value).

=item kstat_numerator

KStat query to use as numerator, returning a single result (required if mode is ratio or percent).

=item kstat_denominator

KStat query to use as denominator, returning a single result (required if mode is ratio or percent).

=item kstat

KStat query, returning a single result (required if mode is value).

=item kstats

KStats queries, space separated, returning one or more values (required if mode is sum or average).

=back

=head1 METRICS

=over

=item result

The result of performing the operation on the KStat(s).

=back

=cut

sub get_kstat_values {
    my $kstat_query = shift;
    my %kstat_hash = @_;
    my ($module_part, $instance_part, $name_part, $statistic_part) = split_kstat_query($kstat_query);

    my @values = ();
    foreach my $module (get_hash_keys($module_part, %kstat_hash)) {
        my %module_hash = %{$kstat_hash{$module}};
        foreach my $instance (get_hash_keys($instance_part, %module_hash)) {
            my %instance_hash = %{$module_hash{$instance}};
            foreach my $name (get_hash_keys($name_part, %instance_hash)) {
                my %statistic_hash = %{$instance_hash{$name}};
                foreach my $statistic (get_hash_keys($statistic_part, %statistic_hash)) {
                    my $value = $statistic_hash{$statistic};
                    push(@values, $value);
                }
            }
        }
    }

    if (@values == 0) {
        die "kstat query \"$kstat_query\": Statistic not found\n";
    }

    return @values;
}

sub get_kstat_value {
    my $kstat_query = shift;
    my %kstat_hash = @_;
    my @values = get_kstat_values($kstat_query, %kstat_hash);

    if (@values > 1)
    {
        die "kstat query \"$kstat_query\": Matched multiple statistics\n";
    }
    return $values[0];
}

sub get_hash_keys {
    my $key = shift;
    my %hash = @_;

    if(! defined($key) || $key eq '') {
        my @keys = keys(%hash);
        return @keys;
    }
    elsif(exists $hash{$key}) {
        return ($key);
    }
    else {
        return ();
    }
}

sub split_kstat_query {
    my ($query) = @_;
    my @parts = split(/:/, $query, 4);
    if (@parts != 4 || $parts[3] eq '') {
        die "kstat_query must match format: [module]:[instance]:[name]:statistic\n";
    }
    return @parts;
}

sub new {
    my ($class, $check_name, $config) = @_;
    my $self = $class->SUPER::new($check_name, $config);
    
    $self->{'kstat'} = Sun::Solaris::Kstat->new();

    bless($self, $class);
    return $self;
}

sub handler {
    my $self = shift;
    my $config = $self->{'config'};
    my $mode = $config->{'mode'} || 'value';

    my $kstat = $self->{'kstat'};
    $kstat->update();

    my $result;
    if($mode eq 'value') {
        
        my $kstat_query = $config->{'kstat'} || die "KStat query is required.\n";
        
        $result = get_kstat_value($kstat_query, %$kstat);
        
    } elsif($mode eq 'ratio' || $mode eq 'percent') {
    
        my $kstat_numerator = $config->{'kstat_numerator'} || die "KStat numerator is required.\n";
        my $kstat_denominator = $config->{'kstat_denominator'} || die "KStat denominator is required.\n";

        my $numerator = get_kstat_value($kstat_numerator, %$kstat);
        my $denominator = get_kstat_value($kstat_denominator, %$kstat);
        
        if($mode eq 'ratio') {
            $result = ($numerator / $denominator);
        } elsif ($mode eq 'percent') {
            $result = (100 * $numerator / ($numerator + $denominator) );
        }

    } elsif($mode eq 'sum' || $mode eq 'average') {
    
        my $kstat_queries = $config->{'kstats'} || die "One or more KStat queries are required.\n";
        my @kstat_values = split(/\s+/, $config->{'kstats'});
    
        my @values = ();
        foreach my $kstat_query (@kstat_values) {
            push(@values, get_kstat_values($kstat_query, %$kstat));
        }
        $result = sum(@values);
        
        if("average" eq $mode) {
            $result /= scalar(@values);
        }

    } else {
        die "Unsupported mode: $mode\n";
    }
    
    return {
        'result' => [$result, 'n']
    };
};

1;
