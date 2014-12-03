#!/usr/bin/perl

## add-host-with-thumbprint.pl
## Created by Reuben Stump (reuben.stump@gmail.com)
## Example script to demonstrate generation of SSL Thumbprint of an ESXi HostSystem
##  and calling AddHost_Task() to add the HostSystem to vCenter with SSL validation.

use strict;
use warnings;

use VMware::VIRuntime;
use Term::ReadKey;
use Digest::SHA1 qw(sha1_hex);
use MIME::Base64 qw(decode_base64);

my %opts = (
	esx_user => {
		type => ":s",
		help => "ESXi console login user (Optional. Default: root)",
		required => 0,
		default => "root",
	},
	esx_user => {
		type => ":s",
		help => "ESXi console login password (Optional.  Prompt when unspecified.)",
		required => 0,
	},
	esx_host => {
		type => "=s",
		help => "ESXi hostname (Required.  FQDN or IPAddress)",
		required => 1,
	},
	cluster => {
		type => "=s",
		help => "Name of parent cluster for HostSystem (Required.)",
		required => 1,
	},
);

Opts::add_options(%opts);
Opts::parse();
Opts::validate();

Util::connect();

my ($esx_user, $esx_pass, $esx_host, $cluster, $cluster_view, $thumbprint, $spec, 
	$task, $task_view, $task_error);

$esx_user = Opts::get_option("esx_user") || 'root';
$esx_pass = Opts::get_option("esx_pass") || 
	prompt_for_password( prompt => "Enter password for ESXi $esx_user console account" );
$esx_host = Opts::get_option("esx_host");
$cluster  = Opts::get_option("cluster");

## Retrieve specified cluster EntityView
$cluster_view = Vim::find_entity_view(view_type => "ClusterComputeResource",
					filter => { 'name' => $cluster }, properties => [ 'name' ] ) || 
	die "No cluster named '$cluster' found in vCenter Inventory."; 

## Connect to ESXi HostSystem, fetch SSL Certificate, and generate SHA1 digest (thumbprint)
## Additional verification of the SSL certificate could be done before adding the host
$thumbprint = get_esx_sslthumbprint(esx_host => $esx_host, esx_pass => $esx_pass, 
				esx_user => $esx_user );

## Create HostConnectSpec
$spec = HostConnectSpec->new(
	force => 'false',
	hostName => $esx_host,
	userName => $esx_user,
	password => $esx_pass,
	sslThumbprint => $thumbprint );
	
print "Adding HostSystem '$esx_host' to Cluster '$cluster'...\n";							

## Call AddHost_Task()
$task = $cluster_view->AddHost_Task(spec => $spec, asConnected => "true");

## Wait for AddHost_Task()
$task_view = wait_for_task(task => $task);
if ($task_view->info->state->val =~ m/error/gi) {
	$task_error = eval { $task_view->info->error->localizedMessage };
	print "   failure. $task_error.\n";
} else {
	print "   success.\n";
}


## Subroutines ###########################################################################

sub prompt_for_password {
	my %args = @_;
	
	my ($password, $prompt);
	$prompt= delete($args{prompt});
	
	print "$prompt: ";
	ReadMode('noecho');
	$password = ReadLine(0);
	print "\n";
	
	chomp $password;
	ReadMode 0;
	return $password;
}

sub wait_for_task {
	my %args = @_;
	
	my ($task, $task_view);
	$task = delete($args{'task'});

	$task_view = Vim::get_view(mo_ref => $task);
	my $task_running = 1;
	while ($task_running) {
		sleep 1;
		$task_view->update_view_data();
		
		if ($task_view->info->state->val =~ m/(success|error)/gi) {
			$task_running = 0;
		}
	}
	return $task_view;
}

sub get_esx_sslthumbprint {
	my %args = @_;

	my ($esx_host, $esx_user, $esx_pass, $esx_port, $certificate, $thumbprint);
	$esx_host = delete($args{'esx_host'}) ||
		die "Missing required parameter 'esx_host'\n";
	$esx_user = delete($args{'esx_user'}) ||
		die "Missing required parameter 'esx_user'\n";
	$esx_pass = delete($args{'esx_pass'}) ||
		die "Missing required parameter 'esx_pass'\n";
	$esx_port = delete($args{'esx_port'}) || "443";

	$certificate = get_esx_certificate( esx_host => $esx_host, esx_user => $esx_user, 
								esx_pass => $esx_pass );
	$thumbprint  = generate_ssl_thumbprint( pem => $certificate );
	
	return $thumbprint;
}

sub get_esx_certificate {
	my %args = @_;
	
	my ($esx_host, $esx_user, $esx_pass, $esx_port, $ua, $res, $certificate, $realm_name);
	$esx_host = delete($args{'esx_host'}) ||
		die "Missing required parameter 'esx_host'\n";
	$esx_user = delete($args{'esx_user'}) ||
		die "Missing required parameter 'esx_user'\n";
	$esx_pass = delete($args{'esx_pass'}) ||
		die "Missing required parameter 'esx_pass'\n";
	$esx_port = delete($args{'esx_port'}) || "443";
    
    $certificate = undef;
    $ua = LWP::UserAgent->new();
	$realm_name = "VMware HTTP server";
    $ua->credentials( "$esx_host:$esx_port", $realm_name, $esx_user => $esx_pass );
    $res = $ua->get("https://$esx_host:$esx_port/host/ssl_cert");
    
  	die $res->status_line unless $res->is_success;
    $certificate = $res->decoded_content();
    
    return $certificate;
}

sub generate_ssl_thumbprint {
	my %args = @_;

	my ($pem, $der, $digest, $sslthumbprint);
	$pem = delete($args{pem});
	
	## Strip PEM tags to get Base64 encoded certificate data
	$pem =~ s/-{1,}(BEGIN|END) CERTIFICATE-{1,}//g;

	## Convert PEM to DER (decode Base64)
	$der = decode_base64($pem);
	
	## Generate SHA1 hex digest
	$digest = sha1_hex($der);
	
	## Format thumbprint
	$sslthumbprint = "";
	for (my $i=0; $i < length($digest); $i+=2) {
		my $substring = substr($digest, $i, 2);
		$sslthumbprint .= uc($substring);
		unless ($i >= 38) {
			$sslthumbprint .= ":";
		}
	}
	
	return $sslthumbprint;
}

BEGIN {
	$ENV{'PERL_LWP_SSL_VERIFY_HOSTNAME'} = 0;
}