package Core::JMX;

use strict;
use warnings;

use base 'Resmon::Module';

use JMX::Jmx4Perl;

=pod

=head1 NAME

Core::JMX - monitor JMX stats via Jmx4Perl/Jolokia

=head1 SYNOPSIS

 Core::JMX {
     memorypool : query => java.lang:type=MemoryPool\,name=*, attributes => Usage, metric_pattern => /^.*?=(.+?)\,.*_(.*)$/$1_$2/
 }

 Core::JMX {
     memory : query => java.lang:type=Memory, attributes => HeapMemoryUsage,NonHeapMemoryUsage
 }

=head1 DESCRIPTION

This module monitors arbitrary JMX statistics usage using jmx4perl/jolokia.

=head1 CONFIGURATION

=over

=item check_name

Arbitrary name of the check.

=item url

The Jolokia URL to connect to (optional; defaults to "http://localhost:8778/jolokia/").

=item username

The basic authentication username to send when requesting JMX statistics (required if password is specified).

=item password

The basic authentication password to send when requesting JMX statistics (required if username is specified).

=item query

The JMX query to perform (required if alias is not specified).

=item attributes

The JMX attributes to return, comma-separated (optional when query is specified, otherwise all attributes for query are returned).

=item alias

The name of a Jmx4Perl alias (required if query is not specified).

=item product

The name of a Jmx4Perl product (optional but recommended when using an alias; defaults to "unknown").

=item metric_pattern

A Perl regular expression used to transform the returned JMX names into friendlier metric names (recommended for most queries).

=back

=head1 METRICS

=over

=item *

Metrics as reported by JMX, and transformed by metric_pattern.

=back

=cut

sub new {
    my ($class, $check_name, $config) = @_;
    my $self = $class->SUPER::new($check_name, $config);
    
    my $url = $config->{'url'} || 'http://localhost:8778/jolokia/';
    my $username = $config->{'username'};
    my $password = $config->{'password'};
    my $product = $config->{'product'} || 'unknown';
    
    if($username && $password) {
        $self->{'jmx'} = new JMX::Jmx4Perl(url => $url, product => $product, user => $username, password => $password);
    } else {
        $self->{'jmx'} = new JMX::Jmx4Perl(url => $url, product => $product);
    }
    
    my $metric_pattern = $config->{'metric_pattern'};
    if ($metric_pattern) {
        $metric_pattern = trim_slashes($metric_pattern);
        my ($metric_pattern_search, $metric_pattern_replace) = split(/(?<!\\)\//, $metric_pattern);
        $self->{'metric_pattern_search'} = $metric_pattern_search;
        $self->{'metric_pattern_replace'} = '"' . $metric_pattern_replace . '"';
    }

    bless($self, $class);
    return $self;
}

sub trim_slashes {
    my $string = shift;
    $string =~ s/^\/?(.*?)\/?$/$1/;
    return $string;
}

sub flatten_recursive {
    my ($prefix, $in, $out) = @_;
    for my $key (keys %$in) {
        my $value = $in->{$key};
        my $new_prefix = $prefix ? $prefix . '_' . $key : $key;
        $new_prefix =~ s/\s+/_/g;
        $new_prefix = lc($new_prefix);
        
        if ( defined $value && ref $value eq 'HASH' ) {
            flatten_recursive($new_prefix, $value, $out);
        }
        else {
            $out->{$new_prefix} = [$value, 'n'];
        }
    }
}

sub handler {
    my $self = shift;
    
    my $jmx = $self->{'jmx'};
    my $metric_pattern_search = $self->{'metric_pattern_search'};
    my $metric_pattern_replace = $self->{'metric_pattern_replace'};
    my $config = $self->{'config'};
    
    my $alias = $config->{'alias'};
    my $query = $config->{'query'};
    my $attributes = $config->{'attributes'};

    my $response;
    if (defined $alias) {

        # Use a pre-defined jmx4perl alias
        $response = $jmx->get_attribute($alias);

    } elsif (defined $query) {
        if (defined $attributes)
        {
            # Get comma-separated list of attributes
            my @array = split(/,/, $attributes);
            $response = $jmx->get_attribute($query, \@array);

        } else {

            # Get all attributes
            $response = $jmx->get_attribute($query, undef);

        }
    } else {

        die "Either alias or query is required.";

    }
    
    my $flattened = {};
    flatten_recursive('', $response, $flattened);
    
    my $result;
    if($metric_pattern_search && $metric_pattern_replace) {
        my $transformed = {};
        while( my ($key, $val) = each %$flattened ) {
            $key =~ s/$metric_pattern_search/$metric_pattern_replace/ee;
            $transformed->{$key} = $val;
        }
        $result = $transformed;
    } else {
        $result = $flattened;
    }
    
    return $result;
};

1;
