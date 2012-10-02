package Core::LDAP;

use strict;
use warnings;
use Switch;

use base 'Resmon::Module';

use Net::LDAP;

=pod

=head1 NAME

Core::LDAP - monitor LDAP stats via Net::LDAP

=head1 SYNOPSIS

 Core::LDAP {
     stats : baseDN => cn=snmp\,cn=monitor, attributes => bytessent,bytesrecv
 }
 
 Core::LDAP {
     email_users : uri => ldap://localhost:1389, baseDN => dc=example\,dc=com, filter => (objectClass=mailRecipient)
 }

=head1 DESCRIPTION

This module monitors arbitrary LDAP attributes or search counts via Net::LDAP.

=head1 CONFIGURATION

=over

=item check_name

Arbitrary name of the check.

=item uri

The LDAP URI to connect to (optional; defaults to "ldap://localhost").

=item base_dn

The Base DN under which to search (required).

=item bind_dn

DN to use for bind authentication (required if bind_password is specified).

=item bind_password

Password to use for bind authentication (required if bind_dn is specified).

=item attributes

One or more comma-separated LDAP attributes to return directly as metrics (required unless filter is specified).

=item filter

An LDAP filter query to perform, and report the number of entries found (required unless attributes are specified).

=back

=head1 METRICS

=over

=item count

The count of query results if filter is specified.

=item *

Attribute values if attributes are specified.

=back

=cut

sub appendAttributes {
    my ($out, $entry, $prefix) = @_;
    foreach my $attribute ($entry->attributes()) {
        my $key = $attribute;
        $key =~ s/;/-/g;
        if($prefix) {
            $key = "$prefix-$key";
        }
        my $value = $entry->get_value($attribute);
        $out->{$key} = [$value, 'n'];
    }
}

sub handler {
    my $self = shift;
    my $config = $self->{'config'};
    my $uri = $config->{'uri'} || 'ldap://localhost';
    my $base_dn = $config->{'base_dn'} || die "base_dn is required\n";
    my $bind_dn = $config->{'bind_dn'};
    my $bind_password = $config->{'bind_password'};
    my $attributes = $config->{'attributes'};
    my $filter = $config->{'filter'};
    
    if(!$attributes && !$filter)
    {
        die "Either filter or attributes is required\n";
    }

    my $ldap = Net::LDAP->new($uri) or die "$@";

    my $response;
    if($bind_dn && $bind_password) {
        $response = $ldap->bind($bind_dn, password => $bind_password);
    } else {
        $response = $ldap->bind();
    }
    $response->code && die $response->error;

    my $result = {};
    if ($attributes) {
        my @array = split(/,/, $attributes);
        $response = $ldap->search(
                base   => $baseDN,
                scope  => 'base',
                attrs  => \@array,
                filter => '(objectclass=*)');
        $response->code && die $response->error;

        if(1 == $response->count()) {
            my $entry = $response->entry(0);
            appendAttributes($result, $entry);
        } else {
            foreach my $entry ($response->entries) {
                appendAttributes($result, $entry, $entry->DN());
            }
        }
    } elsif ($filter) {
        $response = $ldap->search(
                base   => $baseDN,
                scope  => 'sub',
                attrs  => ['1.1'],
                filter => $filter);
        $response->code && die $response->error;
        $result->{'count'} = [$response->count(), 'n'];
    }

    $ldap->unbind();

    return $result;
}

1;