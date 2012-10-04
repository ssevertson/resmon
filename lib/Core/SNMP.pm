package Core::SNMP;

use strict;
use warnings;
use base 'Resmon::Module';
use Net::SNMP;

=pod

=head1 NAME

Core::SNMP - Get values via SNMP, either individual metrics or parts of tables

=head1 SYNOPSIS

 Core::SNMP {
    ProcessCount : oid => 1.3.6.1.2.1.25.1.6.0
 }

 Core::SNMP {
    NetInPackets : mode => table, oid_instance_name => 1.3.6.1.2.1.2.2.1.2, oid_names_values => packets_in 1.3.6.1.2.1.2.2.1.10 packets_out 1.3.6.1.2.1.2.2.1.16
 }
 
 Core::SNMP {
    NetInPackets : mode => table, oid_instance_name => 1.3.6.1.2.1.2.2.1.2, oid_names_values => packets_in 1.3.6.1.2.1.2.2.1.10 packets_out 1.3.6.1.2.1.2.2.1.16, oid_filter => 1.3.6.1.2.1.2.2.1.2, filter_values => nge0 nge1
 }
 

=head1 DESCRIPTION

This module retrieves metric values from an SNMP server, with two different modes of operation

In "single" mode, a single value is retrieved for the specified oid.

In "table" mode, an SNMP table is queried, using oid_instance_name as the metric name, and oid_value as the metric value.


=head1 CONFIGURATION

=over

=item check_name

Arbitrary name of the check.

=item mode

Mode of operation, either "single" or "table (defaults to "single").

=item oid

SNMP OID to query for a value in "single" mode (required if mode="single").

=item oid_instance_name

SNMP OID to query for the metric name of each item in a table (required if mode="table").

=item oid_names_values

List of names/SNMP OID pairs to query for the metric values of each item in a table, space-separated (required if mode="table").

=item oid_filter

SNMP OID to query and apply as a filter in conjunction with filter_values to each item in a table (required if filter_values is specified).

=item filter_values

Values from oid_filter to apply as a filter in conjunction with oid_filter to each item in a table (required if oid_filter is specified).

=item community

SNMP community string to use (defaults to "public").

=item hostname

SNMP hostname to use to (defaults to "127.0.0.1").

=item port

SNMP port to use to (defaults to 161).

=item name_pattern

A Perl regular expression used to transform the returned names into friendlier metric names (optional if mode=""table"", defaults to no pattern).

=back

=cut

sub new {
    my ($class, $check_name, $config) = @_;
    my $self = $class->SUPER::new($check_name, $config);
    
    my $mode = $config->{'mode'} || 'table';
    my $name_pattern = $config->{'name_pattern'};
    if ('table' eq $mode && defined($name_pattern)) {
        $name_pattern = trim_slashes($name_pattern);
        my ($name_pattern_search, $name_pattern_replace) = split(/(?<!\\)\//, $name_pattern);
        $self->{'name_pattern_search'} = $name_pattern_search;
        $self->{'name_pattern_replace'} = '"' . $name_pattern_replace . '"';
    }

    bless($self, $class);
    return $self;
}


sub get_snmp_value {
    my ($session, $oid) = @_;
    
    my $hash = $session->get_request($oid);

    if (!defined($hash)) {
        print STDERR "SNMP Failure getting OID $oid\n";
        print STDERR $session->error() . "\n";
    }
    
    return $hash->{$oid};
}

sub get_snmp_values {
    my ($session, $oid) = @_;
    
    my $hash = $session->get_table($oid);

    if (!defined($hash)) {
        print STDERR "SNMP Failure getting table OID $oid\n";
        print STDERR $session->error() . "\n";
    }
    
    return $hash;
}

sub get_last_oid {
    my ($oid) = @_;
    $oid =~ s/^[0-9.]*\.([0-9])/$1/;
    return $oid;
}

sub trim_slashes {
    my $string = shift;
    $string =~ s/^\/?(.*?)\/?$/$1/;
    return $string;
}

sub handler {

    my $self = shift;
    my $config = $self->{'config'};

    my $mode      = $config->{'mode'}      || 'single';
    my $community = $config->{'community'} || 'public';
    my $hostname  = $config->{'hostname'}  || '127.0.0.1';
    my $port      = $config->{'port'}      || 161;
    my $version   = $config->{'version'}   || 2;
    
    # Start SNMP session
    my ($session, $error) = Net::SNMP->session(
            -hostname => $hostname,
            -community => $community,
            -timeout   => "10",
            -port      => $port,
            -version  => $version);
    
    if (!defined($session)) {
        printf STDERR "ERR: $error\n";
        return;
    }
    
    my $result = {};
    if ('single' eq $mode) {
        
        my $oid = $config->{'oid'} || die "Parameter oid is required";
        
        my $name = $self->{'check_name'};
        my $value = get_snmp_value($session, $oid);
        $result->{$name} = $value;

    } elsif ('table' eq $mode) {
        
        my $oid_instance_name = $config->{'oid_instance_name'} || die "Paramter oid_instance_name is required";
        my $oid_names_values  = $config->{'oid_names_values'}  || die "Parameter oid_names_values is required";
        my $oid_filter = $config->{'oid_filter'};
        my $filter_values = $config->{'filter_values'};
        my $name_pattern_search = $self->{'name_pattern_search'};
        my $name_pattern_replace = $self->{'name_pattern_replace'};
        

        my $instance_names_by_oid = get_snmp_values($session, $oid_instance_name);
        my $instance_names_by_index = { map { get_last_oid($_) => $instance_names_by_oid->{$_} } keys %$instance_names_by_oid };

        if($oid_filter && $filter_values) {
            my $filter_values_hash = { map { $_ => 1 } split(/\s+/, $filter_values) };

            my $filter_values_by_oid = get_snmp_values($session, $oid_filter);
            my $filter_values_by_index = { map { get_last_oid($_) => $filter_values_by_oid->{$_} } keys %$filter_values_by_oid };
            
            $instance_names_by_index = { map { 
                    exists $filter_values_by_index->{$_} && exists $filter_values_hash->{$filter_values_by_index->{$_}}
                            ? ($_ => $instance_names_by_index->{$_})
                            : () } keys %$instance_names_by_index };
        }

        my %oid_name_value_hash = split(/\s+/, $oid_names_values);
        while( my ($name, $oid_value) = each %oid_name_value_hash ) {
            my $values_by_oid = get_snmp_values($session, $oid_value);
            while( my ($oid, $value) = each %$values_by_oid ) {
                my $instance_name = $instance_names_by_index->{get_last_oid($oid)};
                if($instance_name) {
                    $result->{"$instance_name-$name"} = $value;
                }
            }
        }
        
        if(defined($name_pattern_search) && defined($name_pattern_replace)) {
            my $transformed = {};
            while( my ($key, $val) = each %$result ) {
                $key =~ s/$name_pattern_search/$name_pattern_replace/gee;
                $transformed->{$key} = $val;
            }
            $result = $transformed;
        }
        
    } else {
        
        die "Unsupported mode $mode";
        
    }
    $session->close();
    
    return $result;
};
1;
