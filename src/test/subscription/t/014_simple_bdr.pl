# Test simple bidirectional logical replication behavior with row filtering
# ID is meant to be something like uuid (e.g. from pgcrypto), but integer
# type is used for simplicity.
use strict;
use warnings;
use PostgresNode;
use TestLib;
use Test::More tests => 4;

# Create cloud node
my $node_cloud = get_new_node('publisher');
$node_cloud->init(allows_streaming => 'logical');
$node_cloud->start;

# Create remote node
my $node_remote = get_new_node('subscriber');
$node_remote->init(allows_streaming => 'logical');
$node_remote->start;

# Setup structure on cloud server
$node_cloud->safe_psql('postgres',
	"CREATE TABLE users (
		id integer primary key,
		name text,
		is_cloud boolean
	);"
);

# Setup structure on remote server
$node_remote->safe_psql('postgres',
	"CREATE TABLE users (
		id integer primary key,
		name text,
		is_cloud boolean
	);"
);

# Setup logical replication
$node_cloud->safe_psql('postgres', "CREATE PUBLICATION cloud;");
$node_cloud->safe_psql('postgres', "ALTER PUBLICATION cloud ADD TABLE users WHERE (is_cloud IS TRUE);");

$node_remote->safe_psql('postgres', "CREATE PUBLICATION remote;");
$node_remote->safe_psql('postgres', "ALTER PUBLICATION remote ADD TABLE users WHERE (is_cloud IS FALSE);");

$node_cloud->safe_psql('postgres',
	"INSERT INTO users (id, name, is_cloud) VALUES (1, 'user1_on_cloud', TRUE);");

$node_remote->safe_psql('postgres',
	"INSERT INTO users (id, name, is_cloud) VALUES (2, 'user2_on_remote', FALSE);");

my $cloud_connstr = $node_cloud->connstr . ' dbname=postgres';
my $remote_appname = 'remote_sub';
$node_remote->safe_psql('postgres',
	"CREATE SUBSCRIPTION cloud_to_remote CONNECTION '$cloud_connstr application_name=$remote_appname' PUBLICATION cloud"
);

my $remote_connstr = $node_remote->connstr . ' dbname=postgres';
my $cloud_appname = 'cloud_sub';
$node_cloud->safe_psql('postgres',
	"CREATE SUBSCRIPTION remote_to_cloud CONNECTION '$remote_connstr application_name=$cloud_appname' PUBLICATION remote"
);

# Wait for initial table sync to finish
my $synced_query =
"SELECT count(1) = 0 FROM pg_subscription_rel WHERE srsubstate NOT IN ('r', 's');";
$node_remote->poll_query_until('postgres', $synced_query)
  or die "Timed out while waiting for remote to synchronize data";
$node_cloud->poll_query_until('postgres', $synced_query)
  or die "Timed out while waiting for cloud to synchronize data";

$node_cloud->wait_for_catchup($remote_appname);
$node_remote->wait_for_catchup($cloud_appname);

# Test initial table sync
my $result =
  $node_remote->safe_psql('postgres', "SELECT count(*) from users");
is($result, qq(2), 'check initial table sync on remote');
$result =
  $node_cloud->safe_psql('postgres', "SELECT count(*) from users");
is($result, qq(2), 'check initial table sync on cloud');


# Test BDR
$node_cloud->safe_psql('postgres',
	"INSERT INTO users (id, name, is_cloud) VALUES (3, 'user3_on_cloud', TRUE);");
$node_cloud->safe_psql('postgres',
	"INSERT INTO users (id, name, is_cloud) VALUES (4, 'user4_on_cloud', TRUE);");
$node_remote->safe_psql('postgres',
	"INSERT INTO users (id, name, is_cloud) VALUES (5, 'user5_on_remote', FALSE);");

$node_cloud->wait_for_catchup($remote_appname);
$node_remote->wait_for_catchup($cloud_appname);

$result =
  $node_remote->safe_psql('postgres', "SELECT id, name, is_cloud FROM users ORDER BY ID");
is($result, qq(1|user1_on_cloud|t
2|user2_on_remote|f
3|user3_on_cloud|t
4|user4_on_cloud|t
5|user5_on_remote|f), 'check users on remote');
$result =
  $node_cloud->safe_psql('postgres', "SELECT id, name, is_cloud FROM users ORDER BY ID");
is($result, qq(1|user1_on_cloud|t
2|user2_on_remote|f
3|user3_on_cloud|t
4|user4_on_cloud|t
5|user5_on_remote|f), 'check users on cloud');

$node_remote->stop('fast');
$node_cloud->stop('fast');
