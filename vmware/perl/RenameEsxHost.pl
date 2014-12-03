#!/usr/bin/perl

## RenameEsxHost.pl
## Created by Reuben Stump (http://www.virtuin.com)
##
## Rename ESXi host in vCenter using ReconnectHost_Task()

use strict;
use warnings;

use VMware::VIRuntime;

my %opts = (
	host => {
		type => "=s",
		help => "Current ESXi host display name in vCenter",
		required => 1,
	},
	hostname => {
		type => "=s",
		help => "New ESXi host name",
		required => 1,
	},
	domainname => {
		type => "=s",
		help => "New ESXi domain name",
		required => 1,
	},
);
	
Opts::add_options(%opts);
Opts::parse();
Opts::validate();

Util::connect();

my ($host_view, $host_net, $host_dns, $host_vcname, $host_name, $domain_name, $conn_spec);

$host_vcname = Opts::get_option('host');
$host_name = Opts::get_option('hostname');
$domain_name = Opts::get_option('domainname');

$host_view = Vim::find_entity_view(view_type => "HostSystem", 
									filter => { 'name' => $host_vcname });						
die "No ESXi host '$host_vcname' found in vCenter inventory!" unless $host_view;

$host_net = Vim::get_view(mo_ref => $host_view->{'configManager'}->{'networkSystem'});
die "Failed to get host system '$host_vcname' network configuration!" unless $host_net;

$host_dns = $host_net->{'dnsConfig'};

print "Current DNS settings for host '$host_vcname':\n";
print "  Host name  : " . $host_dns->{'hostName'} . "\n";
print "  Domain name: " . $host_dns->{'domainName'} . "\n";

## Update host dns configuration with new hostname and domainname values
$host_dns->{'hostName'} 	 = $host_name;
$host_dns->{'domainName'} = $domain_name;

$host_net->UpdateDnsConfig(config => $host_dns);
print "Updated DNS settings for host '$host_vcname':\n";
print "  Host name  : " . $host_name . "\n";
print "  Domain name: " . $domain_name . "\n";

## Host must be disconnected before calling ReconnectHost().
eval {
	$host_view->DisconnectHost();
};

## Get updated view of host system
$host_view->update_view_data();

if ($host_view->{'runtime'}->{'connectionState'}->{'val'} =~ m/disconnected/gi) {
	# Host was successfully disconnected, update connection spec with new hostname
	$conn_spec = new HostConnectSpec();
	$conn_spec->{'force'} = 1;
	$conn_spec->{'hostName'} = "$host_name.$domain_name";

	$host_view->ReconnectHost(cnxSpec => $conn_spec);
} else {
	# Host is not disconnected, something went wrong and manual intervention is required
	die "Failed to disconnect host '$host_vcname'!";
}

print "Host '$host_vcname' successfully renamed to '$host_name.$domain_name' in vCenter\n";

Util::disconnect();